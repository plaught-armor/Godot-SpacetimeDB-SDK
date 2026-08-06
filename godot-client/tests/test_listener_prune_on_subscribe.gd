# Regression test for the listener array of a subscriber that was freed without
# unsubscribing.
#
# LocalDatabase dispatches over a snapshot and skips a Callable whose object is gone, so
# such an entry is not a correctness problem — but nothing removed it either, and a pool
# that subscribes a raw callback per instance grew the array for the life of the
# connection, paying an is_valid() per dead entry on every dispatch. Subscribing now
# prunes the dead entries first, which bounds the array in exactly the shape that grew it.
#
# RowReceiver was never affected (it unsubscribes in _exit_tree); this is about the raw
# subscribe_to_* API.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_listener_prune_on_subscribe.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	f += _test_pool_churn_does_not_grow_the_array()
	f += _test_live_listeners_survive_a_prune()
	f += _test_every_listener_kind_prunes()
	return f


# The shape that grew the array: subscribe from an object, free it without
# unsubscribing, repeat. Each new subscriber clears the previous generation.
func _test_pool_churn_does_not_grow_the_array() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	for i: int in 20:
		var subscriber: _Subscriber = _Subscriber.new()
		db.subscribe_to_inserts(&"t", subscriber.on_row)
		subscriber.free() # no unsubscribe — the Callable is left behind
	# Each subscribe drops the previous generation before appending, so twenty rounds of
	# churn leave one entry, not twenty (which is what the array held before the prune).
	f += _check_i("pool churn leaves one entry", _listener_count(db), 1)

	var live: _Subscriber = _Subscriber.new()
	db.subscribe_to_inserts(&"t", live.on_row)
	f += _check_i("the last dead entry goes too", _listener_count(db), 1)

	# And the survivor still works.
	_apply(db, [_Row.new(1)], [])
	f += _check_i("the live listener still fires", live.calls, 1)

	live.free()
	db.free()
	return f


# Pruning must not touch a listener whose object is alive, including one that has not
# fired yet and one registered from a lambda (which has no object to free).
func _test_live_listeners_survive_a_prune() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	var first: _Subscriber = _Subscriber.new()
	var doomed: _Subscriber = _Subscriber.new()
	var hits: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_inserts(&"t", first.on_row)
	db.subscribe_to_inserts(
		&"t",
		func(_r: _ModuleTableType) -> void:
			hits[0] += 1,
	)
	db.subscribe_to_inserts(&"t", doomed.on_row)
	doomed.free()

	var late: _Subscriber = _Subscriber.new()
	db.subscribe_to_inserts(&"t", late.on_row)
	f += _check_i("only the freed one was dropped", _listener_count(db), 3)

	_apply(db, [_Row.new(1)], [])
	f += _check_i("first listener fired", first.calls, 1)
	f += _check_i("lambda listener fired", hits[0], 1)
	f += _check_i("late listener fired", late.calls, 1)

	first.free()
	late.free()
	db.free()
	return f


# All five listener kinds go through the same registration path.
func _test_every_listener_kind_prunes() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	var kinds: Array[StringName] = [
		&"inserts",
		&"updates",
		&"before_deletes",
		&"deletes",
		&"transactions_completed",
	]
	for kind: StringName in kinds:
		var dead: _Subscriber = _Subscriber.new()
		_subscribe(db, kind, dead)
		dead.free()
		var live: _Subscriber = _Subscriber.new()
		_subscribe(db, kind, live)
		f += _check_i("%s: dead entry pruned" % kind, _listener_count(db, kind), 1)
		live.free()
	db.free()
	return f


func _subscribe(db: LocalDatabase, kind: StringName, s: _Subscriber) -> void:
	if kind == &"inserts":
		db.subscribe_to_inserts(&"t", s.on_row)
	elif kind == &"updates":
		db.subscribe_to_updates(&"t", s.on_update)
	elif kind == &"before_deletes":
		db.subscribe_to_before_deletes(&"t", s.on_row)
	elif kind == &"deletes":
		db.subscribe_to_deletes(&"t", s.on_row)
	else:
		db.subscribe_to_transactions_completed(&"t", s.on_done)


# Reads the private listener array directly: its LENGTH is the thing under test, and no
# public surface reports it (tests/ is exempt from the private-access gate).
func _listener_count(db: LocalDatabase, kind: StringName = &"inserts") -> int:
	var by_table: Dictionary = db._insert_listeners_by_table
	if kind == &"updates":
		by_table = db._update_listeners_by_table
	elif kind == &"before_deletes":
		by_table = db._before_delete_listeners_by_table
	elif kind == &"deletes":
		by_table = db._delete_listeners_by_table
	elif kind == &"transactions_completed":
		by_table = db._transactions_completed_listeners_by_table
	return (by_table.get(&"t", []) as Array).size()


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"t"]
	schema.types[&"t"] = _Row
	schema.tables[&"t"] = _Row
	return LocalDatabase.new(schema)


func _apply(db: LocalDatabase, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"t"
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	db.apply_table_update(u)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


# An Object (not RefCounted): free() must actually invalidate the Callable, which is what
# the prune keys on.
class _Subscriber:
	extends Object
	var calls: int = 0


	func on_row(_r: _ModuleTableType) -> void:
		calls += 1


	func on_update(_p: _ModuleTableType, _n: _ModuleTableType) -> void:
		calls += 1


	func on_done() -> void:
		calls += 1


class _Row:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32" }
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0


	func _init(p_id: int = 0) -> void:
		id = p_id

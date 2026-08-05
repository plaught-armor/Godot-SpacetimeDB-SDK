# A row callback that frees ANOTHER subscriber must not cost the rest of the batch.
#
# LocalDatabase dispatches row callbacks over a snapshot of the table's listener
# array (so a listener can unsubscribe inside its own callback). A callback that
# frees a different subscriber leaves that object's Callable in the already-taken
# snapshot; calling it is a GDScript runtime error, which unwound the whole
# apply_table_update — the rest of the transaction never reached the mirror and no
# transactions_completed fired, and the server does not resend. The dispatch sites
# skip a dead listener instead, the way the engine treats a signal whose receiver
# was freed.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_listener_freed_mid_batch.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase


class _Row:
	extends _ModuleTableType
	@export var id: int = 0


	static func make(p_id: int) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		return r


## Subscriber that frees [member victim] the first time it sees a row.
class _Killer:
	extends Node
	var victim: Node = null
	var seen: int = 0


	func on_insert(_row: _ModuleTableType) -> void:
		seen += 1
		if is_instance_valid(victim):
			victim.free()
			victim = null


## Plain subscriber; the one the killer frees mid-batch.
class _Victim:
	extends Node
	var seen: int = 0


	func on_insert(_row: _ModuleTableType) -> void:
		seen += 1


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"alpha"] = &"id"

	var f: int = 0
	f += _case_insert_batch()
	f += _case_delete_batch()
	_db.free()
	return f


# The killer is registered first, so the victim's dead Callable is still ahead of
# the loop when the killer frees it.
func _case_insert_batch() -> int:
	var killer: _Killer = _Killer.new()
	var victim: _Victim = _Victim.new()
	killer.victim = victim
	_db.subscribe_to_inserts(&"alpha", killer.on_insert)
	_db.subscribe_to_inserts(&"alpha", victim.on_insert)
	var completed: PackedInt32Array = [0]
	_db.subscribe_to_transactions_completed(
		&"alpha",
		func() -> void:
			completed[0] += 1,
	)

	_apply(&"alpha", [_Row.make(1), _Row.make(2), _Row.make(3)], [])

	var f: int = 0
	f += _check("insert: every row reached the mirror", _db.get_all_rows(&"alpha").size(), 3)
	f += _check("insert: the live listener saw every row", killer.seen, 3)
	f += _check("insert: transactions_completed still fired", completed[0], 1)
	killer.free()
	return f


# Same shape on the delete wave, which dispatches from a different loop.
func _case_delete_batch() -> int:
	var killer: _Killer = _Killer.new()
	var victim: _Victim = _Victim.new()
	killer.victim = victim
	_db.subscribe_to_deletes(&"alpha", killer.on_insert)
	_db.subscribe_to_deletes(&"alpha", victim.on_insert)

	_apply(&"alpha", [], [_Row.make(1), _Row.make(2), _Row.make(3)])

	var f: int = 0
	f += _check("delete: every row left the mirror", _db.get_all_rows(&"alpha").size(), 0)
	f += _check("delete: the live listener saw every row", killer.seen, 3)
	killer.free()
	return f


func _apply(table: StringName, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u)


func _check(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

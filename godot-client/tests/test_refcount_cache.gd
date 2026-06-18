# Test for per-row refcounting + event-table handling in LocalDatabase.
#
# Verifies for a PK table that a row shared by overlapping subscriptions is
# refcounted: a second identical insert bumps the count silently, an update
# fires on_update once, and a delete only evicts (firing on_delete) when the
# last holder drops it. Also verifies event-table rows fire on_insert but are
# never stored in the cache.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_refcount_cache.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0

var _inserts: int = 0
var _updates: int = 0
var _deletes: int = 0
var _last_update_val: int = -1
var _pkless_inserts: int = 0
var _pkless_deletes: int = 0
var _db: LocalDatabase


class _TestRow:
	extends _ModuleTableType
	@export var id: int = 0
	@export var val: int = 0


	static func make(p_id: int, p_val: int) -> _TestRow:
		var r: _TestRow = _TestRow.new()
		r.id = p_id
		r.val = p_val
		return r


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha", &"events", &"gamma"]
	_db = LocalDatabase.new(schema)
	# Force the PK path + value-compare without a disk schema by seeding the caches.
	_db._primary_key_cache[&"alpha"] = &"id"
	_db._row_property_cache[&"alpha"] = [&"id", &"val"] as Array[StringName]
	# gamma: PK-less ("" primary key) — refcounted by row value.
	_db._primary_key_cache[&"gamma"] = &""
	_db._row_property_cache[&"gamma"] = [&"id", &"val"] as Array[StringName]

	_db.subscribe_to_inserts(&"alpha", _on_insert)
	_db.subscribe_to_updates(&"alpha", _on_update)
	_db.subscribe_to_deletes(&"alpha", _on_delete)
	_db.subscribe_to_inserts(&"events", _on_insert)
	_db.subscribe_to_inserts(&"gamma", _on_pkless_insert)
	_db.subscribe_to_deletes(&"gamma", _on_pkless_delete)

	var f: int = 0

	# A) Fresh insert from subscription #1.
	_apply(&"alpha", [_TestRow.make(1, 10)], [])
	f += _check_i("insert fires once on first delivery", _inserts, 1)
	f += _check_i("row cached", _db.count_all_rows(&"alpha"), 1)

	# B) Same row delivered by overlapping subscription #2 — silent refcount bump.
	_apply(&"alpha", [_TestRow.make(1, 10)], [])
	f += _check_i("overlapping identical insert is silent", _inserts, 1)
	f += _check_i("no spurious update on identical re-deliver", _updates, 0)

	# C) Update: delete-old + insert-new (same pk) in one batch fires on_update once.
	_apply(&"alpha", [_TestRow.make(1, 20)], [_TestRow.make(1, 10)])
	f += _check_i("update fires once", _updates, 1)
	f += _check_i("delete does not fire on update", _deletes, 0)
	f += _check_i("update carries new value", _last_update_val, 20)

	# D) One holder drops the row (refcount 2 -> 1): no delete, still present.
	_apply(&"alpha", [], [_TestRow.make(1, 20)])
	f += _check_i("shared row survives first drop", _deletes, 0)
	f += _check_i("row still cached after first drop", _db.count_all_rows(&"alpha"), 1)

	# E) Last holder drops the row (refcount 1 -> 0): on_delete fires, evicted.
	_apply(&"alpha", [], [_TestRow.make(1, 20)])
	f += _check_i("delete fires when last holder drops", _deletes, 1)
	f += _check_i("row evicted after last drop", _db.count_all_rows(&"alpha"), 0)

	# F) Event table: insert fires the callback but is never stored.
	var ev: TableUpdateData = TableUpdateData.new()
	ev.table_name = &"events"
	ev.is_event = true
	ev.inserts.assign([_TestRow.make(5, 99)])
	_db.apply_table_update(ev)
	f += _check_i("event-table insert fires callback", _inserts, 2)
	f += _check_i("event-table row not stored", _db.count_all_rows(&"events"), 0)

	# --- PK-less table refcounting (keyed by row value) ---
	# G) Fresh insert from subscription #1.
	_apply(&"gamma", [_TestRow.make(1, 10)], [])
	f += _check_i("pk-less: insert fires once", _pkless_inserts, 1)
	f += _check_i("pk-less: row cached", _db.count_all_rows(&"gamma"), 1)

	# H) Same value from overlapping subscription #2 — silent multiplicity bump.
	_apply(&"gamma", [_TestRow.make(1, 10)], [])
	f += _check_i("pk-less: overlapping insert is silent", _pkless_inserts, 1)
	f += _check_i("pk-less: not duplicated in cache", _db.count_all_rows(&"gamma"), 1)

	# I) One holder drops it (count 2 -> 1): survives, no on_delete.
	_apply(&"gamma", [], [_TestRow.make(1, 10)])
	f += _check_i("pk-less: shared row survives first drop", _pkless_deletes, 0)
	f += _check_i("pk-less: still cached after first drop", _db.count_all_rows(&"gamma"), 1)

	# J) Last holder drops it (count 1 -> 0): on_delete fires, evicted.
	_apply(&"gamma", [], [_TestRow.make(1, 10)])
	f += _check_i("pk-less: delete fires on last drop", _pkless_deletes, 1)
	f += _check_i("pk-less: evicted after last drop", _db.count_all_rows(&"gamma"), 0)

	# K) Distinct values are independent rows.
	_apply(&"gamma", [_TestRow.make(1, 10), _TestRow.make(2, 20)], [])
	f += _check_i("pk-less: distinct values both insert", _pkless_inserts, 3)
	f += _check_i("pk-less: both cached", _db.count_all_rows(&"gamma"), 2)

	_db.free()
	return f


func _apply(table: StringName, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	u.inserts.assign(inserts)
	u.deletes.assign(deletes)
	_db.apply_table_update(u)


func _on_insert(_row: _ModuleTableType) -> void:
	_inserts += 1


func _on_update(_old_row: _ModuleTableType, new_row: _ModuleTableType) -> void:
	_updates += 1
	_last_update_val = new_row.get(&"val")


func _on_delete(_row: _ModuleTableType) -> void:
	_deletes += 1


func _on_pkless_insert(_row: _ModuleTableType) -> void:
	_pkless_inserts += 1


func _on_pkless_delete(_row: _ModuleTableType) -> void:
	_pkless_deletes += 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

# Regression test for the null-`prev` crash in LocalDatabase.apply_table_update.
#
# A delete+insert of the same pk (the server's "update" encoding) for a pk that is
# NOT currently cached used to fire row_updated with prev == null; the index cache
# listeners dereference prev (`p[_field_name]`) and crash. The fix routes a null
# prev through insert semantics instead, so no update listener ever sees null.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_update_null_prev.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const PkRow: GDScript = preload("res://tests/_test_pk_row.gd")

var _total: int = 0
var _inserts: int = 0
var _updates: int = 0
var _null_prev_seen: bool = false
var _last_prev_val: int = -1


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"tbl"]
	schema.types[&"tbl"] = PkRow
	var db: LocalDatabase = LocalDatabase.new(schema)
	db._tables[&"tbl"] = { }
	db.subscribe_to_inserts(&"tbl", _on_insert)
	db.subscribe_to_updates(&"tbl", _on_update)

	var f: int = 0

	# Scenario 1 — delete+insert of an UNCACHED pk. The crash case: must become an
	# insert, never an update with a null prev.
	db.apply_table_update(_mk_update([_mk_row(5, 1)], [_mk_row(5, 2)]))
	f += _check_i("uncached update→insert: insert fired", _inserts, 1)
	f += _check_i("uncached update→insert: update NOT fired", _updates, 0)
	f += _check_b("uncached update→insert: no null prev to listener", _null_prev_seen, false)
	f += _check_i("uncached update→insert: row stored", db._tables[&"tbl"].size(), 1)

	# Scenario 2 — a genuine update of a CACHED pk fires row_updated with non-null prev.
	_reset()
	db.apply_table_update(_mk_update([], [_mk_row(7, 1)])) # subscribe-insert pk 7
	f += _check_i("cached setup: insert fired", _inserts, 1)
	_reset()
	db.apply_table_update(_mk_update([_mk_row(7, 1)], [_mk_row(7, 9)])) # value change
	f += _check_i("cached update: update fired", _updates, 1)
	f += _check_b("cached update: prev non-null", _null_prev_seen, false)
	f += _check_i("cached update: prev carried old value", _last_prev_val, 1)

	db.free()
	return f


func _mk_row(id_val: int, v: int) -> Resource:
	var r: Resource = PkRow.new()
	r.id = id_val
	r.val = v
	return r


func _mk_update(deletes: Array, inserts: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"tbl"
	u.deletes.assign(deletes)
	u.inserts.assign(inserts)
	u.is_event = false
	return u


func _reset() -> void:
	_inserts = 0
	_updates = 0
	_null_prev_seen = false
	_last_prev_val = -1


func _on_insert(_row: _ModuleTableType) -> void:
	_inserts += 1


func _on_update(prev: Variant, _cur: _ModuleTableType) -> void:
	_updates += 1
	if prev == null:
		_null_prev_seen = true
	else:
		# Dereference like the index listeners do — would crash on a null prev.
		_last_prev_val = prev.val


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

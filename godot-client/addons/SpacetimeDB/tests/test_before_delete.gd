# Test for the on_before_delete hook on LocalDatabase.
#
# Verifies that for a PK table:
#   - before-delete fires for a deleted row,
#   - it fires BEFORE the post-delete hook,
#   - the row is still queryable from the cache when before-delete runs,
#   - and gone by the time the post-delete hook runs.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_before_delete.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0

var _order: Array[StringName] = []
var _present_at_before: bool = false
var _present_at_after: bool = true
var _db: LocalDatabase


class _TestRow:
	extends _ModuleTableType
	@export var id: int = 0


	static func make(p_id: int) -> _TestRow:
		var r: _TestRow = _TestRow.new()
		r.id = p_id
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
	schema.raw_table_names = [&"alpha"]
	_db = LocalDatabase.new(schema)
	# Force the PK path without a disk schema by seeding the PK cache.
	_db._primary_key_cache[&"alpha"] = &"id"

	_db.subscribe_to_before_deletes(&"alpha", _on_before_delete)
	_db.subscribe_to_deletes(&"alpha", _on_delete)

	# Insert id=1, then delete it in a separate batch.
	var ins: TableUpdateData = TableUpdateData.new()
	ins.table_name = &"alpha"
	ins.inserts = [_TestRow.make(1)]
	_db.apply_table_update(ins)

	var del: TableUpdateData = TableUpdateData.new()
	del.table_name = &"alpha"
	del.deletes = [_TestRow.make(1)]
	_db.apply_table_update(del)

	var f: int = 0
	f += _check_b("before-delete fired", _order.has(&"before"), true)
	f += _check_b("delete fired", _order.has(&"delete"), true)
	f += _check_b("before-delete precedes delete", _order == [&"before", &"delete"], true)
	f += _check_b("row present at before-delete", _present_at_before, true)
	f += _check_b("row gone at post-delete", _present_at_after, false)

	_db.free()
	return f


func _on_before_delete(row: _ModuleTableType) -> void:
	_order.append(&"before")
	_present_at_before = _db.get_row_by_pk(&"alpha", row.get(&"id")) != null


func _on_delete(row: _ModuleTableType) -> void:
	_order.append(&"delete")
	_present_at_after = _db.get_row_by_pk(&"alpha", row.get(&"id")) != null


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

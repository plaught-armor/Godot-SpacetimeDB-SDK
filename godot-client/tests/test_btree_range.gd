# Behavioral test for _ModuleTableBTreeIndex range queries (the sorted-key mirror
# that backs the codegen'd filter_range on orderable index columns). Drives a
# LocalDatabase through insert / update / delete batches and asserts:
#   - _sorted_keys stays ascending and distinct across inserts,
#   - _range_rows returns every row whose key is in [from, to] inclusive,
#   - empty / single-key / full-span / boundary windows resolve correctly,
#   - an update that moves a row's key re-sorts the mirror,
#   - emptying a boundary bucket drops its key from the mirror,
#   - an overlapping re-delivery (refcount bump) does not duplicate the key.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_btree_range.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase
var _idx: _ModuleTableBTreeIndex
var _cache: Dictionary = { }


class _Row:
	extends _ModuleTableType
	@export var id: int = 0
	@export var group: int = 0


	static func make(p_id: int, p_group: int) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		r.group = p_group
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
	_db._primary_key_cache[&"alpha"] = &"id" # PK path without a disk schema

	_idx = _ModuleTableBTreeIndex.new()
	_idx._table_name = &"alpha"
	_idx._field_name = &"group"
	_idx._connect_cache_to_db(_cache, _db)

	var f: int = 0

	# Insert deliberately out of key order: groups 30, 10, 40, 20 (two rows in 20).
	_apply_inserts([_Row.make(1, 30), _Row.make(2, 10), _Row.make(3, 40), _Row.make(4, 20), _Row.make(5, 20)])
	f += _check_keys("sorted_keys ascending + distinct", [10, 20, 30, 40])

	# Inclusive window [15, 35] → groups 20, 30 → ids 1, 4, 5.
	f += _check_ids("range [15,35] middle window", _idx._range_rows(15, 35), [1, 4, 5])
	# Boundaries inclusive: [20, 30] keeps both endpoints.
	f += _check_ids("range [20,30] inclusive ends", _idx._range_rows(20, 30), [1, 4, 5])
	# Single-key window collapsed onto an existing key.
	f += _check_ids("range [40,40] single key", _idx._range_rows(40, 40), [3])
	# Full span covers everything.
	f += _check_ids("range [0,100] full span", _idx._range_rows(0, 100), [1, 2, 3, 4, 5])
	# Gap window between keys returns nothing.
	f += _check_ids("range [21,29] empty gap", _idx._range_rows(21, 29), [])
	# Window entirely below / above the key set returns nothing.
	f += _check_ids("range [0,5] below all", _idx._range_rows(0, 5), [])
	f += _check_ids("range [50,99] above all", _idx._range_rows(50, 99), [])

	# Move id1 from group 30 → 25. Key 30 empties (dropped), 25 appears.
	_apply_update(_Row.make(1, 30), _Row.make(1, 25))
	f += _check_keys("sorted_keys after move", [10, 20, 25, 40])
	f += _check_ids("range [22,27] catches moved row", _idx._range_rows(22, 27), [1])
	f += _check_ids("range [28,35] excludes moved row", _idx._range_rows(28, 35), [])

	# Overlapping re-delivery of an existing row bumps the refcount but must not
	# add a duplicate key to the mirror.
	_apply_inserts([_Row.make(4, 20)])
	f += _check_keys("sorted_keys unchanged on re-delivery", [10, 20, 25, 40])

	# Delete the boundary key 40 entirely → it leaves the mirror.
	_apply_deletes([_Row.make(3, 40)])
	f += _check_keys("sorted_keys after boundary delete", [10, 20, 25])
	f += _check_ids("range [30,99] empty after delete", _idx._range_rows(30, 99), [])
	return f


func _apply_inserts(rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.inserts = typed
	_db.apply_table_update(u)


func _apply_deletes(rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.deletes = typed
	_db.apply_table_update(u)


func _apply_update(old_row: _Row, new_row: _Row) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var ins: Array[Resource] = []
	ins.assign([new_row])
	var del: Array[Resource] = []
	del.assign([old_row])
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u)


# Collects the ids out of a _range_rows result, sorted, for order-independent compare.
func _ids_of(rows: Array) -> Array[int]:
	var ids: Array[int] = []
	for r: _Row in rows:
		ids.append(r.id)
	ids.sort()
	return ids


func _check_ids(label: String, rows: Array, want: Array) -> int:
	_total += 1
	var got: Array[int] = _ids_of(rows)
	if got == want:
		print("PASS  %s = %s" % [label, str(got)])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, str(got), str(want)])
	return 1


func _check_keys(label: String, want: Array) -> int:
	_total += 1
	if _idx._sorted_keys == want:
		print("PASS  %s = %s" % [label, str(_idx._sorted_keys)])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, str(_idx._sorted_keys), str(want)])
	return 1

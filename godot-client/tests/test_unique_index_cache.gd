# Behavioral test for the _ModuleTableUniqueIndex single-row cache — the O(1)
# find() path every unique-indexed lookup uses. Drives a LocalDatabase through
# insert / update / delete and asserts the cache:
#   - insert keys the row by its indexed value,
#   - an update that changes the indexed value re-keys it (old key dropped),
#   - delete removes the key.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_unique_index_cache.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase


class _Row:
	extends _ModuleTableType
	@export var id: int = 0
	@export var key: int = 0


	static func make(p_id: int, p_key: int) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		r.key = p_key
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
	_db._primary_key_cache[&"alpha"] = &"id"

	var idx: _ModuleTableUniqueIndex = _ModuleTableUniqueIndex.new()
	idx._table_name = &"alpha"
	idx._field_name = &"key"
	var cache: Dictionary = { }
	idx._connect_cache_to_db(cache, _db)

	var f: int = 0

	# Insert two rows → each keyed by its unique value.
	_apply_inserts([_Row.make(1, 10), _Row.make(2, 20)])
	f += _check_b("k10 → id1", cache.get(10) != null and cache[10].id == 1, true)
	f += _check_b("k20 → id2", cache.get(20) != null and cache[20].id == 2, true)
	f += _check_i("cache size", cache.size(), 2)

	# Update id1: key 10 → 30 re-keys it; the stale key 10 is dropped.
	_apply_update(_Row.make(1, 10), _Row.make(1, 30))
	f += _check_b("old key 10 dropped", cache.has(10), false)
	f += _check_b("k30 → id1", cache.get(30) != null and cache[30].id == 1, true)
	f += _check_i("cache size after re-key", cache.size(), 2)

	# Delete id2 → its key 20 is removed.
	_apply_deletes([_Row.make(2, 20)])
	f += _check_b("k20 removed", cache.has(20), false)
	f += _check_i("cache size after delete", cache.size(), 1)
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


# A real update: delete the old row and insert the new one with the same PK in one
# batch, so the db takes its update path rather than an overlapping re-delivery.
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

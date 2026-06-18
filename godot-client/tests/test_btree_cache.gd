# Behavioral test for the _ModuleTableBTreeIndex multimap cache (2.3 — the btree
# index is a real per-value bucket cache, no longer a linear scan). Drives a
# LocalDatabase through insert / update / delete batches and asserts the cache
# buckets stay correct:
#   - insert appends to the value's bucket,
#   - an update that changes the indexed value moves the row between buckets,
#   - delete removes the row and prunes the bucket once empty.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_btree_cache.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase


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

	var idx: _ModuleTableBTreeIndex = _ModuleTableBTreeIndex.new()
	idx._table_name = &"alpha"
	idx._field_name = &"group"
	var cache: Dictionary = { }
	idx._connect_cache_to_db(cache, _db)

	var f: int = 0

	# Insert: id1/g10, id2/g10, id3/g20 → two buckets.
	_apply_inserts([_Row.make(1, 10), _Row.make(2, 10), _Row.make(3, 20)])
	f += _check_i("g10 bucket after insert", _bucket(cache, 10).size(), 2)
	f += _check_i("g20 bucket after insert", _bucket(cache, 20).size(), 1)

	# Update id1: group 10 → 20. A real update is a delete+insert of the same PK in
	# one batch (re-inserting the PK alone is an overlapping re-delivery that bumps
	# the refcount instead). This moves id1 between buckets.
	_apply_update(_Row.make(1, 10), _Row.make(1, 20))
	f += _check_i("g10 bucket after move", _bucket(cache, 10).size(), 1)
	f += _check_i("g20 bucket after move", _bucket(cache, 20).size(), 2)
	f += _check_b("moved row id correct", _bucket(cache, 10)[0].id == 2, true)

	# Delete id3 (g20) leaves g20 with just id1.
	_apply_deletes([_Row.make(3, 20)])
	f += _check_i("g20 bucket after delete", _bucket(cache, 20).size(), 1)

	# Delete the last members → buckets prune to absent keys.
	_apply_deletes([_Row.make(1, 20)])
	f += _check_b("g20 pruned when empty", cache.has(20), false)
	_apply_deletes([_Row.make(2, 10)])
	f += _check_b("g10 pruned when empty", cache.has(10), false)
	f += _check_i("cache fully drained", cache.size(), 0)
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


# A real update: delete the old row and insert the new one with the same PK in a
# single batch, so the db takes its update path (refcount unchanged) rather than
# treating the re-insert as an overlapping re-delivery.
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


func _bucket(cache: Dictionary, key: int) -> Array:
	return cache.get(key, [])


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

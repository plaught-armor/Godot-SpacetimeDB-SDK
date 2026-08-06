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
	const PRIMARY_KEY: StringName = &"id"
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

	# One transaction hands a unique value from its old holder to a new row: id1 (key 30)
	# is deleted and id3 takes 30. LocalDatabase applies the whole insert list before any
	# delete, so the successor is already cached when the delete arrives — erasing by key
	# alone dropped it, and find(30) then returned null for a row iter() still yields.
	_apply_handoff(_Row.make(1, 30), _Row.make(3, 30))
	f += _check_b("k30 survives the handoff", cache.has(30), true)
	f += _check_b("k30 → the successor, id3", cache.get(30) != null and cache[30].id == 3, true)
	f += _check_b(
		"the successor is the stored row",
		cache.get(30) == _db.get_row_by_pk(&"alpha", 3),
		true,
	)
	f += _check_i("cache size after handoff", cache.size(), 1)

	# The same race through the update path: id3 moves 30 → 40 in the batch that also
	# gives 30 to id4. Whoever holds the key at that moment keeps it.
	_apply_batch([_Row.make(3, 30)], [_Row.make(3, 40), _Row.make(4, 30)])
	f += _check_b("k40 → id3", cache.get(40) != null and cache[40].id == 3, true)
	f += _check_b("k30 → its new holder, id4", cache.get(30) != null and cache[30].id == 4, true)
	f += _check_i("cache size after the re-key race", cache.size(), 2)

	# And an ordinary delete still gives the key up.
	_apply_deletes([_Row.make(4, 30)])
	f += _check_b("k30 removed once nobody holds it", cache.has(30), false)
	f += _check_i("final cache size", cache.size(), 1)

	f += _run_reverse_order_race()
	return f


# The re-key race above fires the mover's update before the taker's insert, because that
# is the order its insert list happens to be in. The server picks that order, so pin the
# other one too, on its own database so neither case inherits the other's rows: id1 gives
# up key 10 while id2 takes it, with id2's insert arriving FIRST.
func _run_reverse_order_race() -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha"]
	var db: LocalDatabase = LocalDatabase.new(schema)
	db._primary_key_cache[&"alpha"] = &"id"
	var idx: _ModuleTableUniqueIndex = _ModuleTableUniqueIndex.new()
	idx._table_name = &"alpha"
	idx._field_name = &"key"
	var cache: Dictionary = { }
	idx._connect_cache_to_db(cache, db)

	var f: int = 0
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var seed_ins: Array[Resource] = []
	seed_ins.assign([_Row.make(1, 10)])
	u.inserts = seed_ins
	db.apply_table_update(u)

	var race: TableUpdateData = TableUpdateData.new()
	race.table_name = &"alpha"
	var ins: Array[Resource] = []
	ins.assign([_Row.make(2, 10), _Row.make(1, 20)]) # taker first, then the mover
	var del: Array[Resource] = []
	del.assign([_Row.make(1, 10)])
	race.inserts = ins
	race.deletes = del
	db.apply_table_update(race)

	f += _check_b(
		"reverse order: k10 → the taker, id2",
		cache.get(10) != null and cache[10].id == 2,
		true,
	)
	f += _check_b(
		"reverse order: k20 → the mover, id1",
		cache.get(20) != null and cache[20].id == 1,
		true,
	)
	f += _check_i("reverse order: cache size", cache.size(), 2)
	db.free()
	return f


# Delete one row and insert a different one carrying the same indexed value, in a single
# batch — different primary keys, so this is a delete plus an insert, not an update.
func _apply_handoff(deleted: _Row, inserted: _Row) -> void:
	_apply_batch([deleted], [inserted])


func _apply_batch(deletes: Array, inserts: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u)


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

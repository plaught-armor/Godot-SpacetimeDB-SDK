# A generated unique index on a table's primary key reads LocalDatabase's own table
# instead of keeping a cache of its own. The table already maps each primary key to its
# row, so the cache was a second copy, kept current by a hook call on every inserted,
# updated and deleted row.
#
# Pinned through the real generated Blackholio bindings: BlackholioEntityTable has one
# unique index, on its primary key entity_id, and no other index.
#   - find() follows inserts, updates and deletes, including through a wipe;
#   - a row callback already finds the row its message applied, as with a cache;
#   - the index registers no hooks.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_primary_key_index.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase = null
var _table: BlackholioEntityTable = null
## What the insert callback found through the index, per inserted entity id.
var _found_in_callback: Dictionary[int, bool] = { }


func _initialize() -> void:
	_db = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	_table = BlackholioEntityTable.new(_db)
	var fails: int = _run()
	_db.free()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	f += _check_b("no index hooks registered", _db._index_hooks_by_table.has(&"entity"), false)
	f += _check_b("empty: find is null", _table.first_by_entity_id(1) == null, true)

	_table.on_insert(_on_insert)
	_apply([_entity(1, 10), _entity(2, 20)], [])
	f += _check_i("insert: found by key", _table.first_by_entity_id(1).mass, 10)
	f += _check_i("insert: find_by", _table.find_by_entity_id(2).size(), 1)
	f += _check_b("insert: callback found its row", _found_in_callback.get(1, false), true)

	_apply([_entity(1, 11)], [_entity(1, 10)])
	f += _check_i("update: new row found", _table.first_by_entity_id(1).mass, 11)
	f += _check_b(
		"update: same row as the table",
		_table.first_by_entity_id(1) == _db.get_row_by_pk(&"entity", 1),
		true,
	)

	_apply([], [_entity(2, 20)])
	f += _check_b("delete: find is null", _table.first_by_entity_id(2) == null, true)
	f += _check_i("delete: find_by empty", _table.find_by_entity_id(2).size(), 0)

	_db.clear_all_tables()
	f += _check_b("wipe: find is null", _table.first_by_entity_id(1) == null, true)
	_apply([_entity(3, 30)], [])
	f += _check_i("after wipe: found again", _table.first_by_entity_id(3).mass, 30)
	return f


func _on_insert(row: _ModuleTableType) -> void:
	var id: int = row.entity_id
	_found_in_callback[id] = _table.first_by_entity_id(id) == row


func _entity(id: int, mass: int) -> BlackholioEntity:
	return BlackholioEntity.create(id, BlackholioDbVector2.create(0.0, 0.0), mass)


func _apply(inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"entity"
	u.inserts.assign(inserts)
	u.deletes.assign(deletes)
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

# Probe: what do the generated index caches hold after each of the two cache wipes?
#
# Both index kinds (_ModuleTableUniqueIndex, _ModuleTableBTreeIndex) keep their cache
# current by subscribing to LocalDatabase's insert/update/delete callbacks.
# clear_local_db() reports a delete per row; clear_all_tables() reports nothing at all.
# Ask what each leaves behind, for a PK table and a PK-less one.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_index_after_wipe.gd
#
# Underscore-prefixed: a probe, not part of the suite.
extends SceneTree

var _findings: int = 0


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


class _PklessRow:
	extends _ModuleTableType
	@export var key: int = 0


	static func make(p_key: int) -> _PklessRow:
		var r: _PklessRow = _PklessRow.new()
		r.key = p_key
		return r


func _initialize() -> void:
	_scenario_pk("clear_all_tables", true)
	_scenario_pk("clear_local_db", false)
	_scenario_pkless("clear_all_tables", true)
	_scenario_pkless("clear_local_db", false)
	print("\n%d finding(s)." % _findings)
	quit(0)


func _make_db(pk_less: bool) -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha"]
	# The row script must be registered or the PK-less path collapses every row into one
	# cached entry (_get_row_properties returns empty with no script).
	if pk_less:
		schema.types[&"alpha"] = _PklessRow
		schema.tables[&"alpha"] = _PklessRow
	else:
		schema.types[&"alpha"] = _Row
		schema.tables[&"alpha"] = _Row
	return LocalDatabase.new(schema)


func _apply_inserts(db: LocalDatabase, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.inserts = typed
	db.apply_table_update(u)


func _report(label: String, mirror_rows: int, uniq: int, btree: int, keys: int) -> void:
	var stale: bool = mirror_rows == 0 and (uniq > 0 or btree > 0 or keys > 0)
	print(
		"  %-28s mirror=%d unique_cache=%d btree_buckets=%d btree_keys=%d %s"
		% [label, mirror_rows, uniq, btree, keys, "  <-- STALE" if stale else ""]
	)
	if stale:
		_findings += 1


func _scenario_pk(wipe: String, silent: bool) -> void:
	print("\n[PK table] wipe = %s" % wipe)
	var db: LocalDatabase = _make_db(false)

	var uniq: _ModuleTableUniqueIndex = _ModuleTableUniqueIndex.new()
	uniq._table_name = &"alpha"
	uniq._field_name = &"key"
	var uniq_cache: Dictionary = { }
	uniq._connect_cache_to_db(uniq_cache, db)

	var btree: _ModuleTableBTreeIndex = _ModuleTableBTreeIndex.new()
	btree._table_name = &"alpha"
	btree._field_name = &"key"
	var btree_cache: Dictionary = { }
	btree._connect_cache_to_db(btree_cache, db)

	_apply_inserts(db, [_Row.make(1, 10), _Row.make(2, 20), _Row.make(3, 20)])
	_report(
		"after 3 inserts",
		db.count_all_rows(&"alpha"),
		uniq_cache.size(),
		btree_cache.size(),
		btree._sorted_keys.size(),
	)

	if silent:
		db.clear_all_tables()
	else:
		db.clear_local_db()

	_report(
		"after %s" % wipe,
		db.count_all_rows(&"alpha"),
		uniq_cache.size(),
		btree_cache.size(),
		btree._sorted_keys.size(),
	)
	# What a game would actually observe through the generated accessors.
	var ghost: Variant = uniq_cache.get(10)
	print(
		(
			"  unique find(10) -> %s   btree first_row(20) -> %s   filter(20) size %d"
			% [
				"row id=%d" % ghost.id if ghost != null else "null",
				("row id=%d" % btree._first_row(20).id
					if btree._first_row(20) != null
					else "null"),
				btree._range_rows(20, 20).size(),
			]
		)
	)
	db.free()


func _scenario_pkless(wipe: String, silent: bool) -> void:
	print("\n[PK-less table] wipe = %s" % wipe)
	var db: LocalDatabase = _make_db(true)

	var uniq: _ModuleTableUniqueIndex = _ModuleTableUniqueIndex.new()
	uniq._table_name = &"alpha"
	uniq._field_name = &"key"
	var uniq_cache: Dictionary = { }
	uniq._connect_cache_to_db(uniq_cache, db)

	var btree: _ModuleTableBTreeIndex = _ModuleTableBTreeIndex.new()
	btree._table_name = &"alpha"
	btree._field_name = &"key"
	var btree_cache: Dictionary = { }
	btree._connect_cache_to_db(btree_cache, db)

	_apply_inserts(db, [_PklessRow.make(10), _PklessRow.make(20)])
	_report(
		"after 2 inserts",
		db.count_all_rows(&"alpha"),
		uniq_cache.size(),
		btree_cache.size(),
		btree._sorted_keys.size(),
	)

	if silent:
		db.clear_all_tables()
	else:
		db.clear_local_db()

	_report(
		"after %s" % wipe,
		db.count_all_rows(&"alpha"),
		uniq_cache.size(),
		btree_cache.size(),
		btree._sorted_keys.size(),
	)
	db.free()

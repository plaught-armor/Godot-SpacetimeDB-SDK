# Probe: what the mirror looks like when game code wipes it from INSIDE a row callback.
#
# apply_table_update hoists the per-table containers into locals before it dispatches:
#   ref_table  = _ref_counts[table]        (PK)
#   counts     = _pk_less_counts[table]    (PK-less)
#   table_dict = _tables[table]
#   rows_array = _pk_less_tables[table]
# and every listener call in the middle of those loops is game code. clear_local_db()
# empties the INNER containers of _tables / _pk_less_tables (so those locals stay live)
# but CLEARS the outer maps of _ref_counts / _pk_less_counts (so those locals detach).
# Reachable: a listener that calls SpacetimeDBClient.connect_db(), which wipes the mirror
# synchronously before it opens the new socket.
#
# Measures, for both table shapes:
#   - rows the rest of the batch adds after the wipe: are they in the mirror, and do
#     they carry a refcount?
#   - a later delete for such a row: does the row leave, does on_delete fire?
#   - a later re-delivery of such a row: one cached copy or two?
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_reentrant_clear.gd

extends SceneTree

var _db: LocalDatabase
var _wipe_on_pk: int = -1 # fire clear_local_db() from the insert callback for this pk
var _wipe_on_value: int = -1 # ... or this pk-less value
var _wipes: int = 0
var _deleted_pks: PackedInt32Array = []
var _deleted_values: PackedInt32Array = []


func _initialize() -> void:
	_db = _mk_db()
	_db.subscribe_to_inserts(&"keyed", _on_keyed_insert)
	_db.subscribe_to_deletes(&"keyed", _on_keyed_delete)
	_db.subscribe_to_inserts(&"flat", _on_flat_insert)
	_db.subscribe_to_deletes(&"flat", _on_flat_delete)

	_probe_pk()
	_probe_pk_less()

	_db.free()
	quit(0)


func _probe_pk() -> void:
	print("=== PK table ===")
	# Three inserts; the callback for pk 1 wipes the mirror. pks 2 and 3 are added by the
	# rest of the same loop, i.e. after the wipe.
	_wipe_on_pk = 1
	_apply(&"keyed", [_keyed(1), _keyed(2), _keyed(3)], [])
	_wipe_on_pk = -1
	print("wipes fired: %d" % _wipes)
	print("rows cached after the batch: %d" % _db.get_all_rows(&"keyed").size())
	print(
		"  pk2 cached: %s   pk3 cached: %s"
		% [_db.get_row_by_pk(&"keyed", 2) != null, _db.get_row_by_pk(&"keyed", 3) != null]
	)
	print("  refcounts: %s" % [_db._ref_counts.get(&"keyed", { })])

	# The server now deletes pk 2 and 3, as it would for any row it delivered.
	_deleted_pks.clear()
	_apply(&"keyed", [], [_keyed(2), _keyed(3)])
	print("on_delete fired for: %s" % [_deleted_pks])
	print("rows still cached: %d" % _db.get_all_rows(&"keyed").size())


func _probe_pk_less() -> void:
	print("=== PK-less table ===")
	_wipe_on_value = 10
	_apply(&"flat", [_flat(10), _flat(20), _flat(30)], [])
	_wipe_on_value = -1
	print("rows cached after the batch: %d" % _db.get_all_rows(&"flat").size())
	print("  counts buckets: %d" % (_db._pk_less_counts.get(&"flat", { }) as Dictionary).size())

	# Re-delivery of a value the mirror already lists (overlapping subscription).
	_apply(&"flat", [_flat(20)], [])
	print("after re-delivering value 20: %d rows cached" % _db.get_all_rows(&"flat").size())

	_deleted_values.clear()
	_apply(&"flat", [], [_flat(20), _flat(30)])
	print("on_delete fired for: %s" % [_deleted_values])
	print("rows still cached: %d" % _db.get_all_rows(&"flat").size())


func _on_keyed_insert(row: _ModuleTableType) -> void:
	if row.get(&"id") == _wipe_on_pk:
		_wipes += 1
		_db.clear_local_db()


func _on_keyed_delete(row: _ModuleTableType) -> void:
	_deleted_pks.append(row.get(&"id"))


func _on_flat_insert(row: _ModuleTableType) -> void:
	if row.get(&"value") == _wipe_on_value:
		_wipes += 1
		_db.clear_local_db()


func _on_flat_delete(row: _ModuleTableType) -> void:
	_deleted_values.append(row.get(&"value"))


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"flat", &"keyed"]
	schema.types[&"flat"] = _FlatRow
	schema.tables[&"flat"] = _FlatRow
	schema.types[&"keyed"] = _KeyedRow
	schema.tables[&"keyed"] = _KeyedRow
	return LocalDatabase.new(schema)


func _apply(table_name: StringName, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u)


func _keyed(id: int) -> _KeyedRow:
	return _KeyedRow.new(id)


func _flat(value: int) -> _FlatRow:
	return _FlatRow.new(value)


class _FlatRow:
	extends _ModuleTableType
	@export var value: int = 0


	func _init(p_value: int = 0) -> void:
		value = p_value


class _KeyedRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0


	func _init(p_id: int = 0) -> void:
		id = p_id

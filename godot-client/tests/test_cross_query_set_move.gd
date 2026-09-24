# Regression test: a row that moves from one query set to another inside one transaction
# must read as an update, not a delete followed by an insert.
#
# A game subscribing its area of interest one cell at a time (one query set per cell) sees
# an entity crossing between two subscribed cells as a delete in the old cell's set and an
# insert in the new cell's set, both in one TransactionUpdate. Applied set by set, the
# delete dropped the refcount to 0 (on_delete: the game despawned the entity) and the
# insert brought it back (on_insert: respawned). SpacetimeDBClient._inserts_before_deletes
# orders every set's inserts ahead of every set's deletes, so the insert lands on the
# still-held row (refcount 1 -> 2, on_update) and the delete only releases the old set's
# reference.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_cross_query_set_move.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase
var _deleted: int = 0
var _updated: int = 0
var _inserted: int = 0


class _Row:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var tag: int = 0


	static func make(p_id: int, p_tag: int = 0) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		r.tag = p_tag
		return r


func _initialize() -> void:
	var f: int = 0
	f += _case_move_delete_set_first()
	f += _case_move_insert_set_first()
	f += _case_unordered_control()
	f += _case_in_set_update_beside_other_set()
	f += _case_row_held_by_both_sets_updated()
	f += _case_real_leave_still_deletes()
	f += _case_single_set_passes_through()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	if is_instance_valid(_db):
		_db.free()
	quit(f)


## The failing order: the old cell's set (with the delete) comes first in the message.
func _case_move_delete_set_first() -> int:
	_fresh()
	_tx([_qset(1, [_Row.make(1, 10)], [])])
	_reset_counts()
	_tx([_qset(1, [], [_Row.make(1, 10)]), _qset(2, [_Row.make(1, 11)], [])])
	var f: int = _check_i("move del-first: no on_delete", _deleted, 0)
	f += _check_i("move del-first: no on_insert", _inserted, 0)
	f += _check_i("move del-first: one on_update", _updated, 1)
	f += _check_i("move del-first: refcount 1", _db._ref_counts[&"pk"][1], 1)
	f += _check_i("move del-first: new value", _db.get_all_rows(&"pk")[0].tag, 11)
	return f


func _case_move_insert_set_first() -> int:
	_fresh()
	_tx([_qset(1, [_Row.make(1, 10)], [])])
	_reset_counts()
	_tx([_qset(2, [_Row.make(1, 11)], []), _qset(1, [], [_Row.make(1, 10)])])
	var f: int = _check_i("move ins-first: no on_delete", _deleted, 0)
	f += _check_i("move ins-first: no on_insert", _inserted, 0)
	f += _check_i("move ins-first: one on_update", _updated, 1)
	f += _check_i("move ins-first: refcount 1", _db._ref_counts[&"pk"][1], 1)
	return f


## Without the ordering, the delete-first move is a despawn and respawn: the bug.
func _case_unordered_control() -> int:
	_fresh()
	_tx([_qset(1, [_Row.make(1, 10)], [])])
	_reset_counts()
	for dataset: DatabaseUpdateData in [_qset(1, [], [_Row.make(1, 10)]), _qset(2, [_Row.make(1, 11)], [])]:
		_db.apply_database_update(dataset)
	var f: int = _check_i("control: on_delete fires unordered", _deleted, 1)
	f += _check_i("control: on_insert fires unordered", _inserted, 1)
	return f


## An ordinary update inside one set, in a transaction that also touches another set.
func _case_in_set_update_beside_other_set() -> int:
	_fresh()
	_tx([_qset(1, [_Row.make(1, 10)], [])])
	_reset_counts()
	_tx([_qset(1, [_Row.make(1, 11)], [_Row.make(1, 10)]), _qset(2, [_Row.make(2, 0)], [])])
	var f: int = _check_i("beside: one on_update", _updated, 1)
	f += _check_i("beside: one on_insert (the other row)", _inserted, 1)
	f += _check_i("beside: no on_delete", _deleted, 0)
	f += _check_i("beside: refcount of updated row", _db._ref_counts[&"pk"][1], 1)
	f += _check_i("beside: updated value", _row(1).tag, 11)
	return f


## Overlapping sets both report the update: the refcount stays at 2, one on_update.
func _case_row_held_by_both_sets_updated() -> int:
	_fresh()
	_tx([_qset(1, [_Row.make(1, 10)], []), _qset(2, [_Row.make(1, 10)], [])])
	_reset_counts()
	_tx([_qset(1, [_Row.make(1, 11)], [_Row.make(1, 10)]), _qset(2, [_Row.make(1, 11)], [_Row.make(1, 10)])])
	var f: int = _check_i("both: refcount 2", _db._ref_counts[&"pk"][1], 2)
	f += _check_i("both: one on_update", _updated, 1)
	f += _check_i("both: no on_delete", _deleted, 0)
	f += _check_i("both: no on_insert", _inserted, 0)
	return f


## A row leaving every set is still a delete when another set's rows ride along.
func _case_real_leave_still_deletes() -> int:
	_fresh()
	_tx([_qset(1, [_Row.make(1, 10)], [])])
	_reset_counts()
	_tx([_qset(1, [], [_Row.make(1, 10)]), _qset(2, [_Row.make(2, 0)], [])])
	var f: int = _check_i("leave: on_delete", _deleted, 1)
	f += _check_i("leave: row gone", int(_row(1) != null), 0)
	return f


func _case_single_set_passes_through() -> int:
	var sets: Array[DatabaseUpdateData] = [_qset(1, [_Row.make(1, 11)], [_Row.make(1, 10)])]
	var out: Array[DatabaseUpdateData] = SpacetimeDBClient._inserts_before_deletes(sets)
	_total += 1
	if out == sets:
		print("PASS  single set returned as is")
		return 0
	printerr("FAIL  single set was rebuilt")
	return 1


func _fresh() -> void:
	if is_instance_valid(_db):
		_db.free()
	_reset_counts()
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"pk"] = &"id"
	var props: Array[StringName] = [&"id", &"tag"]
	_db._row_property_cache[&"pk"] = props
	_db.subscribe_to_deletes(&"pk", _on_delete)
	_db.subscribe_to_updates(&"pk", _on_update)
	_db.subscribe_to_inserts(&"pk", _on_insert)


func _reset_counts() -> void:
	_deleted = 0
	_updated = 0
	_inserted = 0


func _qset(query_id: int, ins: Array, del: Array) -> DatabaseUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"pk"
	u.inserts.assign(ins)
	u.deletes.assign(del)
	var d: DatabaseUpdateData = DatabaseUpdateData.new()
	d.query_id.id = query_id
	d.tables.append(u)
	return d


## One transaction, applied the way SpacetimeDBClient._handle_transaction_update does.
func _tx(sets: Array[DatabaseUpdateData]) -> void:
	for dataset: DatabaseUpdateData in SpacetimeDBClient._inserts_before_deletes(sets):
		_db.apply_database_update(dataset)


func _on_delete(_row_deleted: _ModuleTableType) -> void:
	_deleted += 1


func _on_update(_old_row: _ModuleTableType, _new_row: _ModuleTableType) -> void:
	_updated += 1


func _on_insert(_row_inserted: _ModuleTableType) -> void:
	_inserted += 1


func _row(id: int) -> _Row:
	for r: _Row in _db.get_all_rows(&"pk"):
		if r.id == id:
			return r
	return null


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

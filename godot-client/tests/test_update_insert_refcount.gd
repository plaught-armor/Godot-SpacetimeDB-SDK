# Regression test: a delete+insert of the same pk (the server's "update" encoding)
# for a pk the cache does not hold takes insert semantics, and must record the
# reference that delivery carries.
#
# It used to leave the refcount untouched, so the row landed in the cache at
# refcount 0 while the matching delete was consumed as part of the update. An
# unreferenced cached row is permanent: a later delete reads refcount 0, skips the
# row, and no on_delete ever fires — the row stays visible to every query helper
# for the rest of the session. The next delivery of that pk also fired a second
# on_insert for an already-cached row instead of on_update.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_update_insert_refcount.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const PkRow: GDScript = preload("res://tests/_test_pk_row.gd")

var _total: int = 0
var _inserts: int = 0
var _updates: int = 0
var _deletes: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var db: LocalDatabase = _mk_db()
	var f: int = 0

	# Update encoding for an uncached pk: insert semantics, and the delivery's
	# reference is recorded (the delete pass is skipped, so nothing else will).
	db.apply_table_update(_mk_update([_mk_row(5, 1)], [_mk_row(5, 2)]))
	f += _check_i("uncached update: insert fired", _inserts, 1)
	f += _check_i("uncached update: row cached", db._tables[&"tbl"].size(), 1)
	f += _check_i("uncached update: refcount recorded", _ref(db, 5), 1)

	# A later re-delivery of a still-cached pk is an update, not a second insert.
	_reset()
	db.apply_table_update(_mk_update([], [_mk_row(5, 3)]))
	f += _check_i("re-delivery: update fired", _updates, 1)
	f += _check_i("re-delivery: no duplicate insert", _inserts, 0)
	# Overlapping delivery, so the row is now held twice.
	f += _check_i("re-delivery: refcount bumped", _ref(db, 5), 2)

	# Both references have to be released before the row leaves the cache.
	_reset()
	db.apply_table_update(_mk_update([_mk_row(5, 3)], []))
	f += _check_i("first delete: row survives one release", db._tables[&"tbl"].size(), 1)
	f += _check_i("first delete: no delete fired", _deletes, 0)
	db.apply_table_update(_mk_update([_mk_row(5, 3)], []))
	f += _check_i("second delete: row evicted", db._tables[&"tbl"].size(), 0)
	f += _check_i("second delete: delete fired", _deletes, 1)
	f += _check_i("second delete: refcount dropped", _ref(db, 5), 0)

	# The plain case: one insert, one delete, evicted. The bug's control.
	var db2: LocalDatabase = _mk_db()
	_reset()
	db2.apply_table_update(_mk_update([], [_mk_row(9, 1)]))
	f += _check_i("plain insert: refcount recorded", _ref(db2, 9), 1)
	db2.apply_table_update(_mk_update([_mk_row(9, 1)], []))
	f += _check_i("plain delete: row evicted", db2._tables[&"tbl"].size(), 0)
	f += _check_i("plain delete: delete fired", _deletes, 1)

	# An update encoding for a pk already held by two query sets is net-zero: the
	# delete it carries is consumed as part of the update, so neither reference is
	# released and the recorded count must not change.
	var db3: LocalDatabase = _mk_db()
	_reset()
	db3.apply_table_update(_mk_update([], [_mk_row(4, 1)]))
	db3.apply_table_update(_mk_update([], [_mk_row(4, 1)])) # second query set, same row
	f += _check_i("held twice: refcount 2", _ref(db3, 4), 2)
	db3.apply_table_update(_mk_update([_mk_row(4, 1)], [_mk_row(4, 7)]))
	f += _check_i("update while held twice: refcount unchanged", _ref(db3, 4), 2)
	f += _check_i("update while held twice: row still cached", db3._tables[&"tbl"].size(), 1)

	# The same delivery tagged with a query id: the reference has to be recorded for
	# prune_query to find, or a SubscriptionError on that query leaves the row behind.
	var db4: LocalDatabase = _mk_db()
	_reset()
	db4.apply_table_update(_mk_update([_mk_row(3, 1)], [_mk_row(3, 2)]), 7)
	f += _check_i("tagged update: refcount recorded", _ref(db4, 3), 1)
	f += _check_i("tagged update: membership recorded", _query_mem(db4, 7), 1)
	db4.prune_query(7)
	f += _check_i("prune: row evicted", db4._tables[&"tbl"].size(), 0)
	f += _check_i("prune: delete fired", _deletes, 1)
	f += _check_i("prune: refcount dropped", _ref(db4, 3), 0)

	db.free()
	db2.free()
	db3.free()
	db4.free()
	return f


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"tbl"]
	# A table lives in both maps, exactly as _add_table_names writes it: `types` under
	# the normalized key for nested-column resolution, `tables` under the exact wire
	# name for everything that starts from a table name (row type, primary key).
	schema.types[&"tbl"] = PkRow
	schema.tables[&"tbl"] = PkRow
	var db: LocalDatabase = LocalDatabase.new(schema)
	db._tables[&"tbl"] = { }
	db.subscribe_to_inserts(&"tbl", _on_insert)
	db.subscribe_to_updates(&"tbl", _on_update)
	db.subscribe_to_deletes(&"tbl", _on_delete)
	return db


func _ref(db: LocalDatabase, pk: int) -> int:
	var per_table: Dictionary = db._ref_counts.get(&"tbl", { })
	return per_table.get(pk, 0)


func _query_mem(db: LocalDatabase, query_id: int) -> int:
	var tables: Dictionary = db._query_rows.get(query_id, { })
	var per_table: Dictionary = tables.get(&"tbl", { })
	return per_table.size()


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
	_deletes = 0


func _on_insert(_row: _ModuleTableType) -> void:
	_inserts += 1


func _on_update(_prev: _ModuleTableType, _cur: _ModuleTableType) -> void:
	_updates += 1


func _on_delete(_row: _ModuleTableType) -> void:
	_deletes += 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

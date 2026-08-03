# Regression test: the reconnect path must report the cache wipe to row listeners.
#
# _prepare_for_reconnect() used to wipe the mirror with LocalDatabase.clear_all_tables(),
# which empties the storage silently. A row deleted server-side while the client was
# away therefore left the mirror with no on_delete: the resubscribe re-inserted only
# the rows that still exist, and a consumer keyed by primary key kept whatever it had
# spawned for the rows that did not come back, for the rest of the session (in the
# Blackholio example, eaten food and departed players stayed on screen after every
# auto-reconnect). The wipe now runs through clear_local_db(), which emits
# before_delete/delete per row plus one transactions_completed per non-empty table,
# so a consumer tears its view down and rebuilds it from the resubscribe.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_reconnect_row_deletes.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const PkRow: GDScript = preload("res://tests/_test_pk_row.gd")
const PkLessRow: GDScript = preload("res://tests/_test_pk_less_row.gd")

var _total: int = 0
var _deletes: PackedInt64Array = []
var _before_deletes: PackedInt64Array = []
var _pk_less_deletes: int = 0
var _tx_completed: Array[StringName] = []
## "before:<id>" / "delete:<id>" in emission order, to pin before_delete → delete.
var _order: PackedStringArray = []


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	# Built with .new() and never added to the tree, so _ready (auto-connect, threads)
	# never runs — same harness as tests/test_reconnect_state.gd.
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var db: LocalDatabase = _mk_db()
	client._local_db = db

	# Two PK rows and one PK-less row in the mirror when the socket drops. The PK-less
	# row goes through apply_table_update too, so _pk_less_counts is populated the way a
	# real delivery would leave it.
	db.apply_table_update(_mk_update(&"tbl", [], [_mk_row(1, 10), _mk_row(2, 20)]), 0)
	db.apply_table_update(_mk_update(&"flat", [], [_ModuleTableType.new()]), 0)
	f += _check_i("setup: rows cached", db._tables[&"tbl"].size(), 2)
	f += _check_i("setup: pk-less row cached", db._pk_less_tables[&"flat"].size(), 1)

	# Setup emitted its own inserts and one transactions_completed per table; only what
	# the wipe reports is under test.
	_tx_completed.clear()
	_order.clear()

	client._prepare_for_reconnect()

	# Every cached row is reported as deleted, so a consumer can tear its view down.
	f += _check_i("wipe reported both PK rows", _deletes.size(), 2)
	f += _check_b("wipe reported row 1", _deletes.has(1), true)
	f += _check_b("wipe reported row 2", _deletes.has(2), true)
	f += _check_i("wipe reported the PK-less row", _pk_less_deletes, 1)
	# before_delete precedes each delete, so a handler that needs to read the row (or
	# rows related to it) while it is still queryable gets its chance here too.
	f += _check_i("wipe reported before_delete per row", _before_deletes.size(), 3)
	f += _check_s(
		"per-row order was before → delete",
		", ".join(_order),
		"before:1, delete:1, before:2, delete:2, before:flat, delete:flat",
	)
	# Exactly one per non-empty table, and nothing for a table that held no rows.
	f += _check_i("tbl got one transactions_completed", _tx_completed.count(&"tbl"), 1)
	f += _check_i("flat got one transactions_completed", _tx_completed.count(&"flat"), 1)
	f += _check_i("the empty table stayed silent", _tx_completed.count(&"empty"), 0)

	# And the mirror is empty, with its table keys intact so the resubscribe's updates
	# are not rejected as unknown tables.
	f += _check_i("mirror emptied", db._tables[&"tbl"].size(), 0)
	f += _check_i("pk-less mirror emptied", db._pk_less_tables[&"flat"].size(), 0)
	f += _check_b("table key survived", db._tables.has(&"tbl"), true)
	# State parity with the silent clear_all_tables it replaced: every refcount and
	# per-query membership map is reset too, not just the row storage.
	f += _check_i("refcounts dropped", db._ref_counts.get(&"tbl", { }).size(), 0)
	f += _check_i("pk-less refcounts dropped", db._pk_less_counts.get(&"flat", { }).size(), 0)
	f += _check_i("per-query membership dropped", db._query_rows.size(), 0)

	# The resubscribe refills it: row 2 is gone server-side and never returns, and the
	# consumer has already been told, so nothing is left stranded.
	db.apply_table_update(_mk_update(&"tbl", [], [_mk_row(1, 10)]), 0)
	f += _check_i("resubscribe refilled the mirror", db._tables[&"tbl"].size(), 1)
	f += _check_i("no extra delete from the refill", _deletes.size(), 2)

	client.free()
	db.free()
	return f


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	# `empty` is registered and stays empty — it must emit nothing at all.
	schema.raw_table_names = [&"tbl", &"flat", &"empty"]
	# A table lives in both maps, exactly as _add_table_names writes it: `types` under
	# the normalized key for nested-column resolution, `tables` under the exact wire
	# name for everything that starts from a table name (row type, primary key).
	schema.types[&"tbl"] = PkRow
	schema.tables[&"tbl"] = PkRow
	schema.types[&"flat"] = PkLessRow
	schema.tables[&"flat"] = PkLessRow
	schema.types[&"empty"] = PkRow
	schema.tables[&"empty"] = PkRow
	var db: LocalDatabase = LocalDatabase.new(schema)
	db.subscribe_to_deletes(&"tbl", _on_delete)
	db.subscribe_to_before_deletes(&"tbl", _on_before_delete)
	db.subscribe_to_deletes(&"flat", _on_pk_less_delete)
	db.subscribe_to_before_deletes(&"flat", _on_pk_less_before_delete)
	db.subscribe_to_deletes(&"empty", _on_delete)
	db.row_transactions_completed.connect(_on_tx_completed)
	return db


func _mk_row(id_val: int, v: int) -> Resource:
	var r: Resource = PkRow.new()
	r.id = id_val
	r.val = v
	return r


func _mk_update(table: StringName, deletes: Array, inserts: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	u.deletes.assign(deletes)
	u.inserts.assign(inserts)
	u.is_event = false
	return u


func _on_delete(row: _ModuleTableType) -> void:
	_deletes.append(row.id)
	_order.append("delete:%d" % row.id)


func _on_before_delete(row: _ModuleTableType) -> void:
	_before_deletes.append(row.id)
	_order.append("before:%d" % row.id)


func _on_pk_less_delete(_row: _ModuleTableType) -> void:
	_pk_less_deletes += 1
	_order.append("delete:flat")


func _on_pk_less_before_delete(_row: _ModuleTableType) -> void:
	_before_deletes.append(0)
	_order.append("before:flat")


func _on_tx_completed(table_name: StringName) -> void:
	_tx_completed.append(table_name)


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


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1

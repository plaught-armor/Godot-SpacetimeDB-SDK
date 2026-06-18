# Test for LocalDatabase.clear_local_db(). Verifies a cache wipe emits a delete
# callback per row (both the row_deleted signal AND per-table delete listeners)
# plus one row_transactions_completed per non-empty table, across both PK tables
# (_tables) and PK-less tables (_pk_less_tables), and leaves every table empty.
# Empty tables must emit nothing.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_clear_local_db.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0

# Emission counters wired to signals + per-table listeners.
var _signal_deletes: int = 0
var _signal_tx: Array[StringName] = []
var _listener_deletes: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	# Empty schema (no disk schema needed — we poke the tables directly). The bad
	# path just prints a load warning; raw_table_names is set by hand afterward.
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha", &"gamma"] # gamma stays empty
	var db: LocalDatabase = LocalDatabase.new(schema)

	# alpha: 2 PK rows. beta: 3 PK-less rows. gamma: empty.
	db._tables[&"alpha"][1] = _ModuleTableType.new()
	db._tables[&"alpha"][2] = _ModuleTableType.new()
	db._pk_less_tables[&"beta"] = [_ModuleTableType.new(), _ModuleTableType.new(), _ModuleTableType.new()]

	db.row_deleted.connect(_on_row_deleted)
	db.row_transactions_completed.connect(_on_tx_completed)
	db.subscribe_to_deletes(&"alpha", _on_listener_delete)

	db.clear_local_db()

	var f: int = 0
	# 2 alpha + 3 beta rows → 5 delete signals.
	f += _check_i("row_deleted count", _signal_deletes, 5)
	# Per-table delete listener registered only for alpha → 2 calls.
	f += _check_i("alpha delete listener count", _listener_deletes, 2)
	# One tx-completed per non-empty table (alpha, beta); gamma empty → skipped.
	f += _check_i("tx_completed count", _signal_tx.size(), 2)
	f += _check_b("alpha got tx_completed", _signal_tx.has(&"alpha"), true)
	f += _check_b("beta got tx_completed", _signal_tx.has(&"beta"), true)
	f += _check_b("gamma (empty) emitted nothing", _signal_tx.has(&"gamma"), false)
	# Storage emptied.
	f += _check_i("alpha rows after clear", db._tables[&"alpha"].size(), 0)
	f += _check_i("beta rows after clear", db._pk_less_tables[&"beta"].size(), 0)

	db.free()
	return f


func _on_row_deleted(_table_name: StringName, _row: _ModuleTableType) -> void:
	_signal_deletes += 1


func _on_tx_completed(table_name: StringName) -> void:
	_signal_tx.append(table_name)


func _on_listener_delete(_row: _ModuleTableType) -> void:
	_listener_deletes += 1


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

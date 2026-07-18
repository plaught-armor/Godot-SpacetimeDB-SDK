# Guards the Performance custom-monitor lifecycle on SpacetimeDBConnection.
#
# The client reuses one connection object across reconnects, so pointing it at a
# different database has to re-register the monitors under the new name —
# otherwise it keeps reporting under the old one AND leaks them, since teardown
# removes by the current name. Registration is driven from one suffix-to-getter
# table; this asserts register/rename/teardown stay symmetric with it.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_monitor_lifecycle.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_registers_under_db_name()
	fails += _test_rename_moves_every_monitor()
	fails += _test_no_monitors_when_disabled()
	fails += _test_teardown_removes_all()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _options(monitor: bool) -> SpacetimeDBConnectionOptions:
	var o: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	o.monitor_mode = monitor
	return o


func _ours(prefix: String) -> Array:
	var names: Array = []
	for n: StringName in Performance.get_custom_monitor_names():
		if String(n).begins_with(prefix):
			names.append(String(n))
	return names


func _test_registers_under_db_name() -> int:
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(_options(true), "alpha")
	var f: int = _check_i("registers 8 monitors", _ours("spacetime/alpha").size(), 8)
	conn.free()
	return f


# The rename path: same connection, different database.
func _test_rename_moves_every_monitor() -> int:
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(_options(true), "alpha")
	# connect_to_database bails before touching the socket without a token, but the
	# rename block runs first — which is the part under test.
	conn.connect_to_database("http://127.0.0.1:1", "beta", "deadbeef")
	var f: int = _check_i("old name fully released", _ours("spacetime/alpha").size(), 0)
	f += _check_i("new name fully registered", _ours("spacetime/beta").size(), 8)
	conn.free()
	f += _check_i("teardown after rename leaves none", _ours("spacetime/beta").size(), 0)
	return f


func _test_no_monitors_when_disabled() -> int:
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(_options(false), "gamma")
	var f: int = _check_i("monitor_mode off registers none", _ours("spacetime/gamma").size(), 0)
	conn.connect_to_database("http://127.0.0.1:1", "delta", "deadbeef")
	f += _check_i("rename with monitors off stays empty", _ours("spacetime/delta").size(), 0)
	conn.free()
	return f


func _test_teardown_removes_all() -> int:
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(_options(true), "epsilon")
	conn.free()
	return _check_i("free() removes every monitor", _ours("spacetime/epsilon").size(), 0)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

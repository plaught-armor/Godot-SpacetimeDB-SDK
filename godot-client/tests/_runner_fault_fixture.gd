# Fixture for the runner's own runtime-fault detection — NOT a test of the SDK. The
# leading underscore keeps it out of run_tests.sh's test_*.gd glob; run it by name:
#
#   cd godot-client && ./run_tests.sh _runner_fault_fixture
#
# Expected: FAIL ... runtime error. It passes one case, then calls a method that does
# not exist. The fault unwinds _run(), which returns the default int 0, so _initialize
# goes on to print ALL PASS and quit(0) — the exact shape that used to slip through the
# runner as ALL GREEN.
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	_total += 1
	print("PASS  a case that really did run")
	# The fault. Everything below it never executes.
	var s: SpacetimeDBStats = SpacetimeDBStats.new()
	s.call(&"no_such_method_on_stats")
	_total += 1
	printerr("FAIL  unreachable: the fault above ends _run()")
	return f + 1

# Unit test for SpacetimeDBConnection.is_stall_gap — the pure classifier behind
# the stall-aware reconnect. A poll gap at or beyond the heartbeat window means
# the main thread froze long enough for the engine to falsely close the socket on
# a missed pong; the connection then routes that close to a fast reconnect instead
# of the backoff ramp a real network drop would get.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_stall_detection.gd
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = 0

	# Gap below the threshold is normal frame cadence — not a stall.
	f += _check("16ms gap, 15s window", SpacetimeDBConnection.is_stall_gap(16, 15000), false)
	f += _check("0ms gap", SpacetimeDBConnection.is_stall_gap(0, 15000), false)

	# Gap at or beyond the threshold is a stall.
	f += _check("exactly at window", SpacetimeDBConnection.is_stall_gap(15000, 15000), true)
	f += _check("well past window", SpacetimeDBConnection.is_stall_gap(40000, 15000), true)
	f += _check("one ms over", SpacetimeDBConnection.is_stall_gap(15001, 15000), true)
	f += _check("one ms under", SpacetimeDBConnection.is_stall_gap(14999, 15000), false)

	# Threshold 0 means heartbeat disabled — the engine never auto-closes on a
	# missed pong, so no gap is ever a stall.
	f += _check("disabled: huge gap", SpacetimeDBConnection.is_stall_gap(999999, 0), false)
	f += _check("disabled: zero gap", SpacetimeDBConnection.is_stall_gap(0, 0), false)

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _check(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1

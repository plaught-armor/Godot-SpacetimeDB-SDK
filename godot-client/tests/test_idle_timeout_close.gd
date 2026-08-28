# A 1001 close carrying "idle timeout" has to say what stopped, not just that a socket
# closed.
#
# From the SpacetimeDB release that follows 2.8.3, a server that receives nothing from a
# client for the length of its idle timeout closes with a handshake rather than tearing
# the connection down, and the close frame carries the reason (`subscribe.rs`, `CloseFrame
# { code: CloseCode::Away, reason: "idle timeout" }`). Godot keeps that text on the peer
# until the next connect (`wsl_peer.cpp` clears `close_reason` only in reset), so it is
# readable at STATE_CLOSED. Older servers cannot reach this path at all: an idle timeout
# there arrives as an abnormal close with nothing to read.
#
# The code alone is not enough — a module that exited closes with 1001 as well — so the
# diagnostic is keyed on the code AND the reason.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_idle_timeout_close.gd
extends SceneTree

const TWO_MIB: int = 1024 * 1024 * 2

var _total: int = 0


func _initialize() -> void:
	var f: int = 0

	f += _check("close code is 1001", SpacetimeDBConnection.CLOSE_GOING_AWAY, 1001)
	f += _check(
		"reason matches the server's spelling",
		SpacetimeDBConnection.CLOSE_REASON_IDLE_TIMEOUT,
		"idle timeout",
	)

	var hint: String = SpacetimeDBConnection.close_diagnostic(
		SpacetimeDBConnection.CLOSE_GOING_AWAY,
		TWO_MIB,
		SpacetimeDBConnection.CLOSE_REASON_IDLE_TIMEOUT,
	)
	f += _check("an idle timeout carries a diagnostic", hint.is_empty(), false)

	# The reason is load-bearing: the other 1001 a server sends is a module that exited,
	# and answering that with the idle-timeout paragraph would send the reader after a
	# frame loop that was never the problem.
	f += _check(
		"another 1001 reason carries none",
		SpacetimeDBConnection.close_diagnostic(
			SpacetimeDBConnection.CLOSE_GOING_AWAY,
			TWO_MIB,
			"module exited",
		),
		"",
	)
	f += _check(
		"a 1001 with no reason carries none",
		SpacetimeDBConnection.close_diagnostic(SpacetimeDBConnection.CLOSE_GOING_AWAY, TWO_MIB, ""),
		"",
	)
	# And so is the code, or a server that ever puts those words on a clean 1000 would
	# have a normal disconnect reported as a fault.
	f += _check(
		"the reason alone is not enough",
		SpacetimeDBConnection.close_diagnostic(1000, TWO_MIB, "idle timeout"),
		"",
	)

	# The 1001 branch is tested first in the function, so this pins that it did not take
	# the oversized-message case with it.
	f += _check(
		"1009 still carries its own",
		(
			SpacetimeDBConnection
			.close_diagnostic(SpacetimeDBConnection.CLOSE_MESSAGE_TOO_BIG, TWO_MIB, "idle timeout")
			.contains("inbound_buffer_size")
		),
		true,
	)

	# What the text has to carry. The close reports a client that stopped running, so it
	# names the cause (a frame loop that stopped), the ordinary way that happens (an app
	# in the background), and the knob that shortens the recovery.
	f += _check("names the frame loop", hint.contains("frame loop"), true)
	f += _check("names the background case", hint.contains("backgrounded"), true)
	f += _check("names the resume option", hint.contains("reconnect_on_app_resume"), true)
	# The heartbeat is the first knob a reader reaches for and the wrong one: Godot
	# answers the server's ping from inside poll() whatever the heartbeat is set to.
	f += _check("rules out the heartbeat", hint.contains("heartbeat"), true)

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1

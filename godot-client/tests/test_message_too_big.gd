# A 1009 close is a configuration failure, and it has to say so.
#
# Godot hands `inbound_buffer_size` to wslay as the maximum receivable message
# length (`wsl_peer.cpp`, `wslay_event_config_set_max_recv_msg_length`), so a server
# message larger than that buffer is never delivered — wslay closes the socket with
# 1009 "Message too big". The server allows itself 32 MiB per message, sixteen times
# this client's default buffer, so this is reachable with a legal server payload.
# Reconnecting resubscribes the same queries and meets the same message, so the
# failure repeats until the attempt limit runs out.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_message_too_big.gd
extends SceneTree

const TWO_MIB: int = 1024 * 1024 * 2

var _total: int = 0


func _initialize() -> void:
	var f: int = 0

	# The code is the one wslay sends, not a SpacetimeDB-level code.
	f += _check("close code is 1009", SpacetimeDBConnection.CLOSE_MESSAGE_TOO_BIG, 1009)

	# Only codes a game cannot diagnose from the number carry a diagnostic. A normal
	# closure must stay on the quiet path, or every clean disconnect pushes an error.
	f += _check(
		"1006 carries no diagnostic",
		SpacetimeDBConnection.close_diagnostic(1006, TWO_MIB),
		"",
	)
	f += _check(
		"1000 carries no diagnostic",
		SpacetimeDBConnection.close_diagnostic(1000, TWO_MIB),
		"",
	)

	var hint: String = SpacetimeDBConnection.close_diagnostic(
		SpacetimeDBConnection.CLOSE_MESSAGE_TOO_BIG,
		TWO_MIB,
	)
	f += _check("1009 carries one", hint.is_empty(), false)

	# The number in the message has to be the buffer the game is running with — a
	# hardcoded "2 MB" would be wrong for anyone who already raised it.
	f += _check("hint names the configured size", hint.contains(str(TWO_MIB)), true)
	f += _check(
		"a raised buffer is reported as raised",
		(
			SpacetimeDBConnection
			.close_diagnostic(SpacetimeDBConnection.CLOSE_MESSAGE_TOO_BIG, TWO_MIB * 8)
			.contains(str(TWO_MIB * 8))
		),
		true,
	)

	# Each of the three ways out of it is worth naming: the option that caps the
	# read, the option that shrinks the payload, and the subscription that produced
	# it. Without these the log says only that a socket closed.
	f += _check("names the option", hint.contains("inbound_buffer_size"), true)
	f += _check("names compression", hint.contains("compression"), true)
	f += _check("names the subscription", hint.contains("subscription"), true)
	# Reconnect is deliberately not suppressed, so the text has to warn that the
	# resubscribe walks back into the same message rather than imply a recovery.
	f += _check("warns the resubscribe repeats it", hint.contains("same message again"), true)

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

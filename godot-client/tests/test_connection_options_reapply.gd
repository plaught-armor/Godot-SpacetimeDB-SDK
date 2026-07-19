# Unit test for the connection outliving its options.
#
# SpacetimeDBConnection reads its socket-level settings once, in _init. The client
# builds it on the FIRST connect_db and keeps it: a later disconnect_db() /
# connect_db(new_options) pair reaches `if _is_initialized:` and never touched the
# live connection, so the second call's compression preference, buffer sizes and
# heartbeat were silently discarded while the client's own fields showed the new
# values. Found by capturing a brotli fixture that came back gzip-tagged.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_connection_options_reapply.gd
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = _test_apply_options_replaces_socket_settings()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_apply_options_replaces_socket_settings() -> int:
	var first: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	first.compression = SpacetimeDBConnection.CompressionPreference.NONE
	first.heartbeat_interval_seconds = 5.0
	first.inbound_buffer_size = 1 << 16
	first.outbound_buffer_size = 1 << 15
	var connection: SpacetimeDBConnection = SpacetimeDBConnection.new(first, "blackholio")

	var f: int = _check_i(
		"the first options are in effect",
		connection.preferred_compression,
		SpacetimeDBConnection.CompressionPreference.NONE,
	)
	f += _check_i("stall threshold follows the heartbeat", connection._stall_threshold_ms, 5000)
	f += _check_i(
		"socket takes the first buffer size",
		connection._websocket.inbound_buffer_size,
		1 << 16,
	)

	var second: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	second.compression = SpacetimeDBConnection.CompressionPreference.BROTLI
	second.heartbeat_interval_seconds = 9.0
	second.inbound_buffer_size = 1 << 18
	second.outbound_buffer_size = 1 << 17
	connection.apply_options(second)

	f += _check_i(
		"a second connect's compression takes effect",
		connection.preferred_compression,
		SpacetimeDBConnection.CompressionPreference.BROTLI,
	)
	f += _check_i("stall threshold follows the new heartbeat", connection._stall_threshold_ms, 9000)
	# The socket settings are the ones the bug actually dropped, so assert the peer
	# itself rather than only the fields mirrored beside it.
	f += _check_i(
		"socket takes the new inbound buffer size",
		connection._websocket.inbound_buffer_size,
		1 << 18,
	)
	f += _check_i(
		"socket takes the new outbound buffer size",
		connection._websocket.outbound_buffer_size,
		1 << 17,
	)
	f += _check_i(
		"socket takes the new heartbeat",
		int(connection._websocket.heartbeat_interval),
		9,
	)
	f += _check_b("the options object itself is replaced", connection._options == second, true)

	connection.free()
	return f


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

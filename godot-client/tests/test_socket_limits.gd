# Regression test: a socket limit the engine cannot work with is refused, not passed on.
#
# SpacetimeDBConnectionOptions' drain knobs are resolved and clamped; its SOCKET knobs
# went straight to WebSocketPeer, and the engine answers a degenerate one by breaking
# quietly. Measured on 4.8.dev through the real client
# (tests/_probe_socket_limits.gd):
#   inbound_buffer_size = 0   the socket OPENS, is_connected_db() reads true, and every
#                             inbound message is dropped — no packet, no close, no
#                             error. The handshake never completed and nothing said so.
#   inbound_buffer_size = -1  "Condition p_size < 0 is true" out of CowData::resize on
#                             the first poll, and the headless process HANGS.
#   inbound_buffer_size 1<<31 the setter takes a C++ 32-bit int while a GDScript int is
#                             64-bit, so it reads back as -2147483648 — the hang again.
#                             1<<32 reads back as 0 — the silent drop again. "Give it
#                             plenty" was the dangerous input.
#   heartbeat_interval = -5.0 the engine refuses the setter and leaves the peer at 0.0
#                             (keepalive off), while the SDK's stall threshold derived
#                             from the same number went to -5000 (stall detection off) —
#                             so asking for a shorter interval disabled both detectors.
#   heartbeat_interval = 0.001 the same failure from the other end: a 1 ms stall threshold
#                             that an ordinary ~16 ms frame gap clears on every poll, so
#                             every real drop was reported as a local freeze and retried
#                             with no backoff. 0.0001 truncates the threshold to 0, which
#                             reads as "detection off".
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_socket_limits.gd
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_buffer_size()
	f += _test_interval()
	f += _test_applied_to_the_peer()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_buffer_size() -> int:
	var f: int = 0
	var default_size: int = SpacetimeDBConnection.DEFAULT_BUFFER_SIZE
	var minimum: int = SpacetimeDBConnection.MIN_BUFFER_SIZE
	# The two the engine breaks on.
	f += _check_i("negative", SpacetimeDBConnection.resolve_buffer_size(-1, "x"), default_size)
	f += _check_i("zero", SpacetimeDBConnection.resolve_buffer_size(0, "x"), default_size)
	# A value that is merely far too small for a message is the same failure, later.
	f += _check_i("one byte", SpacetimeDBConnection.resolve_buffer_size(1, "x"), default_size)
	f += _check_i(
		"one below the floor",
		SpacetimeDBConnection.resolve_buffer_size(minimum - 1, "x"),
		default_size,
	)
	# At and above the floor the caller's number is used untouched — the floor catches a
	# broken value, it does not second-guess a small one.
	f += _check_i("at the floor", SpacetimeDBConnection.resolve_buffer_size(minimum, "x"), minimum)
	f += _check_i("above the floor", SpacetimeDBConnection.resolve_buffer_size(65536, "x"), 65536)
	f += _check_i(
		"the default itself",
		SpacetimeDBConnection.resolve_buffer_size(default_size, "x"),
		default_size,
	)
	# The ceiling. WebSocketPeer's setter takes a C++ 32-bit int and a GDScript int is
	# 64-bit, so a big enough number does not fail — it truncates back into the two
	# failures the floor exists to catch: 1<<31 reads back negative (the hang) and 1<<32
	# reads back 0 (the silent drop). Clamped, not defaulted: "give it plenty" is a clear
	# intent and the 2 MiB default would be a cut of three orders of magnitude.
	var ceiling: int = SpacetimeDBConnection.MAX_BUFFER_SIZE
	f += _check_i(
		"at the ceiling",
		SpacetimeDBConnection.resolve_buffer_size(ceiling, "x"),
		ceiling,
	)
	f += _check_i(
		"one above the ceiling",
		SpacetimeDBConnection.resolve_buffer_size(ceiling + 1, "x"),
		ceiling,
	)
	f += _check_i(
		"2 GiB (wraps negative)",
		SpacetimeDBConnection.resolve_buffer_size(1 << 31, "x"),
		ceiling,
	)
	f += _check_i(
		"4 GiB (wraps to zero)",
		SpacetimeDBConnection.resolve_buffer_size(1 << 32, "x"),
		ceiling,
	)
	return f


func _test_interval() -> int:
	var f: int = 0
	# Zero is documented as "disabled" for both callers and must survive.
	f += _check_f(
		"zero stays zero",
		SpacetimeDBConnection.resolve_interval_seconds(0.0, 1.0, 15.0, "x"),
		0.0,
	)
	f += _check_f(
		"a positive interval is kept",
		SpacetimeDBConnection.resolve_interval_seconds(2.0, 1.0, 15.0, "x"),
		2.0,
	)
	# The floor, which the heartbeat needs and the handshake budget does not. A sub-second
	# heartbeat is the same silent failure from the other end: 0.001 gives a 1 ms stall
	# threshold, so an ordinary ~16 ms frame gap reads as a stall on every poll and every
	# real drop is then reported as a local freeze and retried with no backoff; 0.0001
	# truncates the threshold to 0, which reads as "detection off".
	f += _check_f(
		"a sub-second interval falls back",
		SpacetimeDBConnection.resolve_interval_seconds(0.001, 1.0, 15.0, "x"),
		15.0,
	)
	f += _check_f(
		"one that truncates the threshold to zero falls back",
		SpacetimeDBConnection.resolve_interval_seconds(0.0001, 1.0, 15.0, "x"),
		15.0,
	)
	f += _check_f(
		"at the floor",
		SpacetimeDBConnection.resolve_interval_seconds(1.0, 1.0, 15.0, "x"),
		1.0,
	)
	# A caller with no floor (the handshake budget) keeps an aggressive value: getting
	# that one wrong times every attempt out loudly, which is not the silent class.
	f += _check_f(
		"no floor keeps a small value",
		SpacetimeDBConnection.resolve_interval_seconds(0.5, 0.0, 15.0, "x"),
		0.5,
	)
	f += _check_f(
		"negative falls back",
		SpacetimeDBConnection.resolve_interval_seconds(-5.0, 1.0, 15.0, "x"),
		15.0,
	)
	f += _check_f(
		"a hair negative falls back",
		SpacetimeDBConnection.resolve_interval_seconds(-0.001, 1.0, 3.0, "x"),
		3.0,
	)
	# Both callers turn the result into milliseconds, and int(INF * 1000.0) is INT64_MIN —
	# negative, so every threshold derived from it stops firing. An infinite interval
	# would have restored the wait-forever behaviour the option's doc says it cannot.
	f += _check_f(
		"infinite falls back",
		SpacetimeDBConnection.resolve_interval_seconds(INF, 1.0, 15.0, "x"),
		15.0,
	)
	f += _check_f(
		"negative infinite falls back",
		SpacetimeDBConnection.resolve_interval_seconds(-INF, 1.0, 15.0, "x"),
		15.0,
	)
	# NaN fails every comparison, so it falls back too; pinned so a rewrite to
	# `if value < 0.0` shows up here rather than in a game.
	f += _check_f(
		"NaN falls back",
		SpacetimeDBConnection.resolve_interval_seconds(NAN, 1.0, 15.0, "x"),
		15.0,
	)
	# INF is not the only value that overflows the ×1000: measured on 4.8.dev, any finite
	# value from about 9.3e15 seconds up converts to INT64_MIN just the same, so the bound
	# is a magnitude, not an is_finite() check.
	var ceiling: float = SpacetimeDBConnection.MAX_INTERVAL_SECONDS
	f += _check_f(
		"at the interval ceiling",
		SpacetimeDBConnection.resolve_interval_seconds(ceiling, 1.0, 15.0, "x"),
		ceiling,
	)
	f += _check_f(
		"past the interval ceiling falls back",
		SpacetimeDBConnection.resolve_interval_seconds(ceiling + 1.0, 1.0, 15.0, "x"),
		15.0,
	)
	f += _check_f(
		"a finite value that overflows the milliseconds falls back",
		SpacetimeDBConnection.resolve_interval_seconds(9.3e15, 1.0, 15.0, "x"),
		15.0,
	)
	return f


# What actually reaches the peer, including after the peer is replaced — _reset_peer used
# to re-read the raw options, so a refused value would have come back on every reconnect.
func _test_applied_to_the_peer() -> int:
	var f: int = 0
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.inbound_buffer_size = 0
	options.outbound_buffer_size = -1
	options.heartbeat_interval_seconds = -5.0
	options.connect_timeout_seconds = -2.0
	var connection: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "probedb")

	var default_size: int = SpacetimeDBConnection.DEFAULT_BUFFER_SIZE
	f += _check_i("peer inbound", connection._websocket.inbound_buffer_size, default_size)
	f += _check_i("peer outbound", connection._websocket.outbound_buffer_size, default_size)
	f += _check_f(
		"peer heartbeat",
		connection._websocket.heartbeat_interval,
		SpacetimeDBConnection.DEFAULT_HEARTBEAT_SECONDS,
	)
	# The stall guard and the handshake budget read the resolved numbers, so both stay on.
	f += _check_i("stall threshold", connection._stall_threshold_ms, 15000)
	f += _check_i("handshake budget", connection._connect_timeout_ms, 15000)

	connection._reset_peer()
	f += _check_i("fresh peer inbound", connection._websocket.inbound_buffer_size, default_size)
	f += _check_i("fresh peer outbound", connection._websocket.outbound_buffer_size, default_size)
	f += _check_f(
		"fresh peer heartbeat",
		connection._websocket.heartbeat_interval,
		SpacetimeDBConnection.DEFAULT_HEARTBEAT_SECONDS,
	)

	# A usable set is passed through unchanged, floor included.
	var good: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	good.inbound_buffer_size = SpacetimeDBConnection.MIN_BUFFER_SIZE
	good.outbound_buffer_size = 65536
	good.heartbeat_interval_seconds = 0.0 # documented: keepalive off
	connection.apply_options(good)
	f += _check_i(
		"usable inbound kept",
		connection._websocket.inbound_buffer_size,
		SpacetimeDBConnection.MIN_BUFFER_SIZE,
	)
	f += _check_i("usable outbound kept", connection._websocket.outbound_buffer_size, 65536)
	f += _check_f(
		"keepalive can still be turned off",
		connection._websocket.heartbeat_interval,
		0.0,
	)
	f += _check_i("stall detection off with it", connection._stall_threshold_ms, 0)

	# A sub-second heartbeat through the real apply path: the peer and the stall threshold
	# both take the default, so an ordinary frame gap cannot arm the stall guard.
	var twitchy: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	twitchy.heartbeat_interval_seconds = 0.001
	connection.apply_options(twitchy)
	f += _check_f(
		"sub-second heartbeat refused at the peer",
		connection._websocket.heartbeat_interval,
		SpacetimeDBConnection.DEFAULT_HEARTBEAT_SECONDS,
	)
	f += _check_i("and at the stall threshold", connection._stall_threshold_ms, 15000)
	f += _check_b(
		"a 16 ms frame gap is not a stall",
		SpacetimeDBConnection.is_stall_gap(16, connection._stall_threshold_ms),
		false,
	)

	# A number the engine would truncate reaches the PEER intact — asserting the resolved
	# member alone would pass with the ceiling deleted.
	var huge: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	huge.inbound_buffer_size = 1 << 31
	huge.outbound_buffer_size = 1 << 32
	connection.apply_options(huge)
	f += _check_i(
		"peer inbound survives 2 GiB",
		connection._websocket.inbound_buffer_size,
		SpacetimeDBConnection.MAX_BUFFER_SIZE,
	)
	f += _check_i(
		"peer outbound survives 4 GiB",
		connection._websocket.outbound_buffer_size,
		SpacetimeDBConnection.MAX_BUFFER_SIZE,
	)

	# The diagnostics name the size the socket is RUNNING with, not the refused option —
	# they used to read the raw resource, so a refused 0 was reported as "0 bytes".
	var refused: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	refused.inbound_buffer_size = 0
	connection.apply_options(refused)
	f += _check_i("diagnostic size", connection._inbound_buffer_size, default_size)
	var diagnostic: String = SpacetimeDBConnection.dropped_message_diagnostic(
		connection._inbound_buffer_size
	)
	f += _check_b("diagnostic names the running size", diagnostic.contains(str(default_size)), true)

	connection.free()
	return f

# --- harness ---


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


func _check_f(label: String, got: float, want: float) -> int:
	_total += 1
	if is_equal_approx(got, want):
		print("PASS  %s = %f" % [label, got])
		return 0
	printerr("FAIL  %s: got %f want %f" % [label, got, want])
	return 1

# Regression test: a message too large for the outbound buffer is refused with a
# diagnostic naming the knob, not handed to an engine that answers with a bare
# ERR_OUT_OF_MEMORY.
#
# Measured on 4.8.dev through a real client and a real socket
# (tests/_probe_outbound_send.gd):
#   outbound_buffer_size = 4096, a reducer with an 8192-byte string argument
#       -> WebSocketPeer.send returns ERR_OUT_OF_MEMORY and the engine prints
#          'Condition "outbound_buffer_size > 0 && (wslay_event_get_queued_msg_length(
#          wsl_ctx) + p_buffer_size > (uint32_t)outbound_buffer_size)" is true' naming a
#          C++ file, while the SDK printed "Error sending CallReducer message: 6". Neither
#          line names outbound_buffer_size, its default, or the fact that the failure is
#          permanent for that message — the same call retried forever cannot succeed.
#   the boundary is exact: the largest string argument that went out under a 4096-byte
#       buffer was 4068 bytes, i.e. a 4096-byte message, because the engine's test is
#       `queued + size > buffer`. A message the size of the buffer fits.
#   the same ERR_OUT_OF_MEMORY also means the opposite thing: with the default 2 MiB
#       buffer and a server that stopped reading, 7 x 512 KiB messages were accepted and
#       the 8th was refused. That one IS worth retrying, so it gets its own diagnostic.
#
# NOT covered here, and named rather than faked: the BACKPRESSURE branch's own key. It
# only runs when the engine answers ERR_OUT_OF_MEMORY for a message that FITS, which needs
# a real peer that has stopped reading — and how much a kernel absorbs before that happens
# is not a number a test can rely on. tests/_probe_outbound_send.gd drives it by hand.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_outbound_send_limit.gd
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_oversized_boundary()
	f += _test_oversized_text()
	f += _test_backpressure_text()
	f += _test_send_bytes_refuses()
	f += _test_reported_cause()
	f += _test_close_reason_fits()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


# The boundary the engine actually enforces, not one either side of it.
func _test_oversized_boundary() -> int:
	var f: int = 0
	f += _check_b(
		"well under the buffer fits",
		SpacetimeDBConnection.oversized_send_diagnostic(1, 4096, false).is_empty(),
		true,
	)
	f += _check_b(
		"one below the buffer fits",
		SpacetimeDBConnection.oversized_send_diagnostic(4095, 4096, false).is_empty(),
		true,
	)
	# Measured: a 4096-byte message goes out under a 4096-byte buffer.
	f += _check_b(
		"exactly the buffer fits",
		SpacetimeDBConnection.oversized_send_diagnostic(4096, 4096, false).is_empty(),
		true,
	)
	f += _check_b(
		"one over the buffer is refused",
		SpacetimeDBConnection.oversized_send_diagnostic(4097, 4096, false).is_empty(),
		false,
	)
	f += _check_b(
		"far over the buffer is refused",
		SpacetimeDBConnection
		.oversized_send_diagnostic(SpacetimeDBConnection.MAX_BUFFER_SIZE, SpacetimeDBConnection.DEFAULT_BUFFER_SIZE, false)
		.is_empty(),
		false,
	)
	# An empty message is not a size failure whatever the buffer says.
	f += _check_b(
		"an empty message fits",
		SpacetimeDBConnection.oversized_send_diagnostic(0, 4096, false).is_empty(),
		true,
	)

	# The Web peer refuses at >= where the desktop peer refuses at > (EMWSPeer::_send vs
	# WSLPeer::_send), so a message the exact size of the buffer goes out on one and not
	# the other. Getting this wrong on Web is worse than a missing message: the size test
	# passes, the engine refuses anyway, and the send is then described as backpressure —
	# "the remote is not reading, try again" about a message that can never go out.
	f += _check_i(
		"desktop can send a message the size of the buffer",
		SpacetimeDBConnection.largest_sendable_message(4096, false),
		4096,
	)
	f += _check_i(
		"web is one byte short of it",
		SpacetimeDBConnection.largest_sendable_message(4096, true),
		4095,
	)
	f += _check_b(
		"exactly the buffer is refused on web",
		SpacetimeDBConnection.oversized_send_diagnostic(4096, 4096, true).is_empty(),
		false,
	)
	f += _check_b(
		"one below the buffer still fits on web",
		SpacetimeDBConnection.oversized_send_diagnostic(4095, 4096, true).is_empty(),
		true,
	)
	return f


# What the refusal has to say to be worth more than the engine's line: the size that was
# refused, the number bounding it, the knob that moves that number, and the ceiling.
func _test_oversized_text() -> int:
	var f: int = 0
	var text: String = SpacetimeDBConnection.oversized_send_diagnostic(9001, 4096, false)
	f += _check_b("names the refused size", text.contains("9001"), true)
	f += _check_b("names the running buffer", text.contains("4096"), true)
	f += _check_b("names the knob", text.contains("outbound_buffer_size"), true)
	f += _check_b(
		"names the ceiling",
		text.contains(str(SpacetimeDBConnection.MAX_BUFFER_SIZE)),
		true,
	)
	# Retrying this message cannot help, and the connection is fine — both are the point
	# of the message, and neither is derivable from ERR_OUT_OF_MEMORY.
	f += _check_b("says a retry cannot work", text.contains("no number of retries"), true)
	f += _check_b("says nothing partial went out", text.contains("Nothing partial"), true)
	# At the ceiling "raise it" is not advice, it is the state the caller is already in.
	var at_ceiling: String = SpacetimeDBConnection.oversized_send_diagnostic(
		SpacetimeDBConnection.MAX_BUFFER_SIZE + 1,
		SpacetimeDBConnection.MAX_BUFFER_SIZE,
		false,
	)
	f += _check_b("at the ceiling it does not say to raise it", at_ceiling.contains("Raise"), false)
	f += _check_b(
		"at the ceiling it says there is no room above",
		at_ceiling.contains("no room above"),
		true,
	)
	f += _check_b("below the ceiling it does say to raise it", text.contains("Raise"), true)
	return f


# The other ERR_OUT_OF_MEMORY. Same code, opposite advice: this one is transient.
#
# Every number is distinct so an argument in the wrong position shows up as a wrong
# number rather than as the same text.
func _test_backpressure_text() -> int:
	var f: int = 0
	var text: String = SpacetimeDBConnection.send_backpressure_diagnostic(
		ERR_OUT_OF_MEMORY,
		512,
		1_048_576,
		2_097_152,
		4096,
		false,
	)
	f += _check_b("names the refused size", text.contains("512"), true)
	f += _check_b("names the queued bytes", text.contains("1048576"), true)
	f += _check_b("names the running buffer", text.contains("2097152"), true)
	f += _check_b("names the queued-message ceiling", text.contains("4096"), true)
	f += _check_b("names the knob", text.contains("outbound_buffer_size"), true)
	f += _check_b("names the remote as the cause", text.contains("remote not reading"), true)
	f += _check_b("says the next one may work", text.contains("next one may"), true)
	f += _check_b(
		"is distinguishable from the oversized one",
		text != SpacetimeDBConnection.oversized_send_diagnostic(9001, 4096, false),
		true,
	)
	# ERR_OUT_OF_MEMORY is the only code the engine answers a full queue with; every
	# other failure of WebSocketPeer.send is FAILED, and describing one of those as
	# backpressure would send the reader after a remote that is not the problem.
	f += _check_b(
		"says nothing about a socket that is not open",
		SpacetimeDBConnection
		.send_backpressure_diagnostic(FAILED, 512, 0, 4096, 4096, false)
		.is_empty(),
		true,
	)
	f += _check_b(
		"says nothing about a send that worked",
		SpacetimeDBConnection.send_backpressure_diagnostic(OK, 512, 0, 4096, 4096, false).is_empty(),
		true,
	)
	# The message-count ceiling is the desktop peer's second test and does not exist on
	# Web (EMWSPeer::_send has only the byte test), so offering it there would name a
	# cause that cannot be the cause.
	var web_text: String = SpacetimeDBConnection.send_backpressure_diagnostic(
		ERR_OUT_OF_MEMORY,
		512,
		1_048_576,
		2_097_152,
		4096,
		true,
	)
	f += _check_b("web still names the queued bytes", web_text.contains("1048576"), true)
	f += _check_b("web does not offer a message ceiling", web_text.contains("ceiling"), false)
	f += _check_b("desktop does", text.contains("ceiling"), true)
	return f


# Delivery: the guard is in send_bytes, and it reads the RESOLVED buffer size, not the
# raw option — an option the resolver refused must not become the send limit.
func _test_send_bytes_refuses() -> int:
	var f: int = 0
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.outbound_buffer_size = SpacetimeDBConnection.MIN_BUFFER_SIZE
	var connection: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "probedb")
	f += _check_i(
		"the resolved size is what was asked for",
		connection._outbound_buffer_size,
		SpacetimeDBConnection.MIN_BUFFER_SIZE,
	)

	var over: PackedByteArray = _bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE + 1)
	f += _check_i("a message over the buffer", connection.send_bytes(over), ERR_OUT_OF_MEMORY)
	# And the guard is not a blanket refusal: a message that fits reaches the engine,
	# which refuses it for its own reason (the socket was never opened) with a different
	# code. The engine prints its ERR_FAIL_COND line here; that is the engine, not a fault.
	# Not pinned as FAILED: which code the engine answers a closed socket with is the
	# engine's business, and the claim here is only that the SDK did not refuse it.
	var fits: PackedByteArray = _bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE)
	f += _check_b(
		"a message that fits reaches the engine",
		connection.send_bytes(fits) != ERR_OUT_OF_MEMORY,
		true,
	)
	connection.free()

	# A refused option falls back to the 2 MiB default, so a message the raw option would
	# have rejected has to go through. Reading options.outbound_buffer_size in send_bytes
	# instead of the resolved member fails exactly here.
	var poisoned: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	poisoned.outbound_buffer_size = 0
	var fallback: SpacetimeDBConnection = SpacetimeDBConnection.new(poisoned, "probedb")
	f += _check_i(
		"a refused option resolved to the default",
		fallback._outbound_buffer_size,
		SpacetimeDBConnection.DEFAULT_BUFFER_SIZE,
	)
	f += _check_b(
		"a message the refused option would have rejected is not refused here",
		fallback.send_bytes(_bytes(65536)) != ERR_OUT_OF_MEMORY,
		true,
	)
	fallback.free()
	return f


# What the game is TOLD, not only what send_bytes returned. push_error is not observable
# in-process, so the CAUSE the report was made under is held on the connection
# (_send_refusal) and read here: without this, deleting either report — or widening the
# backpressure branch to every failure — leaves the whole suite green.
func _test_reported_cause() -> int:
	var f: int = 0
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.outbound_buffer_size = SpacetimeDBConnection.MIN_BUFFER_SIZE
	var connection: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "reportdb")
	f += _check_i(
		"nothing reported before a send",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.NONE,
	)

	# A message that fits, on a socket that was never opened: the engine refuses it with
	# FAILED, which is NOT backpressure and must not be described as it.
	connection.send_bytes(_bytes(64))
	f += _check_i(
		"a closed socket is not reported as backpressure",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.NONE,
	)

	connection.send_bytes(_bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE + 1))
	f += _check_i(
		"an oversized message is reported as oversized",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.OVERSIZED,
	)

	# A cause CHANGE is what earns a report, so the state has to move when the cause does
	# — the throttle suppresses a repeat, not a different condition.
	connection._send_refusal = SpacetimeDBConnection.SendRefusal.BACKPRESSURE
	connection.send_bytes(_bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE + 1))
	f += _check_i(
		"a new cause replaces the old one",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.OVERSIZED,
	)

	# A fresh peer re-arms: the queue is new.
	connection._reset_peer()
	f += _check_i(
		"a new peer re-arms the report",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.NONE,
	)

	# The boundary MOVING is what makes a suppressed repeat wrong: the last report's
	# numbers stop being true, and a stale wrong number is worse than a repeat.
	connection.send_bytes(_bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE + 1))
	f += _check_i(
		"the refusal remembers the boundary it was reported against",
		connection._send_refusal_limit,
		SpacetimeDBConnection.MIN_BUFFER_SIZE,
	)
	f += _check_i(
		"and the size it was reported for",
		connection._send_refusal_size,
		SpacetimeDBConnection.MIN_BUFFER_SIZE + 1,
	)
	# A different oversized message is a different problem — two call sites must not
	# collapse into one report, or the second is silent for the rest of the session.
	connection.send_bytes(_bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE + 99))
	f += _check_i(
		"a different oversized message is reported on its own",
		connection._send_refusal_size,
		SpacetimeDBConnection.MIN_BUFFER_SIZE + 99,
	)
	var wider: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	wider.outbound_buffer_size = SpacetimeDBConnection.MIN_BUFFER_SIZE * 2
	connection.apply_options(wider)
	connection.send_bytes(_bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE * 2 + 1))
	f += _check_i(
		"a moved boundary is reported again",
		connection._send_refusal_limit,
		SpacetimeDBConnection.MIN_BUFFER_SIZE * 2,
	)

	# A new session reports its own refusals: the peer object survives a reconnect, so
	# _reset_peer is not on that path and cannot be what does this.
	connection.set_token("eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig")
	connection.connect_to_database("http://127.0.0.1:1", "probedb", "0")
	f += _check_i(
		"a new connection re-arms the report",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.NONE,
	)
	f += _check_i("and forgets the old boundary", connection._send_refusal_limit, 0)
	connection.disconnect_from_server()
	connection.free()

	# The platform split is only as good as the feature tag, and OS.has_feature matches
	# exactly: "Web" is permanently false, which would put every Web build back on the
	# desktop boundary with nothing to notice it. Asserted against the production constant
	# — a desktop run cannot exercise the Web path, but it can pin how it is spelled.
	f += _check_b(
		"the web feature tag is spelled the way the engine defines it",
		SpacetimeDBConnection.WEB_FEATURE_TAG == "web",
		true,
	)
	return f


# The other value this SDK hands the engine on the way out. A reason over the frame's
# limit makes wslay refuse to queue the close frame at all, and WSLPeer::close ignores
# that and moves to STATE_CLOSING regardless — a socket that never closes. Measured, with
# the wedge and the fix both driven, in tests/_probe_outbound_send.gd; only the boundary
# is testable here, since the trim runs on an active peer.
func _test_close_reason_fits() -> int:
	var f: int = 0
	var limit: int = SpacetimeDBConnection.MAX_CLOSE_REASON_BYTES
	f += _check_i("the limit is the frame's", limit, 123)
	var default_reason: String = "Client initiated disconnect"
	f += _check_b(
		"the SDK's own default is sent unchanged",
		SpacetimeDBConnection.fit_close_reason(default_reason) == default_reason,
		true,
	)
	f += _check_b("empty is unchanged", SpacetimeDBConnection.fit_close_reason("").is_empty(), true)
	var exact: String = "a".repeat(limit)
	f += _check_b(
		"exactly the limit is unchanged",
		SpacetimeDBConnection.fit_close_reason(exact) == exact,
		true,
	)
	f += _check_i(
		"one over is trimmed to the limit",
		SpacetimeDBConnection.fit_close_reason("a".repeat(limit + 1)).to_utf8_buffer().size(),
		limit,
	)
	f += _check_i(
		"far over is trimmed to the limit",
		SpacetimeDBConnection.fit_close_reason("a".repeat(4000)).to_utf8_buffer().size(),
		limit,
	)
	# Trimming by character, not by byte: a cut inside a multi-byte sequence would put a
	# broken sequence on the wire. "é" is two bytes, so the fit lands one byte short.
	var multibyte: String = "é".repeat(200)
	var trimmed: String = SpacetimeDBConnection.fit_close_reason(multibyte)
	f += _check_i("multi-byte trims to a whole character", trimmed.to_utf8_buffer().size(), 122)
	f += _check_b(
		"and survives a round trip",
		trimmed.to_utf8_buffer().get_string_from_utf8() == trimmed,
		true,
	)
	return f

# --- harness ---


func _bytes(size: int) -> PackedByteArray:
	var out: PackedByteArray = []
	out.resize(size)
	return out


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

# Regression test: the two outbound facts that are only true on an OPEN socket, so the
# pure-function tests in test_outbound_send_limit.gd cannot reach them.
#
# 1. A close reason longer than a close frame can carry left the socket OPEN FOREVER.
#    wslay refuses a reason over 123 UTF-8 bytes (WSLAY_ERR_INVALID_ARGUMENT,
#    wslay_event.c) and WSLPeer::close ignores that return and moves the peer to
#    STATE_CLOSING anyway, so no close frame is ever queued: close_sent stays false, the
#    peer never reaches STATE_CLOSED on its own, is_websocket_active() stays true, and the
#    server keeps the session alive with nothing but its own idle limit to end it.
#    Measured here both ways — straight at the engine (still wedges) and through
#    disconnect_from_server (closes).
# 2. A refusal is reported once per CAUSE, and a successful send clears only the transient
#    one. Clearing on any success re-armed the permanent one, which reported the same
#    paragraph every frame for the shape the throttle exists for: a bulk call refused while
#    ordinary traffic keeps succeeding.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_outbound_socket_close.gd
extends SceneTree

const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 240
const LONG_REASON: String = "why we left: why we left: why we left: why we left: why we left: why we left: why we left: why we left: why we left: why we left:"

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if LONG_REASON.to_utf8_buffer().size() <= SpacetimeDBConnection.MAX_CLOSE_REASON_BYTES:
		printerr("FAIL  the fixture reason is not long enough to test anything")
		quit(1)
		return
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("FAIL  could not open a listener")
		quit(1)
		return

	await _test_engine_still_wedges()
	await _test_sdk_close_completes()
	await _test_oversized_survives_a_successful_send()

	_server.stop()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# The engine defect this fix exists for. If a future Godot queues the close frame anyway,
# this fails and the trim can go.
func _test_engine_still_wedges() -> void:
	var connection: SpacetimeDBConnection = await _open_connection()
	if connection == null:
		return
	connection._websocket.close(1000, LONG_REASON)
	# Short bound on purpose: the assertion below is that CLOSED never arrives, so waiting
	# out the full budget would spend seconds proving nothing.
	await _settle(connection, 20)
	_check_i(
		"ENGINE STILL BROKEN: an over-long reason leaves the peer in STATE_CLOSING",
		connection._websocket.get_ready_state(),
		WebSocketPeer.STATE_CLOSING,
	)
	await _teardown(connection)


func _test_sdk_close_completes() -> void:
	var connection: SpacetimeDBConnection = await _open_connection()
	if connection == null:
		return
	connection.disconnect_from_server(1000, LONG_REASON)
	await _settle(connection)
	_check_i(
		"the SDK's close reaches STATE_CLOSED",
		connection._websocket.get_ready_state(),
		WebSocketPeer.STATE_CLOSED,
	)
	_check_b("and the socket is no longer active", connection.is_websocket_active(), false)
	# What the other end actually received, not only what this end thinks it sent.
	var wire_reason: String = _peer.get_close_reason()
	_check_i("the server got a close code", _peer.get_close_code(), 1000)
	_check_i(
		"and a reason a frame can carry",
		wire_reason.to_utf8_buffer().size(),
		SpacetimeDBConnection.MAX_CLOSE_REASON_BYTES,
	)
	_check_b(
		"which is the head of what was asked for",
		LONG_REASON.begins_with(wire_reason) and not wire_reason.is_empty(),
		true,
	)
	await _teardown(connection)


func _test_oversized_survives_a_successful_send() -> void:
	var options: SpacetimeDBConnectionOptions = _options()
	options.outbound_buffer_size = SpacetimeDBConnection.MIN_BUFFER_SIZE
	var connection: SpacetimeDBConnection = await _open_connection(options)
	if connection == null:
		return
	var over: PackedByteArray = _bytes(SpacetimeDBConnection.MIN_BUFFER_SIZE + 1)
	_check_i("an oversized send is refused", connection.send_bytes(over), ERR_OUT_OF_MEMORY)
	_check_i(
		"and reported as oversized",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.OVERSIZED,
	)

	# The send that works is the whole point: it proves the queue is fine, which says
	# nothing about a message that is too big to ever fit in it.
	_check_i("a small send on the same socket works", connection.send_bytes(_bytes(64)), OK)
	_check_i(
		"the oversized cause is not re-armed by it",
		connection._send_refusal,
		SpacetimeDBConnection.SendRefusal.OVERSIZED,
	)
	await _teardown(connection)

# --- harness ---


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.debug_mode = false
	options.connect_timeout_seconds = 4.0
	return options


# A real SpacetimeDBConnection with a real WebSocket open against a loopback listener.
# No SpacetimeDBClient: the facts under test are the transport's.
func _open_connection(options: SpacetimeDBConnectionOptions = null) -> SpacetimeDBConnection:
	var resolved: SpacetimeDBConnectionOptions = options if options != null else _options()
	var connection: SpacetimeDBConnection = SpacetimeDBConnection.new(resolved, "probedb")
	connection.name = "OutboundCloseProbe"
	root.add_child(connection)
	connection.set_token(FAKE_TOKEN)
	connection.connect_to_database(
		"http://127.0.0.1:%d" % _server.get_local_port(),
		"probedb",
		"00000000000000000000000000000000",
	)

	_peer = null
	for i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			if _peer.accept_stream(_stream) != OK:
				break
		if _peer == null:
			continue
		_peer.poll()
		if (
			_peer.get_ready_state() == WebSocketPeer.STATE_OPEN
			and connection._websocket.get_ready_state() == WebSocketPeer.STATE_OPEN
		):
			return connection

	_check_b("the socket opened", false, true)
	await _teardown(connection)
	return null


# Both peers polled until the client's socket settles, bounded rather than timed: a close
# needs the other side to answer, and the client's own poll runs on the physics frame.
# Polls a few frames past CLOSED so the server peer sees the frame too.
func _settle(connection: SpacetimeDBConnection, frames: int = MAX_WAIT_FRAMES) -> void:
	var after_closed: int = 0
	for i: int in frames:
		if _peer != null:
			_peer.poll()
		await physics_frame
		if connection._websocket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			after_closed += 1
			if after_closed >= 3:
				return
	# Not a failure on its own — the wedge scenario expects to sit in STATE_CLOSING — so
	# the caller's assertion is what decides.
	if _peer != null:
		_peer.poll()


func _teardown(connection: SpacetimeDBConnection) -> void:
	if connection != null and is_instance_valid(connection):
		connection.disconnect_from_server()
		root.remove_child(connection)
		connection.free()
	if _peer != null:
		_peer.close()
		_peer = null
	_stream = null
	for i: int in 5:
		await physics_frame


func _bytes(size: int) -> PackedByteArray:
	var out: PackedByteArray = []
	out.resize(size)
	return out


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got %d want %d" % [label, got, want])


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got %s want %s" % [label, got, want])

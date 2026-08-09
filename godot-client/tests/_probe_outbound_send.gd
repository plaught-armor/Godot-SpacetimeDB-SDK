# Probe: the OUTBOUND path — what happens to a message the SDK hands to the socket.
# Forty passes covered the receive side (framing, drain, buffers, close codes); nothing
# has measured what a game observes when a message it sends does NOT go out.
#
# Engine facts this is written against (WSLPeer::_send, Godot 4.x):
#   ERR_FAIL_COND_V(queued_msg_count >= max_queued_packets, ERR_OUT_OF_MEMORY)
#   ERR_FAIL_COND_V(outbound_buffer_size > 0 &&
#       queued_msg_length + size > outbound_buffer_size, ERR_OUT_OF_MEMORY)
# so a single message larger than outbound_buffer_size can NEVER be sent, and the
# engine's own error line names neither the knob nor the SDK.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_outbound_send.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 180
const SMALL_BUFFER: int = 4096 # SpacetimeDBConnection.MIN_BUFFER_SIZE

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []
var _received: Array[PackedByteArray] = []

var _n_connected: int = 0
var _n_error: int = 0
var _n_disconnected: int = 0
var _checks: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	await _scenario_baseline()
	await _scenario_oversize_reducer()
	await _scenario_just_under()
	await _scenario_burst_one_frame()
	await _scenario_stalled_server()
	await _scenario_last_message_before_close()
	await _scenario_last_message_with_a_gap()
	await _scenario_close_reason_too_long()

	_stop_server()
	print("\n== %d checks, %d failed ==" % [_checks, _fails])
	quit(_fails)


# A reducer call on a default connection reaches the server. Control for the rest.
func _scenario_baseline() -> void:
	print("\n== baseline: one reducer call on a default connection ==")
	var client: SpacetimeDBClient = await _connected_client(_options())
	if client == null:
		return
	var handle: SpacetimeDBReducerCall = client.call_reducer(
		"enter_game",
		["probe"],
		[&"string"],
		&"",
	)
	await _pump(10)
	_check(
		"handle is PENDING (send accepted)",
		handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING,
	)
	_check("server got the call", _server_saw("enter_game"))
	print("   packets at the server: %d" % _received.size())
	await _teardown(client)


# A reducer whose serialized message is larger than outbound_buffer_size. The engine
# refuses it outright; what does the GAME see, and does the session survive?
func _scenario_oversize_reducer() -> void:
	print("\n== reducer args larger than outbound_buffer_size (%d) ==" % SMALL_BUFFER)
	var options: SpacetimeDBConnectionOptions = _options()
	options.outbound_buffer_size = SMALL_BUFFER
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return
	var big: String = "x".repeat(SMALL_BUFFER * 2)
	var handle: SpacetimeDBReducerCall = client.call_reducer("enter_game", [big], [&"string"], &"")
	await _pump(10)
	print(
		"   outcome: %d  error: %d (%s)"
		% [handle.outcome, handle.error, error_string(handle.error)]
	)
	_check("oversized call reported as ERROR", handle.is_error())
	_check("oversized call never reached the server", not _server_saw("enter_game"))
	_check("socket still open after the refusal", client.is_connected_db())

	# The session has to keep working: the message was refused before the wire, so
	# nothing is half-sent.
	var after: SpacetimeDBReducerCall = client.call_reducer(
		"enter_game",
		["after"],
		[&"string"],
		&"",
	)
	await _pump(10)
	_check(
		"a later small call still sends",
		after.outcome == SpacetimeDBReducerCall.Outcome.PENDING,
	)
	_check("and arrives at the server", _server_saw("enter_game"))
	print("   packets at the server: %d" % _received.size())
	await _teardown(client)


# The largest message that DOES fit, to price the SDK's own framing overhead against
# the knob — a game sizing a payload has to know what the number bounds.
func _scenario_just_under() -> void:
	print("\n== the largest reducer payload that fits a %d-byte outbound buffer ==" % SMALL_BUFFER)
	var options: SpacetimeDBConnectionOptions = _options()
	options.outbound_buffer_size = SMALL_BUFFER
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return
	var largest_ok: int = -1
	# Bounded search over payload sizes, one byte at a time so the number printed is the
	# exact boundary rather than a multiple of the step.
	for step: int in 64:
		var size: int = SMALL_BUFFER - step
		if size <= 0:
			break
		var handle: SpacetimeDBReducerCall = client.call_reducer(
			"enter_game",
			["x".repeat(size)],
			[&"string"],
			&"",
		)
		if handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING:
			largest_ok = size
			break
		await _pump(1)
	print("   largest string argument accepted: %d of %d bytes" % [largest_ok, SMALL_BUFFER])
	_check("some payload under the knob does send", largest_ok > 0)
	await _pump(10)
	_check("it arrived", _server_saw("enter_game"))
	await _teardown(client)


# Many calls in ONE frame, with the server not polling in between. Does the engine
# flush inline (so the queue never builds), or does a burst hit the queue ceiling?
func _scenario_burst_one_frame() -> void:
	print("\n== 200 reducer calls in one frame, %d-byte outbound buffer ==" % SMALL_BUFFER)
	var options: SpacetimeDBConnectionOptions = _options()
	options.outbound_buffer_size = SMALL_BUFFER
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return
	var sent: int = 0
	var refused: int = 0
	for i: int in 200:
		var handle: SpacetimeDBReducerCall = client.call_reducer(
			"enter_game",
			["burst-%03d" % i],
			[&"string"],
			&"",
		)
		if handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING:
			sent += 1
		else:
			refused += 1
	await _pump(30)
	print("   accepted %d, refused %d, server received %d" % [sent, refused, _received.size()])
	_check("every accepted call reached the server", _received.size() >= sent)
	await _teardown(client)


# A server that stops reading. The kernel absorbs a while, then the send queue fills.
# What a game streaming updates at 60 Hz into a stalled peer would observe.
func _scenario_stalled_server() -> void:
	print("\n== server stops reading; 512 KiB payloads, default 2 MiB outbound ==")
	var client: SpacetimeDBClient = await _connected_client(_options())
	if client == null:
		return
	var payload: String = "y".repeat(512 * 1024)
	var sent: int = 0
	var first_refusal: int = -1
	# Server peer is deliberately NOT polled inside this loop.
	for i: int in 64:
		var handle: SpacetimeDBReducerCall = client.call_reducer(
			"enter_game",
			[payload],
			[&"string"],
			&"",
		)
		if handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING:
			sent += 1
		elif first_refusal < 0:
			first_refusal = i
			break
	print("   accepted %d x 512 KiB before the first refusal (index %d)" % [sent, first_refusal])
	print("   socket still open: %s" % str(client.is_connected_db()))
	_check("a stalled peer refuses rather than corrupts", client.is_connected_db())
	await _teardown(client)


# The shape game code writes: call a "leaving" reducer, then disconnect. The bytes DO
# leave this process — the client counts them sent, and WSLPeer::_send hands them to the
# TCP stream inline (wslay_event_send) before close() queues the close frame — but a
# GODOT peer on the other end never hands them up: the data frame and the close arrive in
# one read, WSLPeer::poll recv-queues the data, auto-replies, sees close_sent &&
# close_received and calls close(-1) -> in_buffer.clear(). That is the engine defect
# already written up in tests/_repro_ws_close_drops_final_messages.gd, seen from the
# other direction, and it is why this scenario expects a LOSS rather than an arrival: the
# probe's server is a Godot peer. A real SpacetimeDB server is tungstenite, which drains
# what it has read before acting on the close. The gap scenario below is the control.
func _scenario_last_message_before_close() -> void:
	print("\n== reducer call immediately followed by disconnect_db() ==")
	var client: SpacetimeDBClient = await _connected_client(_options())
	if client == null:
		return
	var handle: SpacetimeDBReducerCall = client.call_reducer(
		"enter_game",
		["farewell"],
		[&"string"],
		&"",
	)
	_check(
		"the farewell call was accepted",
		handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING,
	)
	var sent_bytes: int = client._connection._total_bytes_sent
	client.disconnect_db()
	await _pump(20)
	_check("the client wrote the farewell to the socket", sent_bytes > 0)
	_check(
		"ENGINE STILL BROKEN: a Godot peer drops what arrives with the close",
		not _server_saw("farewell"),
	)
	print("   packets at the server: %d" % _received.size())
	print("   client counts the bytes as sent: %d" % sent_bytes)
	if client != null and is_instance_valid(client):
		root.remove_child(client)
		client.queue_free()
	_peer = null
	_stream = null
	await _pump(5)


# Control for the scenario above: the same call and the same close, with polls in
# between. If this one arrives and the same-frame one does not, what is being measured
# is the engine's close-clears-the-inbox defect on the RECEIVING peer
# (tests/_repro_ws_close_drops_final_messages.gd), not a send the SDK dropped.
func _scenario_last_message_with_a_gap() -> void:
	print("\n== the same call, with frames of separation before disconnect_db() ==")
	var client: SpacetimeDBClient = await _connected_client(_options())
	if client == null:
		return
	client.call_reducer("enter_game", ["farewell"], [&"string"], &"")
	await _pump(5)
	var arrived_before_close: bool = _server_saw("farewell")
	client.disconnect_db()
	await _pump(20)
	_check("with a gap, the call arrives", arrived_before_close)
	print("   packets at the server: %d" % _received.size())
	if client != null and is_instance_valid(client):
		root.remove_child(client)
		client.queue_free()
	_peer = null
	_stream = null
	await _pump(5)


# The other thing this SDK hands the engine on the way out: a close reason. wslay refuses
# one over 123 UTF-8 bytes (WSLAY_ERR_INVALID_ARGUMENT) and WSLPeer::close ignores that
# return, so no close frame is queued and the peer sits in STATE_CLOSING forever. Measured
# here both ways: straight at the engine, and through the SDK's trimming.
func _scenario_close_reason_too_long() -> void:
	print("\n== a close reason longer than a close frame can carry ==")
	var long_reason: String = "why we left: ".repeat(30) # 390 bytes
	var client: SpacetimeDBClient = await _connected_client(_options())
	if client == null:
		return
	# Straight at the engine, bypassing the SDK, to show the wedge is real.
	client._connection._websocket.close(1000, long_reason)
	await _pump(20)
	var raw_state: int = client._connection._websocket.get_ready_state()
	print(
		"   engine-level close with a %d-byte reason: state %d" % [long_reason.length(), raw_state]
	)
	_check(
		"ENGINE STILL BROKEN: a too-long reason leaves the peer in STATE_CLOSING",
		raw_state == WebSocketPeer.STATE_CLOSING,
	)
	await _teardown(client)

	var second: SpacetimeDBClient = await _connected_client(_options())
	if second == null:
		return
	second._connection.disconnect_from_server(1000, long_reason)
	await _pump(20)
	var sdk_state: int = second._connection._websocket.get_ready_state()
	print("   through disconnect_from_server: state %d" % sdk_state)
	_check("the SDK's close completes", sdk_state == WebSocketPeer.STATE_CLOSED)
	await _teardown(second)

# --- harness ---


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.auto_reconnect = false
	options.connect_timeout_seconds = 3.0
	return options


func _connected_client(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_received.clear()
	var client: SpacetimeDBClient = _spawn(options)
	if client == null:
		return null
	if not await _accept_and_identify(client):
		printerr("   handshake did not complete")
		_fails += 1
		await _teardown(client)
		return null
	return client


func _spawn(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_n_connected = 0
	_n_error = 0
	_n_disconnected = 0
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "OutboundProbeClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	client.connection_error.connect(_on_connection_error)
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)
	return client


func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	_peer = null
	for i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_listening() and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			_peer.inbound_buffer_size = 1024 * 1024 * 8
			_peer.outbound_buffer_size = 1024 * 1024 * 8
			if _peer.accept_stream(_stream) != OK:
				printerr("accept_stream failed")
				return false
		if _peer == null:
			continue
		_peer.poll()
		if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN and client.is_connected_db():
			break
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false

	for frame: PackedByteArray in _identity_frames:
		_peer.put_packet(frame)
	var seen: int = _n_connected
	for i: int in MAX_WAIT_FRAMES:
		_peer.poll()
		await physics_frame
		if _n_connected > seen:
			_drain_server()
			_received.clear()
			return true
	return false


# Polls the server peer and keeps whatever the client sent.
func _drain_server() -> void:
	if _peer == null:
		return
	_peer.poll()
	var guard: int = 0
	while _peer.get_available_packet_count() > 0 and guard < 4096:
		_received.append(_peer.get_packet())
		guard += 1


func _pump(frames: int) -> void:
	for i: int in frames:
		_drain_server()
		await physics_frame
	_drain_server()


func _server_saw(needle: String) -> bool:
	var bytes: PackedByteArray = needle.to_utf8_buffer()
	for packet: PackedByteArray in _received:
		if _contains(packet, bytes):
			return true
	return false


func _contains(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty() or haystack.size() < needle.size():
		return false
	for start: int in haystack.size() - needle.size() + 1:
		var hit: bool = true
		for k: int in needle.size():
			if haystack[start + k] != needle[k]:
				hit = false
				break
		if hit:
			return true
	return false


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("   [%s] %s" % ["ok" if ok else "FAIL", label])


func _teardown(client: SpacetimeDBClient) -> void:
	if client != null and is_instance_valid(client):
		client.disconnect_db()
		root.remove_child(client)
		client.queue_free()
	_peer = null
	_stream = null
	for i: int in 5:
		await physics_frame


func _stop_server() -> void:
	if _server.is_listening():
		_server.stop()


func _load_frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return out
	while file.get_position() < file.get_length():
		var size: int = file.get_32()
		if size <= 0 or file.get_position() + size > file.get_length():
			break
		out.append(file.get_buffer(size))
	file.close()
	return out


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


func _on_disconnected() -> void:
	_n_disconnected += 1


func _on_connection_error(_code: int, _reason: String) -> void:
	_n_error += 1

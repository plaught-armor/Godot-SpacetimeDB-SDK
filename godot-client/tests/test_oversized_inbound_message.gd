# Regression test: an inbound message the engine drops ends the session loudly.
#
# Godot passes `inbound_buffer_size` to wslay as the maximum receivable message
# length, and the SDK used to treat that as the whole story: a bigger message closes
# the socket with 1009, which the client reports. Two engine details together make
# that false.
#
# First, wslay's limit is compared against the running message length, which is only
# accumulated by the chunk-append call that Godot's `no_buffering` mode skips
# (`thirdparty/wslay/wslay_event.c`), so a FRAGMENTED message is measured a frame at a
# time and never trips it. Second, the two buffers Godot sizes from that one number
# are not the same size: the reassembly ring is `Math::nearest_shift(inbound_buffer_size)`,
# i.e. rounded UP to the next power of two, while the destination `packet_buffer` is
# exactly `inbound_buffer_size`. A message between the two is therefore assembled
# whole and queued, and then `PacketBuffer::read_packet` refuses to hand it over —
# after it has already consumed the packet's queue slot. `WSLPeer::get_packet` ignores
# that failure and returns OK with a zero-length packet.
#
# The SDK's receive loop skipped an empty packet and carried on. Measured against a
# live SpacetimeDB 2.8.0 server (a 30 000-row snapshot, ~3.1 MB, default 2 MiB
# buffer): the subscription never applied, the mirror stayed empty, several later
# frames decoded as garbage ("Unknown compression tag 120" — the payload's own bytes,
# because the refused read consumed the packet's queue slot without draining its
# payload), and the client reported NOTHING and stayed connected. The only clue in the
# log was an engine line reading `Condition "p_bytes < (int)p.size" is true`.
#
# No SpacetimeDB frame is empty — every one carries a compression byte and a payload —
# so an empty packet is now taken for what it is: a message that was dropped, on a
# stream that cannot be trusted afterwards. The session ends with a diagnostic naming
# what to change.
#
# The server here is hand-rolled rather than a `WebSocketPeer`, because Godot's peer
# has no way to send a fragmented message and fragmentation is the whole point.
#
# Scope: this pins the SDK-side DETECTION of a dropped message, not the frame-offset
# drift that follows one. Godot reassembles fragments before it enqueues, so a single
# oversized message takes exactly one queue slot and there are no later frames here to
# come out shifted; reproducing that half needs a live server still sending updates
# after the drop, which is where it was measured.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_oversized_inbound_message.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const PROTOCOL: String = "v3.bsatn.spacetimedb"
## RFC 6455's fixed handshake GUID.
const WS_GUID: String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
## Shape-valid placeholder; the hand-rolled listener never checks it.
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const CONNECTION_ID: String = "00000000000000000000000000000001"
## Smallest buffer the scenarios run with. Every fragment stays under it so wslay's
## own per-frame limit is never the thing that fires.
const INBOUND_LIMIT: int = 64 * 1024
const FRAGMENT_SIZE: int = 16 * 1024
## Ceiling for every wait loop (NASA rule 2). At 60 Hz this is ~5 s.
const MAX_WAIT_FRAMES: int = 300

var _server: TCPServer = TCPServer.new()
var _stream: StreamPeerTCP = null

var _total: int = 0
var _fails: int = 0

var _n_error: int = 0
var _last_error_code: int = 0
var _messages: Array[PackedByteArray] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_diagnostic_text()
	await _scenario_dropped_message_ends_the_session()
	await _scenario_fragmented_message_under_the_limit_is_delivered()
	await _scenario_message_past_the_ring_is_invisible()
	_stop_server()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- the diagnostic itself (pure) -----------------------------------------------


func _test_diagnostic_text() -> void:
	var text: String = SpacetimeDBConnection.dropped_message_diagnostic(123456)
	_check_b("diagnostic carries the buffer size in force", text.contains("123456"), true)
	_check_b("diagnostic names the setting to raise", text.contains("inbound_buffer_size"), true)
	_check_b("diagnostic offers compression", text.contains("compression"), true)
	_check_b("diagnostic says the session is ending", text.to_lower().contains("session"), true)

# --- scenarios -------------------------------------------------------------------


## A message past the buffer but inside the ring Godot rounded up to, delivered in
## fragments each well under both. It is assembled, queued, and then refused at the
## read — the shape a live server produces. Nothing reaches the SDK, so the drop is
## the only thing it can report.
func _scenario_dropped_message_ends_the_session() -> void:
	print("\n== fragmented message larger than inbound_buffer_size ==")
	var conn: SpacetimeDBConnection = await _open_connection()
	if conn == null:
		return

	await _send_fragmented(_payload(INBOUND_LIMIT + INBOUND_LIMIT / 2))
	await _pump(90)

	_check_i("connection_error once", _n_error, 1)
	_check_i("reported as 1009 (message too big)", _last_error_code, 1009)
	_check_i("no message delivered", _messages.size(), 0)
	_check_b("the socket is closed", conn.is_connected_db(), false)
	await _teardown(conn)


## Control: the same fragmentation under the limit must still arrive whole. Without
## this, a fix that refused every fragmented message would pass the scenario above.
func _scenario_fragmented_message_under_the_limit_is_delivered() -> void:
	print("\n== fragmented message under inbound_buffer_size ==")
	var conn: SpacetimeDBConnection = await _open_connection()
	if conn == null:
		return

	var payload: PackedByteArray = _payload(FRAGMENT_SIZE * 3)
	await _send_fragmented(payload)
	await _pump(90)

	_check_i("one message delivered", _messages.size(), 1)
	if _messages.size() == 1:
		_check_b("delivered whole and unshifted", _messages[0] == payload, true)
	_check_i("no connection_error", _n_error, 0)
	_check_b("still connected", conn.is_connected_db(), true)
	await _teardown(conn)


## The band this fix cannot cover, pinned so it is a measured limit rather than an
## assumption: a message past the reassembly ring (not just past the buffer) is never
## assembled at all. Godot queues nothing, reports nothing, and holds the socket open,
## so there is no empty packet for the SDK to notice and the caller only learns of it
## by timing out its own subscribe. A failure here means the engine started reporting
## this — good news, and the SDK can then act on it.
func _scenario_message_past_the_ring_is_invisible() -> void:
	print("\n== message past the reassembly ring (engine reports nothing) ==")
	var conn: SpacetimeDBConnection = await _open_connection()
	if conn == null:
		return

	# The ring is the next power of two at or above the buffer, so three times the
	# buffer is past it for any setting.
	await _send_fragmented(_payload(INBOUND_LIMIT * 3))
	await _pump(90)

	_check_i("no message delivered", _messages.size(), 0)
	_check_i("ENGINE FIXED if this fails: no error either", _n_error, 0)
	_check_b("ENGINE FIXED if this fails: socket still open", conn.is_connected_db(), true)
	await _teardown(conn)

# --- harness ---------------------------------------------------------------------


## A real [SpacetimeDBConnection] talking to the hand-rolled listener, already past
## the WebSocket handshake. Returns null (having failed a check) if it never opens.
func _open_connection() -> SpacetimeDBConnection:
	_n_error = 0
	_last_error_code = 0
	_messages.clear()
	_stream = null

	var port: int = _start_server()
	if port == 0:
		_check_b("listener started", false, true)
		return null

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.inbound_buffer_size = INBOUND_LIMIT
	options.outbound_buffer_size = INBOUND_LIMIT
	# No keepalive: the hand-rolled listener answers no PING, and a missed PONG would
	# close the socket out from under the scenario.
	options.heartbeat_interval_seconds = 0.0
	options.connect_timeout_seconds = 5.0

	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "db")
	root.add_child(conn)
	conn.connection_error.connect(_on_connection_error)
	conn.message_received.connect(_on_message_received)
	conn.set_token(FAKE_TOKEN)
	conn.connect_to_database("http://127.0.0.1:%d" % port, "db", CONNECTION_ID)

	for _i: int in MAX_WAIT_FRAMES:
		await process_frame
		_accept_and_handshake()
		if conn.is_connected_db():
			break
	if not conn.is_connected_db():
		_check_b("connection opened", false, true)
		await _teardown(conn)
		return null
	return conn


func _on_connection_error(code: int, _reason: String) -> void:
	_n_error += 1
	_last_error_code = code


func _on_message_received(data: PackedByteArray) -> void:
	_messages.append(data)


func _teardown(conn: SpacetimeDBConnection) -> void:
	conn.disconnect_from_server()
	await _pump(10)
	if is_instance_valid(conn):
		conn.queue_free()
	_stop_server()
	await _pump(5)


func _pump(frames: int) -> void:
	for _i: int in mini(frames, MAX_WAIT_FRAMES):
		await process_frame


func _start_server() -> int:
	if _server.is_listening():
		_server.stop()
	if _server.listen(0, "127.0.0.1") != OK:
		return 0
	return _server.get_local_port()


func _stop_server() -> void:
	if _stream != null:
		_stream.disconnect_from_host()
		_stream = null
	if _server.is_listening():
		_server.stop()


## Accepts the pending connection, if any, and answers its upgrade request. Called
## once per frame while waiting, so the request is read whenever it lands.
func _accept_and_handshake() -> void:
	if _stream == null and _server.is_connection_available():
		_stream = _server.take_connection()
	if _stream == null:
		return
	_stream.poll()
	if _stream.get_available_bytes() <= 0:
		return
	var request: String = _stream.get_utf8_string(_stream.get_available_bytes())
	var key: String = _header_value(request, "sec-websocket-key")
	if key.is_empty():
		return
	var accept: String = Marshalls.raw_to_base64((key + WS_GUID).sha1_buffer())
	var response: String = (
		"HTTP/1.1 101 Switching Protocols\r\n" + "Upgrade: websocket\r\n"
		+ "Connection: Upgrade\r\n" + "Sec-WebSocket-Accept: %s\r\n" % accept
		+ "Sec-WebSocket-Protocol: %s\r\n\r\n" % PROTOCOL
	)
	_stream.put_data(response.to_utf8_buffer())


## The value of [param name] (lower-cased) in an HTTP request, or "" if absent.
func _header_value(request: String, name: String) -> String:
	for line: String in request.split("\r\n"):
		var colon: int = line.find(":")
		if colon < 0:
			continue
		if line.substr(0, colon).strip_edges().to_lower() == name:
			return line.substr(colon + 1).strip_edges()
	return ""


## Writes [param payload] as one binary message split into [constant FRAGMENT_SIZE]
## frames: an unfinished binary frame, continuation frames, then a final one. Server
## frames are never masked.
##
## A frame is yielded between fragments so the client polls and drains the socket. A
## whole oversized message written in one go fills the OS send buffer, and blocking
## there stops the frame loop that is supposed to be reading it.
func _send_fragmented(payload: PackedByteArray) -> void:
	if _stream == null:
		return
	var offset: int = 0
	var first: bool = true
	# Bounded (NASA rule 2): one pass per fragment, plus one so the final pass can
	# carry the FIN.
	var max_frames: int = payload.size() / FRAGMENT_SIZE + 2
	for _i: int in max_frames:
		if offset >= payload.size():
			break
		var end: int = mini(offset + FRAGMENT_SIZE, payload.size())
		var fin: bool = end >= payload.size()
		# 0x2 = binary on the first frame, 0x0 = continuation on the rest.
		var err: Error = _stream.put_data(
			_frame(payload.slice(offset, end), 0x2 if first else 0x0, fin)
		)
		if err != OK:
			_check_b("fragment written (error %d)" % err, false, true)
			return
		offset = end
		first = false
		await process_frame


func _frame(payload: PackedByteArray, opcode: int, fin: bool) -> PackedByteArray:
	var out: PackedByteArray = []
	out.append((0x80 if fin else 0x00) | opcode)
	var size: int = payload.size()
	if size < 126:
		out.append(size)
	elif size < 65536:
		out.append(126)
		out.append((size >> 8) & 0xFF) # network byte order
		out.append(size & 0xFF)
	else:
		out.append(127)
		for shift: int in [56, 48, 40, 32, 24, 16, 8, 0]:
			out.append((size >> shift) & 0xFF)
	out.append_array(payload)
	return out


## A payload whose bytes vary, so a shifted or truncated delivery cannot compare
## equal to the original.
func _payload(size: int) -> PackedByteArray:
	var out: PackedByteArray = []
	out.resize(size)
	for i: int in size:
		out[i] = (i * 31 + 7) & 0xFF
	return out


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %s, want %s" % [label, got, want])


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %d, want %d" % [label, got, want])

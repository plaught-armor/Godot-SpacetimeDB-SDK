# Reproducer for a Godot engine defect, not an SDK one: a WebSocket peer discards
# messages it has already received but not yet handed over, if the remote's close
# frame arrives in the same poll.
#
# `WSLPeer::poll()` runs `wslay_event_recv()`, which queues the data frames into
# `in_buffer` and auto-replies to the close frame; the very next lines see
# close_sent && close_received, call `close(-1)`, and that calls `in_buffer.clear()`
# (modules/websocket/wsl_peer.cpp). By the time any GDScript runs,
# `get_available_packet_count()` is already 0 — there is nothing the SDK can drain.
#
# It matters here because SpacetimeDB deliberately flushes its pending frames
# immediately before the close frame (`crates/client-api/src/routes/subscribe.rs`
# drains `frames_rx` and then sends the close), which is exactly the arrangement that
# loses them.
#
# Not a suite test — the `_` prefix keeps it out of run_tests.sh, because it asserts
# current *engine* behaviour rather than this SDK's. Re-run it after a Godot upgrade:
# if it reports FIXED, drop the caveat from docs/design-decisions.md and the README.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_repro_ws_close_drops_final_messages.gd
#
# Exit code: 0 if the engine still drops (nothing changed), 1 if it no longer does.
extends SceneTree

## Frames the server peer polls between sending the payload and closing. 0 puts the
## data and the close frame in one flush (what SpacetimeDB does); 1 separates them.
const SEPARATED_GAP: int = 1
## The messages the server sends before closing. A plain `var`, never `const`: a
## const array of Packed*Array reports a byte-count size and reads back wrong (C1).
var _payloads: Array[PackedByteArray] = [
	PackedByteArray([1, 2, 3, 4]),
	PackedByteArray([5, 6]),
	PackedByteArray([7]),
]
var _server: TCPServer = TCPServer.new()
## What the connection surfaced during the current run. A member rather than a
## captured local so the listener is a named method (lambda capture semantics stop
## being a question, and the formatter has a history of mangling multi-line lambdas).
var _received: Array[PackedByteArray] = []


func _on_message_received(data: PackedByteArray) -> void:
	_received.append(data)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var together: int = await _received_when_closing_after(0)
	var separated: int = await _received_when_closing_after(SEPARATED_GAP)
	_server.stop()

	print("close in the same flush : %d/%d messages delivered" % [together, _payloads.size()])
	print("close one poll later    : %d/%d messages delivered" % [separated, _payloads.size()])

	if separated != _payloads.size():
		printerr("INCONCLUSIVE — the separated case lost messages too; the harness is at fault")
		quit(1)
		return
	if together == 0:
		print("ENGINE STILL DROPS — the caveat in docs/design-decisions.md stands")
		quit(0)
		return
	print("ENGINE FIXED (%d delivered) — revisit the caveat and this file" % together)
	quit(1)


# Stands up a local WebSocket server, lets the real SpacetimeDBConnection complete a
# handshake against it, sends every payload, waits [param gap_frames] server polls, then
# closes cleanly. Returns how many messages the connection actually surfaced.
func _received_when_closing_after(gap_frames: int) -> int:
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return -1

	_received.clear()
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "reprodb")
	root.add_child(conn)
	conn.message_received.connect(_on_message_received)
	# Shape-valid placeholder: the local listener never checks it, and set_token
	# refuses anything with a control character.
	conn.set_token("eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig")
	conn.connect_to_database("http://127.0.0.1:%d" % _server.get_local_port(), "reprodb", "beef")

	var peer: WebSocketPeer = await _accept(conn)
	if peer == null:
		conn.queue_free()
		return -1

	for payload: PackedByteArray in _payloads:
		peer.put_packet(payload)
	for i: int in gap_frames:
		peer.poll()
		await physics_frame
	peer.close(1000, "bye")

	# Bounded (NASA rule 2): the close completes within a poll or two; the ceiling is
	# only here so a wedged socket ends the run instead of hanging it.
	for i: int in 120:
		peer.poll()
		await physics_frame
		if conn._websocket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			break
	for i: int in 3: # let any last drain land
		await physics_frame

	conn.queue_free()
	return _received.size()


# Accepts the pending TCP connection, upgrades it, and returns the server-side peer
# once BOTH ends report the socket open — the connection has to have seen its own
# open state, or the run would be measuring a handshake race instead of the close.
func _accept(conn: SpacetimeDBConnection) -> WebSocketPeer:
	var peer: WebSocketPeer = null
	for i: int in 300:
		await physics_frame
		if peer == null and _server.is_connection_available():
			peer = WebSocketPeer.new()
			peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			if peer.accept_stream(_server.take_connection()) != OK:
				printerr("accept_stream failed")
				return null
		if peer == null:
			continue
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN and conn.is_connected_db():
			return peer
	printerr("handshake never completed")
	return null

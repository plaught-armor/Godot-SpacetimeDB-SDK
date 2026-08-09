# Probe: what one short/corrupt inbound message does to every message after it.
#
# The framing loop used to treat a read that ran off the end of the buffer as an
# "incomplete trailing message": it cleared the error and KEPT the tail for the
# next packet. Nothing ever sends the rest — a ws v3 payload carries one or more
# WHOLE messages — so the retained bytes prefixed every later packet instead.
# Measured here before the fix: one frame cut a byte short delivered 0 of the 40
# updates that followed it, permanently, the carried buffer growing by every packet.
#
# Measures, through a real client on a real socket, what the game sees after one
# such frame: how many of the following updates arrive.
#
# On fixed code _find_wedging_cut finds nothing and reports cut 0 — no prefix eats
# the next packet any more — so only the fixed one-byte-short scenario runs. That is
# the pass condition, not a broken probe.
#
# Hunting tool, not a suite test (`_` prefix keeps it out of run_tests.sh).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_truncated_frame.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const BROADCAST_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 600
## Healthy copies sent after the corrupt one.
const COPIES: int = 20

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []

var _total: int = 0
var _fails: int = 0
var _n_connected: int = 0
var _n_txn: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	if frames.is_empty():
		printerr("no broadcast fixture frames")
		quit(1)
		return
	var cut: int = _find_wedging_cut(frames[0])
	print("first wedging truncation of frame 0: %d of %d bytes" % [cut, frames[0].size()])
	if cut > 0:
		await _scenario_truncated_then_healthy(frames, cut)
	await _scenario_truncated_then_healthy(frames, frames[0].size() - 1)

	_stop_server()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# Offline: the smallest prefix of a real frame that the reader files as
# "incomplete" (tail retained, no error reported) AND that then eats the whole of
# the next healthy payload. That is the shape the live scenario sends.
func _find_wedging_cut(frame: PackedByteArray) -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
	var payload: PackedByteArray = frame.slice(1)
	var whole: int = _offline_count(payload)
	for cut: int in range(1, payload.size()):
		var deserializer: BSATNDeserializer = BSATNDeserializer.new(schema, false)
		deserializer.process_bytes_and_extract_messages(payload.slice(0, cut))
		deserializer.clear_error()
		# The tell of the old retain path: the packet AFTER the short one comes back
		# with fewer messages than it carries, because the leftover ate into it.
		if deserializer.process_bytes_and_extract_messages(payload).size() < whole:
			return cut + 1 # + the compression tag byte the client strips
	return 0


func _offline_count(payload: PackedByteArray) -> int:
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	return deserializer.process_bytes_and_extract_messages(payload).size()


func _scenario_truncated_then_healthy(frames: Array[PackedByteArray], cut: int) -> void:
	print("\n== one frame cut to %d bytes, then %d healthy copies ==" % [cut, COPIES])
	var per_copy: int = _offline_txn_count(frames)
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	_n_txn = 0
	_peer.put_packet(frames[0].slice(0, cut))
	_peer.poll()
	await _pump(10)
	for _i: int in COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _drain_until_settled()

	_check_i("every healthy update after the corrupt frame arrived", _n_txn, COPIES * per_copy)
	await _teardown(client)

# --- oracle ---


func _offline_txn_count(frames: Array[PackedByteArray]) -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(schema, false)
	var count: int = 0
	for frame: PackedByteArray in frames:
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			frame.slice(1)
		):
			if msg is TransactionUpdateMessage or msg is ReducerResultMessage:
				count += 1
	return count

# --- harness ---


func _connected_client() -> SpacetimeDBClient:
	_n_connected = 0
	_n_txn = 0
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.threading = true
	options.auto_reconnect = false
	options.connect_timeout_seconds = 2.0

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.name = "TruncProbeClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.transaction_update_received.connect(_on_txn)
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)

	if not await _accept_and_identify(client):
		printerr("handshake never completed")
		await _teardown(client)
		return null
	return client


func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	_peer = null
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_listening() and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			_peer.outbound_buffer_size = 16 * 1024 * 1024
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

	var seen: int = _n_connected
	for frame: PackedByteArray in _identity_frames:
		_peer.put_packet(frame)
	for _i: int in MAX_WAIT_FRAMES:
		_peer.poll()
		await physics_frame
		if _n_connected > seen:
			return true
	return false


func _drain_until_settled() -> void:
	var last: int = -1
	var still: int = 0
	for _i: int in MAX_WAIT_FRAMES:
		if _peer != null:
			_peer.poll()
		await physics_frame
		if _n_txn == last:
			still += 1
			if still >= 45:
				return
		else:
			still = 0
			last = _n_txn


func _pump(frames: int) -> void:
	for _i: int in frames:
		if _peer != null:
			_peer.poll()
		await physics_frame


func _teardown(client: SpacetimeDBClient) -> void:
	if client != null and is_instance_valid(client):
		client.disconnect_db()
		root.remove_child(client)
		client.queue_free()
	_peer = null
	_stream = null
	_stop_server()
	for _i: int in 5:
		await physics_frame


func _stop_server() -> void:
	if _server.is_listening():
		_server.stop()


func _load_frames(path: String) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while f.get_position() < f.get_length():
		var size: int = f.get_32()
		out.append(f.get_buffer(size))
	f.close()
	return out

# --- listeners ---


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


func _on_txn(_update: TransactionUpdateMessage) -> void:
	_n_txn += 1

# --- assertions ---


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("   ok   %s (%d)" % [label, got])
		return
	_fails += 1
	printerr("   FAIL %s: got %d, want %d" % [label, got, want])

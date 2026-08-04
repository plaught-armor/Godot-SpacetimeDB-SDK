# A session that has ended stops delivering.
#
# `disconnected` is terminal, but closing the socket does not empty what the session
# already handed over: packets received and not yet parsed, results parsed and not
# yet drained, and the batch a frame was midway through. Those kept landing for
# frames after the signal — row callbacks and transaction updates for a session the
# game had already been told was over, mutating a mirror `disconnect_db()`
# deliberately leaves in place as last-known state. `_prepare_for_reconnect` and
# `connect_db` both drop that traffic at their session boundary; the terminal one
# did not.
#
# Both ways of ending a session are covered: the caller disconnecting, and the
# server closing on a client that is not reconnecting. The drain is deliberately
# rate-limited so the burst is provably still in flight when the session ends —
# otherwise the test would pass by having nothing left to leak.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_traffic_stops_at_disconnect.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
## A standalone transaction update — one the capturing client did not cause, so it
## replays as a plain TransactionUpdate rather than a reducer result.
const TXN_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
## Ceiling for every wait loop (NASA rule 2). ~5 s at 60 Hz.
const MAX_WAIT_FRAMES: int = 300
## Copies of the capture pushed in one burst.
const BURST_COPIES: int = 120
## Messages the client may apply per frame, so the burst outlives the close.
const DRAIN_LIMIT: int = 16

var _total: int = 0
var _fails: int = 0

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []
var _txn_frames: Array[PackedByteArray] = []
var _per_copy: int = 0

var _n_connected: int = 0
var _n_txn: int = 0
## Client the reentrant-disconnect case tears down from inside a drain callback.
var _reentrant_client: SpacetimeDBClient = null
var _reentrant_countdown: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	_txn_frames = _load_frames(TXN_FIXTURE)
	_per_copy = _offline_update_count(_txn_frames)
	if _identity_frames.is_empty() or _per_copy == 0:
		printerr("fixtures missing or carrying no updates")
		quit(1)
		return

	await _test_ends_the_session(true)
	await _test_ends_the_session(false)
	await _test_reentrant_disconnect_from_a_callback()

	if _server.is_listening():
		_server.stop()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# [param by_caller] picks which side ends it: disconnect_db(), or the server closing
# on a client with auto-reconnect off. Either way the terminal signal is the point
# past which nothing more may be applied.
func _test_ends_the_session(by_caller: bool) -> void:
	if not _listen():
		return
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	for _i: int in BURST_COPIES:
		for frame: PackedByteArray in _txn_frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _pump(2)

	if by_caller:
		client.disconnect_db()
	else:
		_peer.close(1000, "bye")
		await _pump(4)
	var applied_at_end: int = _n_txn

	_check_b(
		"the burst was still draining when the session ended",
		applied_at_end < BURST_COPIES * _per_copy,
		true,
	)
	await _pump(60)
	_check_i(
		"nothing applied after the session ended (%s)" % ("caller" if by_caller else "server"),
		_n_txn,
		applied_at_end,
	)
	await _teardown(client)


# The drop clears the batch the drain loop is standing in, so a listener that ends
# the session from inside a callback pulls it out from under the loop. That must be
# noticed, not indexed past: the loop used to die on an out-of-bounds read, which
# takes the rest of the frame's messages with it (and, in this harness, prints the
# SCRIPT ERROR that run_tests.sh fails a file for).
func _test_reentrant_disconnect_from_a_callback() -> void:
	if not _listen():
		return
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	_reentrant_client = client
	_reentrant_countdown = 3
	client.transaction_update_received.connect(_on_txn_disconnecting)
	for _i: int in BURST_COPIES:
		for frame: PackedByteArray in _txn_frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _pump(60)

	_check_b("the callback ended the session", _reentrant_client == null, true)
	_check_b("the client is disconnected", client.is_connected_db(), false)
	# Whatever the loop was holding is gone, and nothing kept arriving after it.
	var applied: int = _n_txn
	await _pump(30)
	_check_i("nothing applied after the reentrant disconnect", _n_txn, applied)
	client.transaction_update_received.disconnect(_on_txn_disconnecting)
	await _teardown(client)


func _on_txn_disconnecting(_update: TransactionUpdateMessage) -> void:
	if _reentrant_client == null:
		return
	_reentrant_countdown -= 1
	if _reentrant_countdown > 0:
		return
	var client: SpacetimeDBClient = _reentrant_client
	_reentrant_client = null
	client.disconnect_db()

# --- oracle ---


# What the same bytes parse to off the socket entirely, so the "still draining"
# assertion is measured against the real message count rather than a guess.
func _offline_update_count(frames: Array[PackedByteArray]) -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(schema, false)
	var count: int = 0
	for frame: PackedByteArray in frames:
		# Byte 0 is the compression tag the client strips before parsing.
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			frame.slice(1)
		):
			if msg is TransactionUpdateMessage:
				count += 1
	return count

# --- harness ---


func _listen() -> bool:
	if _server.is_listening():
		return true
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		_fails += 1
		_total += 1
		return false
	return true


func _connected_client() -> SpacetimeDBClient:
	_n_connected = 0
	_n_txn = 0
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.auto_reconnect = false
	options.connect_timeout_seconds = 2.0
	options.auto_tune_frame_budget = false
	options.max_messages_per_frame = DRAIN_LIMIT

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "BoundaryTestClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.transaction_update_received.connect(_on_txn)
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)

	if not await _accept_and_identify(client):
		printerr("handshake never completed")
		_fails += 1
		_total += 1
		await _teardown(client)
		return null
	_n_txn = 0
	return client


func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	_peer = null
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_listening() and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			# Room for the whole burst in one flush.
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

	for frame: PackedByteArray in _identity_frames:
		_peer.put_packet(frame)
	for _i: int in MAX_WAIT_FRAMES:
		_peer.poll()
		await physics_frame
		if _n_connected > 0:
			return true
	return false


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
	if _server.is_listening():
		_server.stop()
	for _i: int in 5:
		await physics_frame


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
		return
	_fails += 1
	printerr("FAIL %s: got %d, want %d" % [label, got, want])


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		return
	_fails += 1
	printerr("FAIL %s: got %s, want %s" % [label, got, want])

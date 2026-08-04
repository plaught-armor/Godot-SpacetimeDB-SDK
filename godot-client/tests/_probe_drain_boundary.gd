# Probe: the receive path under real socket traffic — worker thread, drain budget,
# and the session boundary. Every other test in the suite feeds the deserializer
# directly; this one puts real captured frames through a real WebSocket and checks
# that what comes out the far end matches what the same bytes parse to offline.
#
# The oracle is the SDK's own offline parse of the same fixture: burst N copies of a
# capture through the socket, expect exactly N x (messages that capture parses to).
# Nothing lost, nothing applied twice.
#
# Hunting tool, not a suite test (`_` prefix keeps it out of run_tests.sh).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_drain_boundary.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const TXN_FIXTURE: String = "res://tests/fixtures/wire_txn.bin"
const BROADCAST_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 600
## Copies of the capture pushed in one burst.
const BURST_COPIES: int = 200

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []

var _total: int = 0
var _fails: int = 0

var _n_connected: int = 0
var _n_txn: int = 0
var _n_reconnected: int = 0
## Client the reentrant-disconnect scenario tears down from inside a callback.
var _reentrant_client: SpacetimeDBClient = null
var _reentrant_after: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	await _scenario_burst(true, BROADCAST_FIXTURE, "threaded, a standalone update")
	await _scenario_burst(false, BROADCAST_FIXTURE, "threadless, a standalone update")
	await _scenario_burst(true, TXN_FIXTURE, "threaded, an update nested in a reducer result")
	await _scenario_coalesced(true)
	await _scenario_coalesced(false)
	await _scenario_session_boundary()
	await _scenario_starved_drain()
	await _scenario_freed_mid_drain()
	await _scenario_disconnect_mid_drain()
	await _scenario_server_close_mid_drain()
	await _scenario_reentrant_disconnect()
	await _scenario_paused_tree(true)
	await _scenario_paused_tree(false)

	_stop_server()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


# N copies of a real transaction capture, each frame put on the wire as the server
# would. Expect exactly N x the offline message count, threaded and threadless.
func _scenario_burst(threaded: bool, fixture: String, label: String) -> void:
	print("\n== burst: %s ==" % label)
	var frames: Array[PackedByteArray] = _load_frames(fixture)
	var per_copy: int = _offline_txn_count(frames)
	print("   the capture parses to %d transaction update(s) offline" % per_copy)
	if per_copy == 0:
		printerr("   fixture carries no transaction updates — wrong oracle")
		_fails += 1
		_total += 1
		return

	var client: SpacetimeDBClient = await _connected_client(threaded)
	if client == null:
		return

	_n_txn = 0
	for i: int in BURST_COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
		_peer.poll()
	await _drain_until_settled()

	_check_i("every message applied, once", _n_txn, BURST_COPIES * per_copy)
	await _teardown(client)


# The v3 protocol allows several BSATN messages inside ONE WebSocket frame, and the
# receive path is supposed to drain a frame down to the last message in it. Same
# oracle, but every copy is concatenated into a single packet.
func _scenario_coalesced(threaded: bool) -> void:
	print("\n== coalesced frames: %s ==" % ("threaded" if threaded else "threadless"))
	var frames: Array[PackedByteArray] = _load_frames(TXN_FIXTURE)
	var per_copy: int = _offline_txn_count(frames)
	# The compression tag is per WebSocket frame, not per message, so a coalesced
	# packet keeps the first frame's tag byte and carries the others' payloads bare.
	var coalesced: PackedByteArray = frames[0].duplicate()
	for i: int in range(1, frames.size()):
		coalesced.append_array(frames[i].slice(1))

	var client: SpacetimeDBClient = await _connected_client(threaded)
	if client == null:
		return

	_n_txn = 0
	for i: int in BURST_COPIES:
		_peer.put_packet(coalesced)
		_peer.poll()
	await _drain_until_settled()

	_check_i("every coalesced message applied, once", _n_txn, BURST_COPIES * per_copy)
	await _teardown(client)


# Traffic still in flight when the socket dies must not land in the next session's
# mirror. The burst goes out, the socket is killed in the same breath, and after the
# reconnect settles nothing from the dead session may still be arriving.
func _scenario_session_boundary() -> void:
	print("\n== a burst in flight when the socket dies ==")
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var client: SpacetimeDBClient = await _connected_client(true)
	if client == null:
		return

	for i: int in BURST_COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	# No pump: the socket dies while the client still has unparsed packets queued.
	_stream.disconnect_from_host()
	_peer = null

	var ok: bool = await _accept_and_identify(client)
	_check_b("reconnect handshake completed", ok, true)
	_check_i("reconnected once", _n_reconnected, 1)

	# From here the new session is silent, so anything that arrives belongs to the
	# dead one and should have been dropped at the boundary.
	_n_txn = 0
	await _pump(120)
	_check_i("no dead-session traffic after the reconnect", _n_txn, 0)
	await _teardown(client)


# One message per frame, minimum time budget: the batch has to survive being drained
# across hundreds of frames, which is the only thing that exercises the held
# _drain_batch and its cursor.
func _scenario_starved_drain() -> void:
	print("\n== a drain starved to one message per frame ==")
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var per_copy: int = _offline_txn_count(frames)
	var copies: int = 100
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.auto_tune_frame_budget = false
	options.max_messages_per_frame = 1
	options.frame_budget_us = 1
	var client: SpacetimeDBClient = await _connected_client_with(options)
	if client == null:
		return

	_n_txn = 0
	for i: int in copies:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _drain_until_settled()

	_check_i("nothing lost across the slow drain", _n_txn, copies * per_copy)
	await _teardown(client)


# The client is freed while packets are still queued and the worker is mid-parse.
# A clean exit means the thread was joined and nothing was left holding the tree.
func _scenario_freed_mid_drain() -> void:
	print("\n== the client is freed mid-drain ==")
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var client: SpacetimeDBClient = await _connected_client(true)
	if client == null:
		return

	for i: int in BURST_COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	# No pump at all: free it while the queue is still full.
	root.remove_child(client)
	client.free()
	_check_b("survived a free mid-drain", true, true)
	_peer = null
	_stream = null
	_stop_server()
	for _i: int in 10:
		await physics_frame


# disconnect_db() with a burst still queued: the session is over, so the rest of that
# traffic must not keep arriving afterwards.
func _scenario_disconnect_mid_drain() -> void:
	print("\n== disconnect_db() mid-drain ==")
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var client: SpacetimeDBClient = await _connected_client(true)
	if client == null:
		return

	for i: int in BURST_COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _pump(2)
	client.disconnect_db()
	var applied_at_disconnect: int = _n_txn
	await _pump(60)

	_check_i("nothing applied after the disconnect", _n_txn, applied_at_disconnect)
	await _teardown(client)


# The same boundary, reached from the other side: the server closes and the client
# is not reconnecting, so `disconnected` is terminal. Traffic queued from that
# session must stop landing there too.
func _scenario_server_close_mid_drain() -> void:
	print("\n== the server closes mid-drain, no auto-reconnect ==")
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var per_copy: int = _offline_txn_count(frames)
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.auto_reconnect = false
	# Held back so the burst is provably still draining when the close lands —
	# otherwise the scenario passes by having nothing left to leak.
	options.auto_tune_frame_budget = false
	options.max_messages_per_frame = 16
	var client: SpacetimeDBClient = await _connected_client_with(options)
	if client == null:
		return

	for i: int in BURST_COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _pump(2)
	_peer.close(1000, "bye")
	await _pump(4)
	var applied_at_close: int = _n_txn
	_check_b(
		"the burst was still draining at the close",
		applied_at_close < BURST_COPIES * per_copy,
		true,
	)
	await _pump(60)

	_check_i("nothing applied after the close", _n_txn, applied_at_close)
	await _teardown(client)


# A row/transaction listener that calls disconnect_db() from inside the drain loop.
# The terminal drop clears the batch the loop is standing in, so the loop has to
# notice rather than keep indexing an emptied array.
func _scenario_reentrant_disconnect() -> void:
	print("\n== disconnect_db() from inside a drain callback ==")
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.auto_reconnect = false
	var client: SpacetimeDBClient = await _connected_client_with(options)
	if client == null:
		return

	_reentrant_client = client
	_reentrant_after = 3
	client.transaction_update_received.connect(_on_txn_disconnecting)
	for i: int in BURST_COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _pump(60)

	print("   applied before the reentrant disconnect fired: %d" % _n_txn)
	_check_b("disconnect fired from the callback", _reentrant_client == null, true)
	client.transaction_update_received.disconnect(_on_txn_disconnecting)
	await _teardown(client)


func _on_txn_disconnecting(_update: TransactionUpdateMessage) -> void:
	if _reentrant_client == null:
		return
	_reentrant_after -= 1
	if _reentrant_after > 0:
		return
	var client: SpacetimeDBClient = _reentrant_client
	_reentrant_client = null
	client.disconnect_db()


# A paused SceneTree. With process_while_paused (the default) the socket keeps being
# polled; with it off the SDK freezes with the game — and must lose nothing, since
# the messages are still sitting in the socket when it resumes.
func _scenario_paused_tree(keep_running: bool) -> void:
	print("\n== paused tree, process_while_paused = %s ==" % keep_running)
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var per_copy: int = _offline_txn_count(frames)
	var copies: int = 20
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.process_while_paused = keep_running
	var client: SpacetimeDBClient = await _connected_client_with(options)
	if client == null:
		return

	_n_txn = 0
	paused = true
	for i: int in copies:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()
	await _pump(60)
	var while_paused: int = _n_txn
	_check_b(
		"polled while paused" if keep_running else "frozen while paused",
		while_paused > 0,
		keep_running,
	)

	paused = false
	await _drain_until_settled()
	_check_i("everything arrives once the tree runs again", _n_txn, copies * per_copy)
	await _teardown(client)

# --- oracle ---


# What the SDK's own deserializer makes of the same bytes, off the socket entirely.
# Both message types count: the client re-emits transaction_update_received for a
# standalone TransactionUpdate AND for the one nested inside a ReducerResult, which
# is the shape a capture of the caller's own reducer call has.
func _offline_txn_count(frames: Array[PackedByteArray]) -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(schema, false)
	var count: int = 0
	for frame: PackedByteArray in frames:
		# Byte 0 is the compression tag the client strips before parsing.
		var payload: PackedByteArray = frame.slice(1)
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			payload
		):
			if msg is TransactionUpdateMessage or msg is ReducerResultMessage:
				count += 1
	return count

# --- harness ---


func _options(threaded: bool) -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.threading = threaded
	options.auto_reconnect = true
	options.connect_timeout_seconds = 2.0
	options.reconnect_initial_delay = 0.05
	options.reconnect_max_delay = 0.1
	options.reconnect_jitter_fraction = 0.0
	return options


func _connected_client(threaded: bool) -> SpacetimeDBClient:
	return await _connected_client_with(_options(threaded))


func _connected_client_with(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_n_connected = 0
	_n_txn = 0
	_n_reconnected = 0
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "DrainProbeClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.reconnected.connect(_on_reconnected)
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
			# Room for a whole burst in one flush.
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


# Pumps until the applied count stops moving, so a drain spread across frames is
# measured whole rather than sampled mid-flight.
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


func _on_reconnected() -> void:
	_n_reconnected += 1


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


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("   ok   %s (%s)" % [label, got])
		return
	_fails += 1
	printerr("   FAIL %s: got %s, want %s" % [label, got, want])

# Probe: a SpacetimeDBClient node that leaves the tree and comes back.
#
# `_exit_tree` joins the deserializer worker and sets `_thread_should_exit`, which is
# never reset — the same family as the RowReceiver reparent bug (a `_ready`-time setup
# that runs once per NODE, not once per tree entry). This drives a real client against a
# real socket, detaches it, re-attaches it, and asks whether the receive path still
# delivers.
#
# Oracle: the SDK's own offline parse of the same capture, same as _probe_drain_boundary.
#
# Hunting tool, not a suite test (`_` prefix keeps it out of run_tests.sh).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_client_reparent.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const BROADCAST_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 600
const COPIES: int = 20

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []

var _total: int = 0
var _fails: int = 0

var _n_connected: int = 0
var _n_txn: int = 0
var _n_reconnecting: int = 0
var _n_reconnected: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	await _scenario_reparent(true)
	await _scenario_reparent(false)
	await _scenario_reparent_mid_backoff()

	_stop_server()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


# Deliver a burst, detach the client, re-attach it, deliver another burst. Both bursts
# have to arrive whole. The threadless run is the control: no worker is torn down there,
# so a failure in the threaded run only is the worker, not the socket or the tree.
func _scenario_reparent(threaded: bool) -> void:
	print("\n== reparent: %s ==" % ("threaded" if threaded else "threadless"))
	var frames: Array[PackedByteArray] = _load_frames(BROADCAST_FIXTURE)
	var per_copy: int = _offline_txn_count(frames)
	var client: SpacetimeDBClient = await _connected_client(threaded)
	if client == null:
		return

	_n_txn = 0
	_burst(frames)
	await _drain_until_settled()
	_check_i("before the reparent", _n_txn, COPIES * per_copy)

	root.remove_child(client)
	await _pump(5)
	_check_b("still connected while detached", client.is_connected_db(), true)
	root.add_child(client)
	await _pump(5)

	_n_txn = 0
	_burst(frames)
	await _drain_until_settled()
	_check_i("after the reparent", _n_txn, COPIES * per_copy)
	_check_b(
		"worker alive after the reparent",
		client.deserializer_worker != null and client.deserializer_worker.is_alive(),
		threaded,
	)
	await _teardown(client)


# The other half of what _exit_tree tears down: a reconnect cycle in flight. Drop the
# socket, let the backoff start, detach the client while it is waiting, put it back.
# The cycle has to pick up where it left off — with the saved subscription queries it
# would restore still in hand.
func _scenario_reparent_mid_backoff() -> void:
	print("\n== reparent mid-backoff ==")
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.auto_reconnect = true
	# Long enough to detach inside the wait, short enough not to stall the probe.
	options.reconnect_initial_delay = 1.5
	options.reconnect_max_delay = 1.5
	options.reconnect_jitter_fraction = 0.0
	var client: SpacetimeDBClient = await _connected_client_with(options)
	if client == null:
		return

	client.subscribe(["SELECT * FROM entity"])
	await _pump(5)

	_n_reconnecting = 0
	_n_reconnected = 0
	# Kill the socket from the server side, abruptly.
	_peer.close(1006)
	_peer.poll()
	_peer = null
	if _stream != null:
		_stream.disconnect_from_host()
		_stream = null
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _n_reconnecting > 0:
			break
	_check_b("a reconnect cycle started", _n_reconnecting > 0, true)

	root.remove_child(client)
	await _pump(10)
	_check_b(
		"the saved subscription set survives the detach",
		not client._saved_subscription_queries.is_empty(),
		true,
	)

	var before_reentry: int = _n_reconnecting
	root.add_child(client)
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _n_reconnecting > before_reentry:
			break
	_check_b("the cycle resumes on re-entry", _n_reconnecting > before_reentry, true)

	# And the resumed attempt is a real one: accept it and finish the handshake.
	_check_b("reconnected", await _accept_and_identify(client), true)
	await _teardown(client)


func _burst(frames: Array[PackedByteArray]) -> void:
	for _i: int in COPIES:
		for frame: PackedByteArray in frames:
			_peer.put_packet(frame)
	_peer.poll()

# --- oracle ---


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
	options.threading = threaded
	options.auto_reconnect = false
	options.connect_timeout_seconds = 2.0
	return options


func _connected_client(threaded: bool) -> SpacetimeDBClient:
	return await _connected_client_with(_options(threaded))


func _connected_client_with(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_n_connected = 0
	_n_txn = 0
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.name = "ReparentProbeClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.reconnecting.connect(_on_reconnecting)
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
		if client.get_parent() != null:
			client.get_parent().remove_child(client)
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


func _on_reconnecting(_attempt: int, _max_attempts: int) -> void:
	_n_reconnecting += 1


func _on_reconnected() -> void:
	_n_reconnected += 1

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

# Throwaway probe: drives the REAL SpacetimeDBClient through socket-lifecycle
# transitions against a local WebSocket server, and asserts what the SDK surfaces.
#
# Not a suite test yet (`_` prefix keeps it out of run_tests.sh) — it is a hunting
# tool. The scenarios it covers: clean close, abnormal drop, reconnect success,
# exhausted attempts, cancel mid-backoff, a pending reducer at the drop, and a
# server message larger than inbound_buffer_size (1009).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_socket_lifecycle.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
## Shape-valid placeholder; the local listener never checks it.
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
## Ceiling for every wait loop (NASA rule 2). At 60 Hz this is ~5 s.
const MAX_WAIT_FRAMES: int = 300

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []

var _total: int = 0
var _fails: int = 0

var _n_connected: int = 0
var _n_disconnected: int = 0
var _n_error: int = 0
var _last_error_code: int = 0
var _n_reconnecting: int = 0
var _n_reconnected: int = 0
var _n_reconnect_failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	await _scenario_clean_close_no_reconnect()
	await _scenario_abnormal_drop_no_reconnect()
	await _scenario_reconnect_succeeds()
	await _scenario_attempts_exhausted()
	await _scenario_cancel_mid_backoff()
	await _scenario_pending_reducer_at_drop()
	await _scenario_oversized_message()

	_stop_server()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


func _scenario_clean_close_no_reconnect() -> void:
	print("\n== clean close, auto_reconnect off ==")
	var client: SpacetimeDBClient = await _connected_client(_options(false))
	if client == null:
		return
	_check_i("connected once", _n_connected, 1)

	_peer.close(1000, "bye")
	await _pump(30)

	_check_i("disconnected once", _n_disconnected, 1)
	_check_i("no connection_error", _n_error, 0)
	_check_i("no reconnect attempt", _n_reconnecting, 0)
	_check_b("client reports disconnected", client.is_connected_db(), false)
	await _teardown(client)


func _scenario_abnormal_drop_no_reconnect() -> void:
	print("\n== abnormal drop (TCP reset), auto_reconnect off ==")
	var client: SpacetimeDBClient = await _connected_client(_options(false))
	if client == null:
		return

	_stream.disconnect_from_host()
	await _pump(60)

	_check_i("connection_error once", _n_error, 1)
	_check_i("error code is -1", _last_error_code, -1)
	_check_i("no reconnect attempt", _n_reconnecting, 0)
	_check_b("client reports disconnected", client.is_connected_db(), false)
	await _teardown(client)


func _scenario_reconnect_succeeds() -> void:
	print("\n== abnormal drop, auto_reconnect on, server still listening ==")
	var client: SpacetimeDBClient = await _connected_client(_options(true))
	if client == null:
		return

	_stream.disconnect_from_host()
	_peer = null
	# The client has to open a new socket; accept it and complete the handshake.
	var ok: bool = await _accept_and_identify(client)
	_check_b("second handshake completed", ok, true)
	await _pump(10)

	_check_b("at least one reconnecting", _n_reconnecting >= 1, true)
	_check_i("reconnected once", _n_reconnected, 1)
	_check_i("no reconnect_failed", _n_reconnect_failed, 0)
	_check_i("no terminal disconnected", _n_disconnected, 0)
	_check_b("client reports connected", client.is_connected_db(), true)
	_check_i("connected emitted twice", _n_connected, 2)
	await _teardown(client)


func _scenario_attempts_exhausted() -> void:
	print("\n== drop, auto_reconnect on, server gone ==")
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.max_reconnect_attempts = 2
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return

	_stop_server() # nothing left to connect to
	_stream.disconnect_from_host()
	await _pump(180)

	_check_i("reconnecting emitted twice", _n_reconnecting, 2)
	_check_i("reconnect_failed once", _n_reconnect_failed, 1)
	_check_i("disconnected once", _n_disconnected, 1)
	await _teardown(client)


func _scenario_cancel_mid_backoff() -> void:
	print("\n== disconnect_db() during the backoff ==")
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.reconnect_initial_delay = 1.0 # long enough to cancel inside it
	options.reconnect_jitter_fraction = 0.0
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return

	_stream.disconnect_from_host()
	_peer = null
	await _pump(5)
	_check_b("a reconnect is scheduled", _n_reconnecting >= 1, true)

	client.disconnect_db()
	var attempts_before: int = _n_reconnecting
	await _pump(120) # past the 1 s backoff
	_check_i("no further reconnect attempt", _n_reconnecting, attempts_before)
	_check_b("no new connection offered", _server.is_connection_available(), false)
	_check_i("disconnected once", _n_disconnected, 1)
	await _teardown(client)


func _scenario_pending_reducer_at_drop() -> void:
	print("\n== a reducer in flight when the socket dies ==")
	var client: SpacetimeDBClient = await _connected_client(_options(false))
	if client == null:
		return

	var handle: SpacetimeDBReducerCall = client.call_reducer("probe_noop", [], [])
	_check_i("call is pending", handle.outcome, SpacetimeDBReducerCall.Outcome.PENDING)

	_stream.disconnect_from_host()
	await _pump(60)

	_check_i("outcome is DISCONNECTED", handle.outcome, SpacetimeDBReducerCall.Outcome.DISCONNECTED)
	await _teardown(client)


func _scenario_oversized_message() -> void:
	print("\n== server message larger than inbound_buffer_size ==")
	var options: SpacetimeDBConnectionOptions = _options(false)
	options.inbound_buffer_size = 4096
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return

	var big: PackedByteArray = []
	big.resize(64 * 1024)
	_peer.put_packet(big)
	await _pump(60)

	_check_b("socket closed", client.is_connected_db(), false)
	print(
		"   close code seen by the client: %d (error signals: %d, disconnected: %d)"
		% [_last_error_code, _n_error, _n_disconnected]
	)
	await _teardown(client)

# --- harness ---


func _options(auto_reconnect: bool) -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.auto_reconnect = auto_reconnect
	options.reconnect_initial_delay = 0.1
	options.reconnect_max_delay = 0.2
	options.reconnect_jitter_fraction = 0.0
	return options


# Stands up the listener, connects a real client to it and completes the SpacetimeDB
# handshake (server-side WebSocket upgrade + an IdentityToken frame). Returns null if
# any step timed out.
func _connected_client(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_reset_counters()
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "ProbeClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	client.connection_error.connect(_on_connection_error)
	client.reconnecting.connect(_on_reconnecting)
	client.reconnected.connect(_on_reconnected)
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)

	if not await _accept_and_identify(client):
		printerr("handshake never completed")
		await _teardown(client)
		return null
	return client


# Accepts the pending TCP connection, upgrades it, and pushes the IdentityToken frames
# once BOTH ends report the socket open. Returns false on timeout.
func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	_peer = null
	for i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_listening() and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			# Room for the oversized-message scenario; the default 64 KiB rejects it.
			_peer.outbound_buffer_size = 1024 * 1024
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
	# The client only counts as identified once its own `connected` fired.
	var seen: int = _n_connected
	for i: int in MAX_WAIT_FRAMES:
		_peer.poll()
		await physics_frame
		if _n_connected > seen:
			return true
	return false


func _pump(frames: int) -> void:
	for i: int in frames:
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
	for i: int in 5:
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


func _reset_counters() -> void:
	_n_connected = 0
	_n_disconnected = 0
	_n_error = 0
	_last_error_code = 0
	_n_reconnecting = 0
	_n_reconnected = 0
	_n_reconnect_failed = 0

# --- listeners ---


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


func _on_disconnected() -> void:
	_n_disconnected += 1


func _on_connection_error(code: int, _reason: String) -> void:
	_n_error += 1
	_last_error_code = code


func _on_reconnecting(_attempt: int, _max_attempts: int) -> void:
	_n_reconnecting += 1


func _on_reconnected() -> void:
	_n_reconnected += 1


func _on_reconnect_failed() -> void:
	_n_reconnect_failed += 1

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

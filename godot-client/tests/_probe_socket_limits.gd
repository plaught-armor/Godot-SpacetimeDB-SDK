# Probe: what a degenerate WebSocket limit in SpacetimeDBConnectionOptions does once it
# reaches the engine. The drain knobs are resolved and clamped
# (SpacetimeDBClient._resolve_drain_config, unit-tested); the SOCKET knobs —
# inbound/outbound buffer size and heartbeat interval — are assigned straight through
# by SpacetimeDBConnection.apply_options, which is the residue the hostile-knob sweep
# named and did not measure.
#
# Measured at the engine level first (tests are not needed for these):
#   WebSocketPeer.inbound_buffer_size = -1  -> accepted by the setter, then
#       "Condition p_size < 0 is true" out of cowdata's resize on the first poll, and
#       the headless process hangs (timeout 124).
#   WebSocketPeer.inbound_buffer_size = 0   -> accepted, the socket OPENS, and every
#       inbound message is silently dropped.
#   WebSocketPeer.heartbeat_interval = -5.0 -> refused (ERR_FAIL_COND p_interval < 0),
#       so the property keeps 0.0, which is the documented "keepalive disabled".
#
# This drives the same values through the real client to see what a game would observe.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_socket_limits.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 180

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []

var _n_connected: int = 0
var _n_error: int = 0
var _n_disconnected: int = 0
var _last_error_code: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	await _scenario_zero_inbound()
	await _scenario_negative_heartbeat()
	# Last on purpose: a negative inbound buffer hangs the engine's poll, so anything
	# after it may never run.
	await _scenario_negative_inbound()

	_stop_server()
	quit(0)


# A zero inbound buffer: the socket opens and nothing ever arrives.
func _scenario_zero_inbound() -> void:
	print("\n== inbound_buffer_size = 0 ==")
	var options: SpacetimeDBConnectionOptions = _options()
	options.inbound_buffer_size = 0
	var client: SpacetimeDBClient = _spawn(options)
	var opened: bool = await _accept_and_identify(client)
	print(
		"   socket opened: %s | connected fired: %d | connection_error: %d (code %d) | disconnected: %d"
		% [str(client.is_connected_db()), _n_connected, _n_error, _last_error_code, _n_disconnected]
	)
	print("   identity known to the game: %s" % str(not client.get_local_identity().is_empty()))
	print("   handshake completed: %s" % str(opened))
	await _teardown(client)


# A negative heartbeat: the engine refuses the setter, so keepalive stays off — and the
# SDK's stall threshold, which is derived from the same number, goes negative.
func _scenario_negative_heartbeat() -> void:
	print("\n== heartbeat_interval_seconds = -5.0 ==")
	var options: SpacetimeDBConnectionOptions = _options()
	options.heartbeat_interval_seconds = -5.0
	var client: SpacetimeDBClient = _spawn(options)
	await _accept_and_identify(client)
	var connection: SpacetimeDBConnection = client._connection
	print("   peer heartbeat_interval: %f" % connection._websocket.heartbeat_interval)
	print("   SDK _stall_threshold_ms: %d" % connection._stall_threshold_ms)
	print(
		"   keepalive and stall detection both off: %s"
		% str(
			connection._websocket.heartbeat_interval == 0.0 and connection._stall_threshold_ms <= 0
		)
	)
	await _teardown(client)


# A negative inbound buffer. Expected to wedge; bounded by MAX_WAIT_FRAMES, but the
# engine's own poll is where it hangs, so this may never return.
func _scenario_negative_inbound() -> void:
	print("\n== inbound_buffer_size = -1 (expected to wedge) ==")
	var options: SpacetimeDBConnectionOptions = _options()
	options.inbound_buffer_size = -1
	var client: SpacetimeDBClient = _spawn(options)
	await _accept_and_identify(client)
	print("   still running; socket open: %s" % str(client.is_connected_db()))
	await _teardown(client)

# --- harness ---


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.auto_reconnect = false
	options.connect_timeout_seconds = 2.0
	return options


func _spawn(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_n_connected = 0
	_n_error = 0
	_n_disconnected = 0
	_last_error_code = 0
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "LimitProbeClient"
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
			return true
	return false


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


func _on_connection_error(code: int, _reason: String) -> void:
	_n_error += 1
	_last_error_code = code

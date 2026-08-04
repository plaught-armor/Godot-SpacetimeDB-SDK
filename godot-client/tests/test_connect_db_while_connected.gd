# connect_db() starts a session; it does not re-point a live one.
#
# It used to accept the call on a connected client and half-apply it: host, database
# name and options were written over the live session's, but no socket was opened and
# the connection was never handed the new options — so the live socket kept the
# previous buffers, heartbeat and compression while the client reported the new
# target, and the next drop auto-reconnected to a host the caller had never connected
# to, carrying the old session's subscriptions. It is now refused, and nothing is
# changed. The reconnect assertion is the point: it is what a caller would actually
# have been bitten by.
#
# Runs against a local TCPServer standing in for SpacetimeDB, replaying a real
# IdentityToken capture as the server's side of the handshake.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_connect_db_while_connected.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
## Ceiling for every wait loop (NASA rule 2). ~5 s at 60 Hz.
const MAX_WAIT_FRAMES: int = 300
## Where the refused call points. Port 1 is never listening.
const OTHER_URL: String = "http://127.0.0.1:1"
const OTHER_DB: String = "otherdb"

var _total: int = 0
var _fails: int = 0

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []
var _n_connected: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	if _identity_frames.is_empty():
		printerr("no identity fixture frames")
		quit(1)
		return

	await _test_refused_and_unchanged()

	if _server.is_listening():
		_server.stop()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _test_refused_and_unchanged() -> void:
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		_fails += 1
		_total += 1
		return

	var options: SpacetimeDBConnectionOptions = _options()
	options.auto_reconnect = true
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "SwitchTestClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	var live_url: String = "http://127.0.0.1:%d" % _server.get_local_port()
	client.connect_db(live_url, "probedb", options)

	if not await _accept_and_identify(client):
		printerr("handshake never completed")
		_fails += 1
		_total += 1
		await _teardown(client)
		return

	# The refused call. Its own options object is deliberately different, so a
	# half-application would be visible in connection_options as well.
	var other_options: SpacetimeDBConnectionOptions = _options()
	other_options.auto_reconnect = false
	client.connect_db(OTHER_URL, OTHER_DB, other_options)
	await _pump(20)

	_check_s("host_url unchanged", client.base_url, live_url)
	_check_s("database_name unchanged", client.database_name, "probedb")
	_check_b("options unchanged", client.connection_options == options, true)
	_check_b("still connected", client.is_connected_db(), true)
	_check_b("no second socket offered", _server.is_connection_available(), false)

	# What the half-application really cost: the next drop must come back HERE, on
	# the options this session was opened with — not to the refused target.
	_stream.disconnect_from_host()
	_peer = null
	var reconnected: bool = await _accept_and_identify(client)
	_check_b("the reconnect lands on the original host", reconnected, true)
	_check_i("connected emitted twice", _n_connected, 2)

	await _teardown(client)

# --- harness ---


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.connect_timeout_seconds = 1.0
	options.reconnect_initial_delay = 0.05
	options.reconnect_max_delay = 0.1
	options.reconnect_jitter_fraction = 0.0
	return options


func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	_peer = null
	for _i: int in MAX_WAIT_FRAMES:
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

	var seen: int = _n_connected
	for frame: PackedByteArray in _identity_frames:
		_peer.put_packet(frame)
	for _i: int in MAX_WAIT_FRAMES:
		_peer.poll()
		await physics_frame
		if _n_connected > seen:
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


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1

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


func _check_s(label: String, got: String, want: String) -> void:
	_total += 1
	if got == want:
		return
	_fails += 1
	printerr("FAIL %s: got '%s', want '%s'" % [label, got, want])

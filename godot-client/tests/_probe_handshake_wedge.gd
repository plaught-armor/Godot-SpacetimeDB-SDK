# Probe: a server that accepts the TCP connection but never answers the WebSocket
# upgrade. Godot's raw WebSocketPeer has no handshake timeout (handshake_timeout
# lives on WebSocketMultiplayerPeer, not here; WSLPeer::poll only ages the socket
# once it is OPEN), so the peer stays in STATE_CONNECTING for as long as the remote
# holds the socket open. This measures what the SDK surfaces to a game in that case.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_handshake_wedge.gd
extends SceneTree

const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
## How long to hold the half-open connection, in physics frames (~10 s at 60 Hz).
const HOLD_FRAMES: int = 600

var _server: TCPServer = TCPServer.new()
var _held: Array[StreamPeerTCP] = []

var _n_connected: int = 0
var _n_disconnected: int = 0
var _n_error: int = 0
var _n_reconnecting: int = 0
var _n_reconnect_failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		quit(1)
		return

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.debug_mode = false
	options.auto_reconnect = true
	options.max_reconnect_attempts = 1
	options.reconnect_initial_delay = 0.1
	options.reconnect_jitter_fraction = 0.0
	# 1 s keepalive: if anything were going to age this socket out, it would be this.
	options.heartbeat_interval_seconds = 1.0
	# Short handshake budget so the whole cascade (timeout → reconnect → timeout →
	# reconnect_failed) fits inside HOLD_FRAMES. 0.0 restores the wedge.
	options.connect_timeout_seconds = 2.0

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	client.connection_error.connect(_on_connection_error)
	client.reconnecting.connect(_on_reconnecting)
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)

	# Take the connection off the backlog and hold it: accepted at the TCP layer,
	# never upgraded. That is what a proxy or load balancer in front of a dead
	# upstream looks like from here.
	for i: int in HOLD_FRAMES:
		if _server.is_connection_available():
			_held.append(_server.take_connection())
			print("   accepted TCP connection %d at frame %d" % [_held.size(), i])
		await physics_frame

	var conn: SpacetimeDBConnection = client.get_node(^"Connection") as SpacetimeDBConnection
	var state: int = conn._websocket.get_ready_state()
	print("\n   after %d frames (~%.1f s):" % [HOLD_FRAMES, HOLD_FRAMES / 60.0])
	print("   websocket state       : %s" % _state_name(state))
	print("   is_connected_db()     : %s" % client.is_connected_db())
	print("   connected             : %d" % _n_connected)
	print("   connection_error      : %d" % _n_error)
	print("   reconnecting          : %d" % _n_reconnecting)
	print("   reconnect_failed      : %d" % _n_reconnect_failed)
	print("   disconnected          : %d" % _n_disconnected)

	var wedged: bool = (
		state == WebSocketPeer.STATE_CONNECTING and _n_connected == 0
		and _n_error == 0 and _n_disconnected == 0
	)
	if wedged:
		printerr("\nWEDGED — the client waits forever with no signal to the game.")
	else:
		print("\nnot wedged — something surfaced the stalled handshake.")

	for stream: StreamPeerTCP in _held:
		stream.disconnect_from_host()
	_server.stop()
	client.disconnect_db()
	root.remove_child(client)
	client.queue_free()
	await physics_frame
	quit(1 if wedged else 0)


func _state_name(state: int) -> String:
	if state == WebSocketPeer.STATE_CONNECTING:
		return "CONNECTING"
	if state == WebSocketPeer.STATE_OPEN:
		return "OPEN"
	if state == WebSocketPeer.STATE_CLOSING:
		return "CLOSING"
	if state == WebSocketPeer.STATE_CLOSED:
		return "CLOSED"
	return "unknown (%d)" % state


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


func _on_disconnected() -> void:
	_n_disconnected += 1


func _on_connection_error(code: int, reason: String) -> void:
	_n_error += 1
	print("   connection_error(%d, %s)" % [code, reason])


func _on_reconnecting(attempt: int, _max_attempts: int) -> void:
	_n_reconnecting += 1
	print("   reconnecting attempt %d" % attempt)


func _on_reconnect_failed() -> void:
	_n_reconnect_failed += 1

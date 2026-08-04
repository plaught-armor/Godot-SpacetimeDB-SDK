# A connection attempt that never gets past the WebSocket handshake has to end.
#
# Godot's raw WebSocketPeer has no handshake timeout — handshake_timeout is a
# WebSocketMultiplayerPeer property, and WSLPeer::poll only ages a socket that is
# already open — so a remote that accepts the TCP connection and never answers the
# upgrade (a proxy in front of a dead upstream, a half-open NAT entry) used to leave
# the client in STATE_CONNECTING indefinitely: no `connected`, no `connection_error`,
# and no auto-reconnect either, because the attempt that would have to fail first
# never ended. Measured before the fix with tests/_probe_handshake_wedge.gd.
#
# The socket cases run against a local TCPServer: one that accepts and never
# upgrades (the stall), and one that completes the handshake normally (the clock
# must stop, or a healthy connection would be dropped on its own budget).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_connect_timeout.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
## Handshake budget for the socket cases. Short enough to keep the suite quick,
## long enough that a loaded machine still completes a loopback handshake inside it.
const BUDGET_SECONDS: float = 0.5
## Ceiling for every wait loop (NASA rule 2). ~5 s at 60 Hz.
const MAX_WAIT_FRAMES: int = 300

var _total: int = 0
var _fails: int = 0

var _server: TCPServer = TCPServer.new()
## Connections taken off the backlog and deliberately never upgraded.
var _held: Array[StreamPeerTCP] = []
var _peer: WebSocketPeer = null

var _n_connected: int = 0
var _n_disconnected: int = 0
var _n_error: int = 0
var _last_error_code: int = 0
var _n_reconnect_failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_is_handshake_expired()
	_test_handshake_stall_credit()
	await _test_stalled_handshake_fails_the_attempt()
	await _test_completed_handshake_is_not_timed_out()

	if _server.is_listening():
		_server.stop()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _test_is_handshake_expired() -> void:
	_check_b(
		"a disabled budget never expires",
		SpacetimeDBConnection.is_handshake_expired(999_999, 0),
		false,
	)
	_check_b(
		"inside the budget is not expired",
		SpacetimeDBConnection.is_handshake_expired(499, 500),
		false,
	)
	_check_b(
		"the budget itself expires",
		SpacetimeDBConnection.is_handshake_expired(500, 500),
		true,
	)
	_check_b(
		"past the budget expires",
		SpacetimeDBConnection.is_handshake_expired(5_000, 500),
		true,
	)


# A frozen frame loop is not the remote failing to answer, so the handshake gets
# that time back — but only a bounded amount of it, or a loop running slower than
# one frame per second would postpone the timeout forever.
func _test_handshake_stall_credit() -> void:
	var gap: int = SpacetimeDBConnection.HANDSHAKE_STALL_GAP_MS
	_check_i(
		"frame pacing earns no credit",
		SpacetimeDBConnection.handshake_stall_credit(gap - 1, 0, 15_000),
		0,
	)
	_check_i(
		"a freeze is credited in full",
		SpacetimeDBConnection.handshake_stall_credit(3_000, 0, 15_000),
		3_000,
	)
	_check_i(
		"credit stops at one budget",
		SpacetimeDBConnection.handshake_stall_credit(9_000, 14_000, 15_000),
		1_000,
	)
	_check_i(
		"an exhausted allowance credits nothing",
		SpacetimeDBConnection.handshake_stall_credit(9_000, 15_000, 15_000),
		0,
	)
	# The credit must not depend on keepalive: a caller that switched the heartbeat
	# off still gets it, which is why this is not routed through is_stall_gap.
	_check_i(
		"a disabled timeout credits nothing",
		SpacetimeDBConnection.handshake_stall_credit(9_000, 0, 0),
		0,
	)


# A remote that accepts the socket and never upgrades it: the attempt must end with
# ERR_TIMEOUT, and the reconnect cycle behind it must run to its own conclusion
# rather than waiting on an attempt that never finishes.
func _test_stalled_handshake_fails_the_attempt() -> void:
	if not _listen():
		return
	var options: SpacetimeDBConnectionOptions = _options()
	options.auto_reconnect = true
	options.max_reconnect_attempts = 1
	var client: SpacetimeDBClient = _new_client()
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)

	# Hold every connection at the TCP layer, upgrading none of them.
	for _i: int in MAX_WAIT_FRAMES:
		if _server.is_connection_available():
			_held.append(_server.take_connection())
		await physics_frame
		if _n_reconnect_failed > 0:
			break

	_check_b("the stalled attempt was reported", _n_error >= 1, true)
	_check_i("reported as ERR_TIMEOUT", _last_error_code, ERR_TIMEOUT)
	_check_i("the reconnect cycle finished", _n_reconnect_failed, 1)
	_check_i("disconnected once", _n_disconnected, 1)
	_check_b("never reported connected", _n_connected == 0, true)

	await _teardown(client)


# The mirror case: a handshake that completes must not be timed out afterwards —
# the budget stops the moment the socket opens.
func _test_completed_handshake_is_not_timed_out() -> void:
	if not _listen():
		return
	var client: SpacetimeDBClient = _new_client()
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", _options())

	var opened: bool = false
	for _i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_connection_available():
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			if _peer.accept_stream(_server.take_connection()) != OK:
				printerr("accept_stream failed")
				break
		if _peer == null:
			continue
		_peer.poll()
		if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			opened = true
			break
	_check_b("the handshake completed", opened, true)

	# Well past the budget, with the socket up and idle.
	for _i: int in int(BUDGET_SECONDS * 60.0) + 60:
		if _peer != null:
			_peer.poll()
		await physics_frame

	_check_i("no timeout on a live socket", _n_error, 0)
	_check_i("no disconnect on a live socket", _n_disconnected, 0)
	await _teardown(client)

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


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.connect_timeout_seconds = BUDGET_SECONDS
	options.reconnect_initial_delay = 0.05
	options.reconnect_max_delay = 0.1
	options.reconnect_jitter_fraction = 0.0
	return options


func _new_client() -> SpacetimeDBClient:
	_n_connected = 0
	_n_disconnected = 0
	_n_error = 0
	_last_error_code = 0
	_n_reconnect_failed = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "TimeoutTestClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.disconnected.connect(_on_disconnected)
	client.connection_error.connect(_on_connection_error)
	client.reconnect_failed.connect(_on_reconnect_failed)
	return client


func _teardown(client: SpacetimeDBClient) -> void:
	if client != null and is_instance_valid(client):
		client.disconnect_db()
		root.remove_child(client)
		client.queue_free()
	for stream: StreamPeerTCP in _held:
		stream.disconnect_from_host()
	_held.clear()
	_peer = null
	if _server.is_listening():
		_server.stop()
	for _i: int in 5:
		await physics_frame

# --- listeners ---


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


func _on_disconnected() -> void:
	_n_disconnected += 1


func _on_connection_error(code: int, _reason: String) -> void:
	_n_error += 1
	_last_error_code = code


func _on_reconnect_failed() -> void:
	_n_reconnect_failed += 1

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

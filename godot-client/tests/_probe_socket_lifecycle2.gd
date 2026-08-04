# Second socket-lifecycle probe: the transitions the first one does not reach —
# a subscription carried across a reconnect, a re-drop in the middle of the
# resubscribe, connect_db() called on a live socket, disconnect_db() during the
# handshake, a server that closes before it sends an IdentityToken, and a repeated
# IdentityToken.
#
# Hunting tool, not a suite test (`_` prefix keeps it out of run_tests.sh).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_socket_lifecycle2.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const RESUBSCRIBE_FIXTURE: String = "res://tests/fixtures/wire_resubscribe.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 300
const QUERY: String = "SELECT * FROM config"

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []
var _resubscribe_frames: Array[PackedByteArray] = []
## Everything the client has sent this scenario, newest last.
var _inbox: Array[PackedByteArray] = []

var _total: int = 0
var _fails: int = 0

var _n_connected: int = 0
var _n_disconnected: int = 0
var _n_error: int = 0
var _n_reconnecting: int = 0
var _n_reconnected: int = 0
var _n_reconnect_failed: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	_resubscribe_frames = _load_frames(RESUBSCRIBE_FIXTURE)
	if _identity_frames.is_empty() or _resubscribe_frames.is_empty():
		printerr("missing fixture frames")
		quit(1)
		return

	await _scenario_subscription_survives_reconnect()
	await _scenario_redrop_mid_resubscribe()
	await _scenario_connect_db_while_connected()
	await _scenario_disconnect_during_handshake()
	await _scenario_close_before_identity()
	await _scenario_duplicate_identity()

	_stop_server()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


func _scenario_subscription_survives_reconnect() -> void:
	print("\n== a subscription is resubscribed after a drop ==")
	var client: SpacetimeDBClient = await _connected_client(_options(true))
	if client == null:
		return

	var sub: SpacetimeDBSubscription = client.subscribe([QUERY])
	_check_b("subscribe returned a handle", sub != null, true)
	await _pump(10)
	_check_i("server got the subscribe", _inbox_count_containing(QUERY), 1)
	# Answer it so the subscription is APPLIED, not pending, when the socket dies.
	_send_frames(_resubscribe_frames)
	await _pump(20)
	_check_i("subscription applied", client.current_subscriptions.size(), 1)

	_stream.disconnect_from_host()
	_peer = null
	var ok: bool = await _accept_and_identify(client)
	_check_b("reconnect handshake completed", ok, true)
	await _pump(20)

	_check_i("resubscribe sent on the new socket", _inbox_count_containing(QUERY), 1)
	_check_i("reconnected not emitted before the apply", _n_reconnected, 0)
	_send_frames(_resubscribe_frames)
	await _pump(20)
	_check_i("reconnected once after the apply", _n_reconnected, 1)
	_check_i("subscription back in current", client.current_subscriptions.size(), 1)
	await _teardown(client)


func _scenario_redrop_mid_resubscribe() -> void:
	print("\n== the socket dies again in the middle of the resubscribe ==")
	var client: SpacetimeDBClient = await _connected_client(_options(true))
	if client == null:
		return

	client.subscribe([QUERY])
	await _pump(10)
	_send_frames(_resubscribe_frames)
	await _pump(20)
	_check_i("subscription applied", client.current_subscriptions.size(), 1)

	# First drop → reconnect → the resubscribe goes out but is never answered.
	_stream.disconnect_from_host()
	_peer = null
	var ok: bool = await _accept_and_identify(client)
	_check_b("first reconnect handshake completed", ok, true)
	await _pump(20)
	_check_i("resubscribe sent", _inbox_count_containing(QUERY), 1)

	# Second drop, mid-cycle: the saved query set must survive it.
	_stream.disconnect_from_host()
	_peer = null
	var ok2: bool = await _accept_and_identify(client)
	_check_b("second reconnect handshake completed", ok2, true)
	await _pump(20)
	_check_i("resubscribe sent again, exactly once", _inbox_count_containing(QUERY), 1)

	_send_frames(_resubscribe_frames)
	await _pump(20)
	_check_i("reconnected once", _n_reconnected, 1)
	_check_i("one subscription, not two", client.current_subscriptions.size(), 1)
	await _teardown(client)


func _scenario_connect_db_while_connected() -> void:
	print("\n== connect_db() called on a live socket (refused, changes nothing) ==")
	var client: SpacetimeDBClient = await _connected_client(_options(false))
	if client == null:
		return

	var live_url: String = client.base_url
	var options: SpacetimeDBConnectionOptions = _options(false)
	client.connect_db("http://127.0.0.1:1", "otherdb", options)
	await _pump(20)

	_check_b("base_url unchanged", client.base_url == live_url, true)
	_check_b("database_name unchanged", client.database_name == "probedb", true)
	_check_b("still connected to the original socket", client.is_connected_db(), true)
	_check_i("no second connection offered", int(_server.is_connection_available()), 0)
	await _teardown(client)


func _scenario_disconnect_during_handshake() -> void:
	print("\n== disconnect_db() while the handshake is still running ==")
	_reset_counters()
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return
	var client: SpacetimeDBClient = _new_client()
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", _options(true))
	await _pump(2)
	client.disconnect_db()

	# Accept and identify anyway — a torn-down client must ignore all of it.
	var accepted: bool = await _accept_only()
	if accepted:
		_send_frames(_identity_frames)
	await _pump(40)

	_check_i("connected never emitted", _n_connected, 0)
	_check_i("no reconnect attempt", _n_reconnecting, 0)
	_check_b("not connected", client.is_connected_db(), false)
	_check_i("disconnected once", _n_disconnected, 1)
	await _teardown(client)


func _scenario_close_before_identity() -> void:
	print("\n== server closes right after the upgrade, before any IdentityToken ==")
	_reset_counters()
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return
	var options: SpacetimeDBConnectionOptions = _options(true)
	options.max_reconnect_attempts = 1
	var client: SpacetimeDBClient = _new_client()
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)
	var accepted: bool = await _accept_only()
	_check_b("upgrade completed", accepted, true)
	if accepted:
		_peer.close(1000, "no identity for you")
	await _pump(60)

	_check_i("connected never emitted", _n_connected, 0)
	_check_b("a reconnect was attempted", _n_reconnecting >= 1, true)
	await _pump(120)
	_check_i("reconnect_failed once", _n_reconnect_failed, 1)
	_check_i("disconnected once", _n_disconnected, 1)
	await _teardown(client)


func _scenario_duplicate_identity() -> void:
	print("\n== the server sends a second IdentityToken ==")
	var client: SpacetimeDBClient = await _connected_client(_options(false))
	if client == null:
		return

	_send_frames(_identity_frames)
	await _pump(20)
	print("   connected emitted %d time(s)" % _n_connected)
	_check_b("still connected", client.is_connected_db(), true)
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
	# Short handshake budget: a scenario that abandons a connection attempt (the
	# server closing before the IdentityToken) must not sit out the 15 s default.
	options.connect_timeout_seconds = 0.5
	return options


func _new_client() -> SpacetimeDBClient:
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
	return client


func _connected_client(options: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	_reset_counters()
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null

	var client: SpacetimeDBClient = _new_client()
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", options)
	if not await _accept_and_identify(client):
		printerr("handshake never completed")
		await _teardown(client)
		return null
	return client


# Accepts and upgrades the pending TCP connection. Returns false on timeout.
func _accept_only() -> bool:
	_peer = null
	for i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_listening() and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			_peer.outbound_buffer_size = 1024 * 1024
			if _peer.accept_stream(_stream) != OK:
				printerr("accept_stream failed")
				return false
		if _peer == null:
			continue
		_peer.poll()
		if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return true
	return false


func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	if not await _accept_only():
		return false
	# Both ends have to agree the socket is up before the first frame goes out.
	for i: int in MAX_WAIT_FRAMES:
		_peer.poll()
		await physics_frame
		if client.is_connected_db():
			break
	_inbox.clear()
	_send_frames(_identity_frames)
	var seen: int = _n_connected
	for i: int in MAX_WAIT_FRAMES:
		_drain_inbox()
		await physics_frame
		if _n_connected > seen:
			return true
	return false


func _send_frames(frames: Array[PackedByteArray]) -> void:
	if _peer == null:
		return
	for frame: PackedByteArray in frames:
		_peer.put_packet(frame)
	_peer.poll()


# Polls the server peer and files away whatever the client sent.
func _drain_inbox() -> void:
	if _peer == null:
		return
	_peer.poll()
	# Bounded: a frame carries far fewer than this many client messages.
	for i: int in 64:
		if _peer.get_available_packet_count() <= 0:
			break
		_inbox.append(_peer.get_packet())


func _pump(frames: int) -> void:
	for i: int in frames:
		_drain_inbox()
		await physics_frame


func _inbox_count_containing(needle: String) -> int:
	var hits: int = 0
	var needle_bytes: PackedByteArray = needle.to_utf8_buffer()
	for packet: PackedByteArray in _inbox:
		if _contains(packet, needle_bytes):
			hits += 1
	return hits


static func _contains(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty() or haystack.size() < needle.size():
		return false
	for start: int in haystack.size() - needle.size() + 1:
		var matched: bool = true
		for k: int in needle.size():
			if haystack[start + k] != needle[k]:
				matched = false
				break
		if matched:
			return true
	return false


func _teardown(client: SpacetimeDBClient) -> void:
	if client != null and is_instance_valid(client):
		client.disconnect_db()
		root.remove_child(client)
		client.queue_free()
	_peer = null
	_stream = null
	_inbox.clear()
	# A scenario may leave a connection the client opened and this probe never took
	# (an abandoned reconnect attempt). Closing the listener drops it, so the next
	# scenario's _accept_only cannot pick up the previous one's socket.
	_stop_server()
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
	_n_reconnecting = 0
	_n_reconnected = 0
	_n_reconnect_failed = 0
	_inbox.clear()

# --- listeners ---


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


func _on_disconnected() -> void:
	_n_disconnected += 1


func _on_connection_error(_code: int, _reason: String) -> void:
	_n_error += 1


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

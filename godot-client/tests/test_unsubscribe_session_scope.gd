# A reconnect re-subscribes what the caller still holds — nothing else.
#
# The client only forgets a subscription when the server's UnsubscribeApplied lands, so a
# drop between the Unsubscribe going out and that reply arriving leaves the query in
# current_subscriptions / pending_subscriptions — which is what _start_reconnection
# rebuilds _saved_subscription_queries from. It used to bring such a query back on the
# new socket, and the caller could not drop it a second time: the resubscribe makes a
# fresh internal handle nothing outside the client has a reference to. The last case here
# is the same failure across a session boundary — subscriptions outlived their session,
# so the first drop of the NEXT one resubscribed the previous session's queries.
#
# Runs against a local TCPServer standing in for SpacetimeDB, replaying real captures as
# the server's side (IdentityToken, SubscribeApplied for query_id 0, UnsubscribeApplied
# for query_id 1 — the ids the first and second subscribe of a session get).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_unsubscribe_session_scope.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
# SubscribeApplied for query_id 0 — the first subscribe of a session.
const SUB_APPLIED_FIXTURE: String = "res://tests/fixtures/wire_resubscribe.bin"
# UnsubscribeApplied for query_id 1 — the second subscribe of a session.
const UNSUB_APPLIED_FIXTURE: String = "res://tests/fixtures/wire_unsubscribe.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 300
const QUERY_A: String = "SELECT * FROM config"
const QUERY_B: String = "SELECT * FROM entity"

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []
var _sub_applied_frames: Array[PackedByteArray] = []
var _unsub_applied_frames: Array[PackedByteArray] = []
## Everything the client has sent this scenario, newest last.
var _inbox: Array[PackedByteArray] = []

var _total: int = 0
var _fails: int = 0
var _n_connected: int = 0
var _n_reconnected: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	_sub_applied_frames = _load_frames(SUB_APPLIED_FIXTURE)
	_unsub_applied_frames = _load_frames(UNSUB_APPLIED_FIXTURE)
	if (
		_identity_frames.is_empty() or _sub_applied_frames.is_empty()
		or _unsub_applied_frames.is_empty()
	):
		printerr("missing fixture frames")
		quit(1)
		return

	await _scenario_unsubscribe_applied_then_drop()
	await _scenario_unsubscribe_in_flight_at_drop()
	await _scenario_pending_unsubscribe_in_flight_at_drop()
	await _scenario_previous_session_subscription()
	await _scenario_end_handler_disconnects()

	_stop_server()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- scenarios ---


# Control: the server answers the unsubscribe before the socket dies. The dropped
# query must not come back on the reconnect, and the surviving one must.
func _scenario_unsubscribe_applied_then_drop() -> void:
	print("\n== unsubscribe ANSWERED, then the socket drops ==")
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	var sub_a: SpacetimeDBSubscription = client.subscribe([QUERY_A]) # query_id 0
	var sub_b: SpacetimeDBSubscription = client.subscribe([QUERY_B]) # query_id 1
	await _pump(10)
	_check_i("server got subscribe A", _inbox_count_containing(QUERY_A), 1)
	_check_i("server got subscribe B", _inbox_count_containing(QUERY_B), 1)
	_send_frames(_sub_applied_frames) # SubscribeApplied for query_id 0
	await _pump(20)
	_check_i("A applied", client.current_subscriptions.size(), 1)

	_check_i("unsubscribe B accepted", sub_b.unsubscribe(), OK)
	await _pump(10)
	_send_frames(_unsub_applied_frames) # UnsubscribeApplied for query_id 1
	await _pump(20)
	_check_b("B ended", sub_b.ended, true)
	_check_i("B gone from pending", client.pending_subscriptions.size(), 0)

	_inbox.clear()
	_stream.disconnect_from_host()
	_peer = null
	_check_b("reconnect handshake completed", await _accept_and_identify(client), true)
	await _pump(20)
	_check_i("A resubscribed", _inbox_count_containing(QUERY_A), 1)
	_check_i("B NOT resubscribed", _inbox_count_containing(QUERY_B), 0)
	_check_b("A's handle is the one that lived", sub_a.ended, true) # ended by the drop
	await _teardown(client)


# The regression: the unsubscribe is sent, the server never answers it (socket dies first).
func _scenario_unsubscribe_in_flight_at_drop() -> void:
	print("\n== unsubscribe IN FLIGHT when the socket drops (applied subscription) ==")
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	var sub_a: SpacetimeDBSubscription = client.subscribe([QUERY_A]) # query_id 0
	await _pump(10)
	_send_frames(_sub_applied_frames)
	await _pump(20)
	_check_i("A applied", client.current_subscriptions.size(), 1)

	_check_i("unsubscribe A accepted", sub_a.unsubscribe(), OK)
	await _pump(5)
	# Server never answers it: the socket dies with the Unsubscribe in flight.
	_inbox.clear()
	_stream.disconnect_from_host()
	_peer = null
	_check_b("reconnect handshake completed", await _accept_and_identify(client), true)
	await _pump(20)
	_check_i("A must NOT be resubscribed", _inbox_count_containing(QUERY_A), 0)
	await _teardown(client)


# Same, for a subscription the server had not yet applied.
func _scenario_pending_unsubscribe_in_flight_at_drop() -> void:
	print("\n== unsubscribe IN FLIGHT when the socket drops (pending subscription) ==")
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	var sub_a: SpacetimeDBSubscription = client.subscribe([QUERY_A])
	await _pump(10)
	_check_i("A still pending", client.pending_subscriptions.size(), 1)
	_check_i("unsubscribe A accepted", sub_a.unsubscribe(), OK)
	await _pump(5)

	_inbox.clear()
	_stream.disconnect_from_host()
	_peer = null
	_check_b("reconnect handshake completed", await _accept_and_identify(client), true)
	await _pump(20)
	_check_i("A must NOT be resubscribed", _inbox_count_containing(QUERY_A), 0)
	await _teardown(client)


# A subscription belongs to the session it was made in. After disconnect_db() +
# connect_db(), a drop in the NEW session must not resurrect the OLD session's queries.
func _scenario_previous_session_subscription() -> void:
	print("\n== a drop in a new session must not revive the previous session's query ==")
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	client.subscribe([QUERY_A])
	await _pump(10)
	_send_frames(_sub_applied_frames)
	await _pump(20)
	_check_i("A applied in session 1", client.current_subscriptions.size(), 1)

	client.disconnect_db()
	await _pump(10)
	_stop_server()
	await _pump(5)
	if _server.listen(0, "127.0.0.1") != OK:
		printerr("could not reopen a listener")
		return
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", _options())
	_check_b("session 2 handshake completed", await _accept_and_identify(client), true)
	client.subscribe([QUERY_B])
	await _pump(10)
	_check_i("session 2 subscribed B", _inbox_count_containing(QUERY_B), 1)

	_inbox.clear()
	_stream.disconnect_from_host()
	_peer = null
	_check_b("reconnect handshake completed", await _accept_and_identify(client), true)
	await _pump(20)
	_check_i("B resubscribed", _inbox_count_containing(QUERY_B), 1)
	_check_i("A (session 1) must NOT be resubscribed", _inbox_count_containing(QUERY_A), 0)
	await _teardown(client)


# Ending the handles is game code, and a handler is allowed to call disconnect_db() from
# inside it — which re-enters the same teardown. Each handle must still end exactly once.
func _scenario_end_handler_disconnects() -> void:
	print("\n== a sub.end handler that calls disconnect_db() ==")
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return

	var sub_a: SpacetimeDBSubscription = client.subscribe([QUERY_A])
	var sub_b: SpacetimeDBSubscription = client.subscribe([QUERY_B])
	await _pump(10)
	_send_frames(_sub_applied_frames) # applies A (query_id 0); B stays pending
	await _pump(20)
	_check_i("A applied", client.current_subscriptions.size(), 1)
	_check_i("B pending", client.pending_subscriptions.size(), 1)

	# S6 ignored: the lambdas mutate this by reference. PackedInt32Array is
	# copy-on-write, so each closure would count into its own copy.
	var ends: Array[int] = [0, 0] # gdlint: ignore[S6]
	sub_a.end.connect(
		func() -> void:
			ends[0] += 1
			client.disconnect_db(),
	) # re-enters the teardown from inside it
	sub_b.end.connect(
		func() -> void:
			ends[1] += 1,
	)

	# Drop the socket: the reconnect path tears the handles down while `disconnected`
	# has not fired, so its once-per-session guard is not what stops the re-entry.
	_stream.disconnect_from_host()
	_peer = null
	await _pump(60)

	_check_i("A's end fired once", ends[0], 1)
	_check_i("B's end fired once", ends[1], 1)
	_check_b("A ended", sub_a.ended, true)
	_check_b("B ended", sub_b.ended, true)
	_check_i("no subscriptions left", client.current_subscriptions.size(), 0)
	_check_i("none left pending", client.pending_subscriptions.size(), 0)
	await _teardown(client)

# --- harness (same shape as _probe_socket_lifecycle2.gd) ---


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.auto_reconnect = true
	options.reconnect_initial_delay = 0.1
	options.reconnect_max_delay = 0.2
	options.reconnect_jitter_fraction = 0.0
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
	client.reconnected.connect(_on_reconnected)
	return client


func _connected_client() -> SpacetimeDBClient:
	_reset_counters()
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null

	var client: SpacetimeDBClient = _new_client()
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", _options())
	if not await _accept_and_identify(client):
		printerr("handshake never completed")
		await _teardown(client)
		return null
	return client


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


func _drain_inbox() -> void:
	if _peer == null:
		return
	_peer.poll()
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
	_n_reconnected = 0
	_inbox.clear()

# --- listeners ---


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_n_connected += 1


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

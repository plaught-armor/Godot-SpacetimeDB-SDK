# Probe: what grows without bound over a long session. Forty-one passes checked what the
# SDK DOES; none measured what it KEEPS. A game runs for hours — every container the SDK
# writes to per call, per row, per subscription or per reconnect is a candidate.
#
# Technique: run each churn twice, N then N again, and compare the growth of the second
# half against the first. A bounded structure grows once and stops; a leak grows the same
# amount both times. Absolute sizes are printed so a bound that is merely LARGE shows up
# as well.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_long_session.gd
extends SceneTree

const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const TXN_FIXTURE: String = "res://tests/fixtures/wire_broadcast_txn.bin"
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const MAX_WAIT_FRAMES: int = 240
const CYCLES: int = 300
## Above SpacetimeDBStats.MAX_PENDING (4096), so BOTH samples are saturated — a first
## sample under the cap and a second at it reads as growth for a bounded map.
const CALL_CYCLES: int = 5000
## Reconnect cycles are slow (a real handshake each), so this churn runs its own count.
const RECONNECT_CYCLES: int = 20
## Over _MAX_PENDING_SUBSCRIPTIONS (4096), so the subscribe churn crosses that cap.
const SUBSCRIBE_BURST: int = 5000

var _server: TCPServer = TCPServer.new()
var _peer: WebSocketPeer = null
var _stream: StreamPeerTCP = null
var _identity_frames: Array[PackedByteArray] = []
var _txn_frames: Array[PackedByteArray] = []
var _n_connected: int = 0
var _rows_seen: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_identity_frames = _load_frames(IDENTITY_FIXTURE)
	_txn_frames = _load_frames(TXN_FIXTURE)
	if _identity_frames.is_empty() or _txn_frames.is_empty():
		printerr("missing fixtures")
		quit(1)
		return

	await _churn_reducer_calls()
	await _churn_subscriptions()
	await _churn_transactions()
	await _churn_row_receivers()
	await _churn_connections()
	await _churn_reconnect_amplification()

	_stop_server()
	quit(0)


# Reducer calls nobody answers. The pending map, the stats trackers and the response
# cache are all keyed by request id, and the ids never repeat.
func _churn_reducer_calls() -> void:
	print("\n== %d x 2 reducer calls, no responses ==" % CALL_CYCLES)
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return
	var first: Dictionary = await _call_n(client, CALL_CYCLES)
	var second: Dictionary = await _call_n(client, CALL_CYCLES)
	_report("pending reducer calls", first["pending"], second["pending"], CALL_CYCLES)
	_report("stats pending sends", first["stats"], second["stats"], CALL_CYCLES)
	_report("result cache", first["cache"], second["cache"], CALL_CYCLES)
	_report("objects", first["objects"], second["objects"], CALL_CYCLES)
	await _teardown(client)


func _call_n(client: SpacetimeDBClient, n: int) -> Dictionary:
	for i: int in n:
		client.call_reducer("enter_game", ["churn-%d" % i], [&"string"], &"")
		if i % 50 == 0:
			await physics_frame
	await _pump(5)
	return {
		"pending": client._pending_reducer_calls.size(),
		"stats": client._stats._pending_usec.size(),
		"cache": client._reducer_result_cache.size(),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
	}


# Subscribe/unsubscribe pairs the server never applies: the pending map, the
# unsubscribing-id set and the handles themselves.
func _churn_subscriptions() -> void:
	print("\n== %d x 2 subscribe+unsubscribe pairs, never applied ==" % SUBSCRIBE_BURST)
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return
	var first: Dictionary = await _subscribe_n(client, SUBSCRIBE_BURST)
	var second: Dictionary = await _subscribe_n(client, SUBSCRIBE_BURST)
	_report("pending subscriptions", first["pending"], second["pending"], SUBSCRIBE_BURST)
	_report("current subscriptions", first["current"], second["current"], SUBSCRIBE_BURST)
	_report("unsubscribing ids", first["unsubbing"], second["unsubbing"], SUBSCRIBE_BURST)
	_report("objects", first["objects"], second["objects"], SUBSCRIBE_BURST)
	await _teardown(client)


func _subscribe_n(client: SpacetimeDBClient, n: int) -> Dictionary:
	for i: int in n:
		var sub: SpacetimeDBSubscription = client.subscribe(
			PackedStringArray(["SELECT * FROM entity WHERE entity_id = %d" % i])
		)
		# A refused subscribe carries no query id; unsubscribing it is meaningless.
		if sub.query_id >= 0:
			client.unsubscribe(sub.query_id)
		if i % 50 == 0:
			await physics_frame
	await _pump(5)
	return {
		"pending": client.pending_subscriptions.size(),
		"current": client.current_subscriptions.size(),
		"unsubbing": client._unsubscribing_query_ids.size(),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
	}


# The same transaction replayed over and over: the mirror, the refcounts, the index
# caches and the per-query membership all take a write per row.
func _churn_transactions() -> void:
	print("\n== %d x 2 replays of a transaction capture ==" % CYCLES)
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return
	var first: Dictionary = await _replay_n(client, CYCLES)
	var second: Dictionary = await _replay_n(client, CYCLES)
	_report("mirror rows", first["rows"], second["rows"], CYCLES)
	_report("refcount entries", first["refs"], second["refs"], CYCLES)
	_report("query membership", first["qrows"], second["qrows"], CYCLES)
	_report("objects", first["objects"], second["objects"], CYCLES)
	_report("static memory (KiB)", first["mem"], second["mem"], CYCLES)
	await _teardown(client)


func _replay_n(client: SpacetimeDBClient, n: int) -> Dictionary:
	for i: int in n:
		for frame: PackedByteArray in _txn_frames:
			if _peer != null:
				_peer.put_packet(frame)
		if i % 10 == 0:
			await _pump(1)
	await _pump(30)
	var db: LocalDatabase = client.get_local_database()
	var rows: int = 0
	for table: StringName in db._tables:
		rows += (db._tables[table] as Dictionary).size()
	var refs: int = 0
	for table: StringName in db._ref_counts:
		refs += (db._ref_counts[table] as Dictionary).size()
	var qrows: int = 0
	for qid: int in db._query_rows:
		qrows += (db._query_rows[qid] as Dictionary).size()
	return {
		"rows": rows,
		"refs": refs,
		"qrows": qrows,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"mem": OS.get_static_memory_usage() / 1024,
	}


# Subscribers that are freed without unsubscribing. The eleventh pass named this as a
# known follow-up: the dead Callable stays in the LIVE listener array forever. RowReceiver
# self-cleans in _exit_tree; a raw subscribe_to_* caller may not, and that is what this
# drives.
func _churn_row_receivers() -> void:
	print("\n== %d x 2 freed subscribers that never unsubscribed ==" % CYCLES)
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return
	var first: Dictionary = await _receivers_n(client, CYCLES)
	var second: Dictionary = await _receivers_n(client, CYCLES)
	_report("insert listeners on the table", first["listeners"], second["listeners"], CYCLES)
	_report("objects", first["objects"], second["objects"], CYCLES)
	await _teardown(client)


func _receivers_n(client: SpacetimeDBClient, n: int) -> Dictionary:
	var db: LocalDatabase = client.get_local_database()
	for i: int in n:
		var owner_node: Node = Node.new()
		db.subscribe_to_inserts(&"entity", Callable(owner_node, &"set_name"))
		owner_node.free()
		if i % 50 == 0:
			await physics_frame
	await _pump(5)
	var listeners: Array = db._insert_listeners_by_table.get(&"entity", [])
	return {
		"listeners": listeners.size(),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
	}


# Connect/disconnect cycles on ONE client: threads, timers, monitors and signal
# connections all get set up per connection.
func _churn_connections() -> void:
	print("\n== 2 x %d connect/disconnect cycles on one client ==" % RECONNECT_CYCLES)
	var client: SpacetimeDBClient = await _connected_client()
	if client == null:
		return
	var first: Dictionary = await _reconnect_n(client, RECONNECT_CYCLES)
	var second: Dictionary = await _reconnect_n(client, RECONNECT_CYCLES)
	_report("connections on `connected`", first["sig"], second["sig"], RECONNECT_CYCLES)
	_report("objects", first["objects"], second["objects"], RECONNECT_CYCLES)
	_report("static memory (KiB)", first["mem"], second["mem"], RECONNECT_CYCLES)
	await _teardown(client)


func _reconnect_n(client: SpacetimeDBClient, n: int) -> Dictionary:
	for i: int in n:
		client.disconnect_db()
		await _pump(2)
		_drop_peer()
		client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", _options())
		await _accept_and_identify(client)
	await _pump(5)
	return {
		"sig": client.connected.get_connections().size(),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"mem": OS.get_static_memory_usage() / 1024,
	}


# What unbounded pending subscriptions COST, not just that they accumulate: every
# never-applied subscription is saved at the drop and re-sent on the reconnect, so a
# server that stopped answering turns into an outbound burst the moment the socket dies.
func _churn_reconnect_amplification() -> void:
	print(
		"\n== %d never-applied subscribes (over the %d cap), then a drop =="
		% [SUBSCRIBE_BURST, SpacetimeDBClient._MAX_PENDING_SUBSCRIPTIONS]
	)
	var options: SpacetimeDBConnectionOptions = _options()
	options.auto_reconnect = true
	options.max_reconnect_attempts = 3
	options.reconnect_initial_delay = 0.1
	options.reconnect_max_delay = 0.2
	var client: SpacetimeDBClient = await _connected_client(options)
	if client == null:
		return
	for i: int in SUBSCRIBE_BURST:
		client.subscribe(PackedStringArray(["SELECT * FROM entity WHERE entity_id = %d" % i]))
		if i % 50 == 0:
			await physics_frame
	await _pump(5)
	print("   pending subscriptions before the drop: %d" % client.pending_subscriptions.size())

	# Kill the socket ABNORMALLY (close(-1) sends no close frame) — a clean close reads as
	# an intentional shutdown and does not start the reconnect cycle.
	if _peer != null:
		_peer.close(-1)
		_peer = null
	_stream = null
	var resubscribes: int = 0
	var identified: bool = false
	for i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			_peer.inbound_buffer_size = 1024 * 1024 * 8
			_peer.outbound_buffer_size = 1024 * 1024 * 8
			if _peer.accept_stream(_stream) != OK:
				break
		if _peer == null:
			continue
		_peer.poll()
		if _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			if not identified:
				identified = true
				for frame: PackedByteArray in _identity_frames:
					_peer.put_packet(frame)
			while _peer.get_available_packet_count() > 0:
				var packet: PackedByteArray = _peer.get_packet()
				# Byte search, not get_string_from_utf8: a BSATN frame is not valid UTF-8
				# and decoding it drops the payload the marker lives in.
				if _contains(packet, "SELECT".to_utf8_buffer()):
					resubscribes += 1
	print("   subscribe messages sent on the new socket: %d" % resubscribes)
	print("   saved query sets: %d" % client._saved_subscriptions.size())
	await _teardown(client)


func _contains(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.is_empty() or haystack.size() < needle.size():
		return false
	for start: int in haystack.size() - needle.size() + 1:
		var hit: bool = true
		for k: int in needle.size():
			if haystack[start + k] != needle[k]:
				hit = false
				break
		if hit:
			return true
	return false

# --- harness ---


func _report(label: String, first: int, second: int, n: int) -> void:
	var growth: int = second - first
	var verdict: String = "bounded" if growth <= 0 else "GROWS by %d" % growth
	print("   %-28s after %d: %-9d after %d: %-9d %s" % [label, n, first, n * 2, second, verdict])


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.token = FAKE_TOKEN
	options.save_token = false
	options.one_time_token = true
	options.debug_mode = false
	options.auto_reconnect = false
	options.connect_timeout_seconds = 4.0
	return options


func _connected_client(options: SpacetimeDBConnectionOptions = null) -> SpacetimeDBClient:
	var resolved: SpacetimeDBConnectionOptions = options if options != null else _options()
	if not _server.is_listening() and _server.listen(0, "127.0.0.1") != OK:
		printerr("could not open a listener")
		return null
	_n_connected = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "Blackholio"
	client.auto_connect = false
	client.debug_mode = false
	client.name = "LongSessionProbeClient"
	root.add_child(client)
	client.connected.connect(_on_connected)
	client.connect_db("http://127.0.0.1:%d" % _server.get_local_port(), "probedb", resolved)
	if not await _accept_and_identify(client):
		printerr("   handshake did not complete")
		await _teardown(client)
		return null
	return client


func _accept_and_identify(client: SpacetimeDBClient) -> bool:
	_peer = null
	for i: int in MAX_WAIT_FRAMES:
		await physics_frame
		if _peer == null and _server.is_listening() and _server.is_connection_available():
			_stream = _server.take_connection()
			_peer = WebSocketPeer.new()
			_peer.supported_protocols = [SpacetimeDBConnection.BSATN_PROTOCOL_V3]
			_peer.inbound_buffer_size = 1024 * 1024 * 8
			_peer.outbound_buffer_size = 1024 * 1024 * 8
			if _peer.accept_stream(_stream) != OK:
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


func _pump(frames: int) -> void:
	for i: int in frames:
		if _peer != null:
			_peer.poll()
			while _peer.get_available_packet_count() > 0:
				_peer.get_packet()
		await physics_frame


func _drop_peer() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	_stream = null


func _teardown(client: SpacetimeDBClient) -> void:
	if client != null and is_instance_valid(client):
		client.disconnect_db()
		root.remove_child(client)
		client.queue_free()
	_drop_peer()
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

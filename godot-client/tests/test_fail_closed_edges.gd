# Unit test for the three fail-closed edges of a session.
#
# 1. A packet that fails to parse delivers nothing, abandons the stream until the session
#    boundary, and drops the socket once, from the main thread. Checked on both parse
#    paths: inline (threading off) and on the worker thread (the default), where a fault
#    or a result from a session that ended mid-parse is also dropped.
# 2. Close codes 1002, 1003, 1007 and 1008 say the server rejected what this client sent:
#    no reconnect follows them, inside a cycle or out of one, and close_diagnostic names
#    the code.
# 3. A server that answers every reconnect's replay with a protocol violation exhausts
#    max_reconnect_attempts and reports reconnect_failed. The attempt count resets when a
#    replay settles, not when the new socket's IdentityToken arrives, so a socket that opens
#    and then fails its replay does not hand the next cycle a fresh allowance.
#
# Driven through the real handlers with stub connection and deserializer objects. The
# client is in the tree because the reconnect scheduler needs get_tree(); its delays are
# long enough that no timer fires before the test ends.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_fail_closed_edges.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const _DELAY: float = 600.0
const _MAX_ATTEMPTS: int = 3
# Bound on the wait for the worker thread, in 5 ms polls (2 s).
const _WORKER_POLLS: int = 400
var _terminal_codes: PackedInt32Array = [1002, 1003, 1007, 1008]
# Compression tag 0 (none) and two payload bytes the stub deserializer never reads.
var _packet: PackedByteArray = [0, 1, 2]

var _total: int = 0
var _reconnecting_count: int = 0
var _reconnect_failed_count: int = 0
var _disconnected_count: int = 0


func _initialize() -> void:
	var f: int = 0
	f += await _test_parse_failure_fails_closed()
	f += await _test_threaded_parse_failure_fails_closed()
	f += await _test_terminal_close_in_cycle()
	f += await _test_terminal_close_outside_cycle()
	f += _test_terminal_close_diagnostic()
	f += await _test_repeated_violation_exhausts()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_parse_failure_fails_closed() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client()
	var conn: _StubConn = client._connection
	var deserializer: _StubDeserializer = _StubDeserializer.new()
	client._deserializer = deserializer

	client._on_websocket_message_received(_packet)
	f += _check_i("a sound packet is delivered", client._result_queue.size(), 1)

	# The stub returns a whole message along with the error: the packet's sound part.
	deserializer.fail = true
	client._on_websocket_message_received(_packet)
	f += _check_i("a failed packet delivers nothing", client._result_queue.size(), 1)
	f += _check_b("the fault is recorded", client._parse_fault.is_empty(), false)

	deserializer.fail = false
	client._on_websocket_message_received(_packet)
	f += _check_i("a sound packet after it is dropped too", client._result_queue.size(), 1)
	f += _check_i("only the sound packets were parsed", deserializer.calls, 2)

	f += _check_i("the socket is not dropped from the parse", conn.violations.size(), 0)
	client._close_on_parse_fault()
	f += _check_i("the main thread drops the socket", conn.violations.size(), 1)
	if conn.violations.size() == 1:
		f += _check_b(
			"and names the parse error",
			conn.violations[0].contains(_StubDeserializer.ERROR_TEXT),
			true,
		)
	client._close_on_parse_fault()
	f += _check_i("once, not every frame", conn.violations.size(), 1)

	# The session boundary clears it: the next session's stream starts sound.
	client._drop_dead_session_traffic()
	client._on_websocket_message_received(_packet)
	f += _check_i("the next session is delivered", client._result_queue.size(), 1)
	client._close_on_parse_fault()
	f += _check_i("and not dropped", conn.violations.size(), 1)
	_free_client(client)
	return f


# The same contract on the worker thread. The packets go through the real
# _on_websocket_message_received and the real worker; the waits poll the queues under their
# locks with no frame in between, so _physics_process never drains a result away. The stale
# epoch case runs the worker's batch parse directly, because a live thread cannot be made to
# lose that race on demand.
func _test_threaded_parse_failure_fails_closed() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client()
	var conn: _StubConn = client._connection
	var deserializer: _StubDeserializer = _StubDeserializer.new()
	client._deserializer = deserializer
	client.use_threading = true
	client._setup_threading()
	f += _check_b("the worker runs", client.deserializer_worker.is_alive(), true)

	# One pull of three packets whose second is bad: the first is delivered, nothing from the
	# second is, and the third is never parsed.
	deserializer.fail_at = 2
	client._packet_mutex.lock()
	client._packet_queue.append(_packet)
	client._packet_queue.append(_packet)
	client._packet_queue.append(_packet)
	client._packet_mutex.unlock()
	client._packet_semaphore.post()
	_wait_for_fault(client)
	f += _check_b("threaded: the fault is recorded", _fault(client).is_empty(), false)
	f += _check_i("threaded: only the packet before it is delivered", _results(client), 1)
	f += _check_i("threaded: the packet after it is not parsed", deserializer.calls, 2)

	# Pulled while the fault is set: discarded unparsed.
	deserializer.fail_at = 0
	client._on_websocket_message_received(_packet)
	_wait_for_empty_queue(client)
	OS.delay_msec(50) # room for a parse that should not happen
	f += _check_i("threaded: a later pull is discarded", deserializer.calls, 2)
	f += _check_i("threaded: and delivers nothing", _results(client), 1)

	f += _check_i("threaded: the worker never drops the socket", conn.violations.size(), 0)
	client._close_on_parse_fault()
	client._close_on_parse_fault()
	f += _check_i("threaded: the main thread drops it once", conn.violations.size(), 1)

	# A fault from a batch pulled before the session boundary is the dead session's: it must
	# not close the new one. Same for its results. The worker sits on its semaphore, so the
	# deserializer is free to use from here.
	client._drop_dead_session_traffic()
	var stale_epoch: int = client._session_epoch - 1
	var batch: Array[PackedByteArray] = [_packet]
	deserializer.fail_at = deserializer.calls + 1
	client._parse_packet_batch(batch, stale_epoch)
	f += _check_b("stale epoch: its fault is ignored", _fault(client).is_empty(), true)
	client._parse_packet_batch(batch, stale_epoch)
	f += _check_i("stale epoch: its results are dropped", _results(client), 0)
	client._close_on_parse_fault()
	f += _check_i("stale epoch: the new session is not dropped", conn.violations.size(), 1)

	# Control: the same fault in the current epoch is kept.
	deserializer.fail_at = deserializer.calls + 1
	client._parse_packet_batch(batch, client._session_epoch)
	f += _check_b("current epoch: its fault is kept", _fault(client).is_empty(), false)

	# And the worker serves the next session once the boundary clears the fault.
	client._drop_dead_session_traffic()
	deserializer.fail_at = 0
	client._on_websocket_message_received(_packet)
	_wait_for_results(client, 1)
	f += _check_i("threaded: the next session is delivered", _results(client), 1)
	_free_client(client)
	return f


func _fault(client: SpacetimeDBClient) -> String:
	client._packet_mutex.lock()
	var fault: String = client._parse_fault
	client._packet_mutex.unlock()
	return fault


func _results(client: SpacetimeDBClient) -> int:
	client._result_mutex.lock()
	var size: int = client._result_queue.size()
	client._result_mutex.unlock()
	return size


func _queued(client: SpacetimeDBClient) -> int:
	client._packet_mutex.lock()
	var size: int = client._packet_queue.size()
	client._packet_mutex.unlock()
	return size


func _wait_for_fault(client: SpacetimeDBClient) -> void:
	for i: int in _WORKER_POLLS:
		if not _fault(client).is_empty():
			return
		OS.delay_msec(5)


func _wait_for_empty_queue(client: SpacetimeDBClient) -> void:
	for i: int in _WORKER_POLLS:
		if _queued(client) == 0:
			return
		OS.delay_msec(5)


func _wait_for_results(client: SpacetimeDBClient, count: int) -> void:
	for i: int in _WORKER_POLLS:
		if _results(client) >= count:
			return
		OS.delay_msec(5)


func _test_terminal_close_in_cycle() -> int:
	var f: int = 0
	for code: int in _terminal_codes:
		var client: SpacetimeDBClient = await _make_client()
		var conn: _StubConn = client._connection
		client._start_reconnection() # attempt 1 scheduled
		_reset_counts()
		conn.last_close_code = code
		client._on_connection_disconnected()
		f += _check_i("%d in a cycle: no next attempt" % code, _reconnecting_count, 0)
		f += _check_i("%d in a cycle: reconnect_failed" % code, _reconnect_failed_count, 1)
		f += _check_i("%d in a cycle: disconnected" % code, _disconnected_count, 1)
		f += _check_i(
			"%d in a cycle: idle" % code,
			client._reconnect_state,
			SpacetimeDBClient._ReconnectState.IDLE,
		)
		_free_client(client)

	# Control: any other close on an attempt goes on to the next one.
	var other: SpacetimeDBClient = await _make_client()
	other._start_reconnection()
	_reset_counts()
	(other._connection as _StubConn).last_close_code = 1011
	other._on_connection_disconnected()
	f += _check_i("1011 in a cycle: next attempt", _reconnecting_count, 1)
	f += _check_i("1011 in a cycle: no reconnect_failed", _reconnect_failed_count, 0)
	_free_client(other)
	return f


func _test_terminal_close_outside_cycle() -> int:
	var f: int = 0
	for code: int in _terminal_codes:
		var client: SpacetimeDBClient = await _make_client()
		(client._connection as _StubConn).last_close_code = code
		_reset_counts()
		client._on_connection_disconnected()
		f += _check_i("%d: no reconnect started" % code, _reconnecting_count, 0)
		f += _check_i("%d: no reconnect_failed" % code, _reconnect_failed_count, 0)
		f += _check_i("%d: disconnected" % code, _disconnected_count, 1)
		_free_client(client)

	var other: SpacetimeDBClient = await _make_client()
	(other._connection as _StubConn).last_close_code = 1000
	_reset_counts()
	other._on_connection_disconnected()
	f += _check_i("1000: reconnect started", _reconnecting_count, 1)
	f += _check_i("1000: no disconnected yet", _disconnected_count, 0)
	_free_client(other)
	return f


func _test_terminal_close_diagnostic() -> int:
	var f: int = 0
	for code: int in _terminal_codes:
		var text: String = SpacetimeDBConnection.close_diagnostic(code, 0, "bad frame")
		f += _check_b("%d: diagnostic names the code" % code, text.contains(str(code)), true)
		f += _check_b("%d: and the reason" % code, text.contains("bad frame"), true)
		f += _check_b("%d: and says terminal" % code, text.contains("terminal"), true)
	f += _check_b(
		"1011: no diagnostic",
		SpacetimeDBConnection.close_diagnostic(1011, 0, "").is_empty(),
		true,
	)
	return f


# Each cycle: the attempt connects, the new socket's IdentityToken arrives and the replay is
# sent, and the server answers it with a violation (the error abort_protocol_violation
# reports). With the count reset at the identity this goes on forever; the bound is
# max_reconnect_attempts.
func _test_repeated_violation_exhausts() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client()
	var conn: _StubConn = client._connection
	client._serializer = BSATNSerializer.new(false)
	client._local_db = LocalDatabase.new(
		SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	)
	client._token = "token"
	client.current_subscriptions[0] = SpacetimeDBSubscription.create(
		client,
		0,
		PackedStringArray(["SELECT * FROM tbl"]),
	)
	client._next_query_id = 1
	_reset_counts()

	client._on_connection_error(ERR_INVALID_DATA, "Protocol violation: first")
	var cycles: int = 0
	for i: int in _MAX_ATTEMPTS * 3:
		if _reconnect_failed_count > 0:
			break
		cycles += 1
		client._attempt_reconnect()
		client._handle_parsed_message(_identity_token())
		client._on_connection_error(ERR_INVALID_DATA, "Protocol violation: again")

	f += _check_i("the replay was sent every cycle", conn.sent, cycles)
	f += _check_i("reconnect_failed once", _reconnect_failed_count, 1)
	f += _check_i("after max_reconnect_attempts cycles", cycles, _MAX_ATTEMPTS)
	f += _check_i("attempts reported", _reconnecting_count, _MAX_ATTEMPTS)
	f += _check_i("disconnected", _disconnected_count, 1)
	_free_client(client)

	# A replay that settles does reset it: the next drop is a fresh cycle.
	var settled: SpacetimeDBClient = await _make_client()
	settled._local_db = LocalDatabase.new(
		SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	)
	settled._token = "token"
	settled._start_reconnection()
	settled._attempt_reconnect()
	settled._handle_parsed_message(_identity_token()) # nothing saved: settles at once
	f += _check_i("a settled replay resets the count", settled._reconnect_attempt, 0)
	_free_client(settled)
	return f


func _identity_token() -> IdentityTokenMessage:
	var message: IdentityTokenMessage = IdentityTokenMessage.new()
	message.identity = PackedByteArray()
	message.identity.resize(32)
	message.connection_id = PackedByteArray()
	message.connection_id.resize(16)
	return message


func _make_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	client.debug_mode = false
	client.use_threading = false
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = true
	options.reconnect_initial_delay = _DELAY
	options.reconnect_max_delay = _DELAY
	options.reconnect_jitter_fraction = 0.0
	options.max_reconnect_attempts = _MAX_ATTEMPTS
	client.connection_options = options
	root.add_child(client)
	# Inside the tree only on the next frame; the scheduler needs get_tree().
	await process_frame
	client._is_initialized = true
	client._connection = _StubConn.new()
	client.reconnecting.connect(_on_reconnecting)
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.disconnected.connect(_on_disconnected)
	return client


func _free_client(client: SpacetimeDBClient) -> void:
	var conn: _StubConn = client._connection
	var db: LocalDatabase = client._local_db
	client._cancel_reconnection()
	root.remove_child(client)
	client.free()
	conn.free()
	# A mirror the test made is not the client's child, so freeing the client leaves it.
	if is_instance_valid(db):
		db.free()


func _reset_counts() -> void:
	_reconnecting_count = 0
	_reconnect_failed_count = 0
	_disconnected_count = 0


func _on_reconnecting(_attempt: int, _max_attempts: int) -> void:
	_reconnecting_count += 1


func _on_reconnect_failed() -> void:
	_reconnect_failed_count += 1


func _on_disconnected() -> void:
	_disconnected_count += 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


# A socket that is always up, takes every send, and records each protocol violation
# instead of dropping anything. Skips the parent _init.
class _StubConn:
	extends SpacetimeDBConnection

	var sent: int = 0
	var violations: PackedStringArray = []


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return true


	func is_websocket_active() -> bool:
		return true


	func send_bytes(_bytes: PackedByteArray) -> Error:
		sent += 1
		return OK


	func set_token(_token: String) -> void:
		pass


	func connect_to_database(
		_base_url: String,
		_database_name: String,
		_connection_id: String,
		_session_id: String = "",
	) -> void:
		pass


	func abort_protocol_violation(reason: String) -> void:
		violations.append(reason)


# Returns one whole message per call, and with [member fail] set (or on call number
# [member fail_at]) also leaves a parse error, the shape of a packet whose later message is
# corrupt. Skips the parent _init.
class _StubDeserializer:
	extends BSATNDeserializer

	const ERROR_TEXT: String = "stub parse failure"

	var fail: bool = false
	var fail_at: int = 0
	var calls: int = 0


	func _init() -> void:
		pass


	func process_bytes_and_extract_messages(
		_data: PackedByteArray
	) -> Array[SpacetimeDBServerMessage]:
		calls += 1
		clear_error()
		if fail or calls == fail_at:
			_set_error(ERROR_TEXT)
		var out: Array[SpacetimeDBServerMessage] = [IdentityTokenMessage.new()]
		return out

# Unit test for the fail-closed edges of a session.
#
# 1. A packet that fails to parse delivers nothing, abandons the stream until the session
#    boundary, and drops the socket once, from the main thread. Checked on both parse
#    paths: inline (threading off) and on the worker thread (the default), where a fault
#    or a result from a session that ended mid-parse is also dropped.
# 2. Close codes 1002, 1003, 1007 and 1008 say the server rejected what this client sent:
#    no reconnect follows them, inside a cycle or out of one, and close_diagnostic names
#    the code. One that lands after a reconnect's IdentityToken but before its replay
#    settles still owes the game reconnect_failed: the cycle reads IDLE there, but the game
#    heard reconnecting and is waiting for the outcome.
# 3. The first protocol violation (a message that cannot be parsed, or a replay answer
#    that does not match the request) is terminal: no reconnect follows, connection_error
#    names the fault, reconnect_failed is heard if a reconnect cycle owned the session, and
#    disconnected comes last. The attempt count resets when the reconnect's IdentityToken
#    arrives, as it does in the official SDKs, not when the replay settles. A
#    connection_error handler that calls connect_db or disconnect_db hears nothing after it.
# 4. The give-ups that come before a socket is tried (no token, no tree for the backoff
#    timer) end the cycle like an exhausted one: reconnect_failed, then disconnected, and
#    the attempt count is reset.
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
var _connected_count: int = 0
var _error_codes: PackedInt32Array = []
var _error_reasons: PackedStringArray = []
var _order: PackedStringArray = []


func _initialize() -> void:
	var f: int = 0
	f += await _test_parse_failure_fails_closed()
	f += await _test_threaded_parse_failure_fails_closed()
	f += await _test_terminal_close_in_cycle()
	f += await _test_terminal_close_outside_cycle()
	f += _test_terminal_close_diagnostic()
	f += await _test_terminal_close_before_replay_settles()
	f += _test_violation_reports_its_code()
	f += await _test_first_violation_is_terminal()
	f += await _test_violation_handler_decides()
	f += await _test_early_give_ups_end_the_cycle()
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


func _test_terminal_close_before_replay_settles() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_replaying_client()
	var conn: _StubConn = client._connection
	_connected_count = 0
	client.connected.connect(_on_connected)
	client._start_reconnection()
	client._attempt_reconnect()
	client._handle_parsed_message(_identity_token())
	_reset_counts()
	f += _check_i("window: connected heard", _connected_count, 1)
	f += _check_i("window: replay sent, not settled", conn.sent, 1)
	conn.last_close_code = 1008
	client._on_connection_disconnected()
	f += _check_i("1008 before the replay settles: reconnect_failed", _reconnect_failed_count, 1)
	f += _check_i("1008 before the replay settles: disconnected", _disconnected_count, 1)
	f += _check_i("1008 before the replay settles: no next attempt", _reconnecting_count, 0)
	_free_client(client)

	# Control: once the replay has settled, the cycle is over and owes nothing.
	var settled: SpacetimeDBClient = await _make_replaying_client()
	settled._start_reconnection()
	settled._attempt_reconnect()
	settled._handle_parsed_message(_identity_token())
	settled._finish_resubscribe(settled._resubscribe_epoch)
	_reset_counts()
	(settled._connection as _StubConn).last_close_code = 1008
	settled._on_connection_disconnected()
	f += _check_i("1008 after the replay settled: no reconnect_failed", _reconnect_failed_count, 0)
	f += _check_i("1008 after the replay settled: disconnected", _disconnected_count, 1)
	_free_client(settled)
	return f


# A client with one live subscription, so a reconnect's replay goes out and waits for an
# answer instead of settling at once.
func _make_replaying_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = await _make_client()
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
	return client


# The real connection reports a violation under the code the client treats as terminal,
# and the reason carries the fault it was given.
func _test_violation_reports_its_code() -> int:
	var f: int = 0
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(
		SpacetimeDBConnectionOptions.new(),
		"violation_db",
	)
	_error_codes.clear()
	_error_reasons.clear()
	conn.connection_error.connect(_on_connection_error)
	conn.abort_protocol_violation("the fault text")
	f += _check_i("one connection_error", _error_codes.size(), 1)
	if _error_codes.size() == 1:
		f += _check_i(
			"under ERR_PROTOCOL_VIOLATION",
			_error_codes[0],
			SpacetimeDBConnection.ERR_PROTOCOL_VIOLATION,
		)
		f += _check_b("naming the fault", _error_reasons[0].contains("the fault text"), true)
	conn.free()
	return f


func _test_first_violation_is_terminal() -> int:
	var f: int = 0
	var violation: int = SpacetimeDBConnection.ERR_PROTOCOL_VIOLATION
	var reason: String = "Protocol violation: a server message could not be parsed (bad tag)"

	# Outside a cycle, with auto-reconnect on: the session ends, nothing reconnects.
	var live: SpacetimeDBClient = await _make_replaying_client()
	live.connection_error.connect(_on_connection_error)
	_reset_counts()
	live._on_connection_error(violation, reason)
	f += _check_i("live session: no reconnect", _reconnecting_count, 0)
	f += _check_b(
		"live session: cycle not started",
		live._reconnect_state == live._ReconnectState.IDLE,
		true,
	)
	f += _check_i("live session: no reconnect_failed", _reconnect_failed_count, 0)
	f += _check_i("live session: disconnected", _disconnected_count, 1)
	f += _check_i("live session: connection_error heard", _error_codes.size(), 1)
	if _error_codes.size() == 1:
		f += _check_b("live session: names the fault", _error_reasons[0].contains("bad tag"), true)
	_free_client(live)

	# Inside a reconnect's replay window: the cycle owned the session, so it failed.
	var replaying: SpacetimeDBClient = await _make_replaying_client()
	var conn: _StubConn = replaying._connection
	replaying.connection_error.connect(_on_connection_error)
	_reset_counts()
	replaying._on_connection_error(ERR_CONNECTION_ERROR, "dropped")
	replaying._attempt_reconnect()
	f += _check_i("replay: attempt 1 counted", replaying._reconnect_attempt, 1)
	replaying._handle_parsed_message(_identity_token())
	f += _check_i("replay: the identity resets the count", replaying._reconnect_attempt, 0)
	f += _check_i("replay: the replay was sent", conn.sent, 1)
	replaying._on_connection_error(violation, reason)
	f += _check_i("replay: no next attempt", _reconnecting_count, 1)
	f += _check_i("replay: reconnect_failed", _reconnect_failed_count, 1)
	f += _check_i("replay: disconnected", _disconnected_count, 1)
	f += _check_b(
		"replay: the cycle is over",
		replaying._reconnect_state == replaying._ReconnectState.IDLE
		and not replaying._reconnect_replay_open,
		true,
	)
	_free_client(replaying)
	return f


# A connection_error handler that calls connect_db or disconnect_db has already decided what
# happens next. The violation arrives inside a reconnect's replay window, where the cycle
# owns the session, so anything emitted after the handler would be a reconnect_failed (and,
# after a connect_db re-armed it, a disconnected) for a session the game already replaced.
func _test_violation_handler_decides() -> int:
	var f: int = 0
	var violation: int = SpacetimeDBConnection.ERR_PROTOCOL_VIOLATION
	var reason: String = "Protocol violation: a server message could not be parsed (bad tag)"

	var leaving: SpacetimeDBClient = await _make_replaying_window()
	leaving.connection_error.connect(func(_c: int, _r: String) -> void: leaving.disconnect_db())
	_reset_counts()
	leaving._on_connection_error(violation, reason)
	f += _check_i("disconnect_db handler: no reconnect_failed", _reconnect_failed_count, 0)
	f += _check_i("disconnect_db handler: its own disconnected only", _disconnected_count, 1)
	_free_client(leaving)

	var restarting: SpacetimeDBClient = await _make_replaying_window()
	var conn: _StubConn = restarting._connection
	conn.opened = 0 # the reconnect that opened the window
	var options: SpacetimeDBConnectionOptions = restarting.connection_options
	options.threading = false
	restarting.connection_error.connect(
		func(_c: int, _r: String) -> void:
			conn.up = false # the violation closed the socket, so connect_db is allowed
			restarting.connect_db("http://localhost:3000", "test_mod", options)
	)
	_reset_counts()
	restarting._on_connection_error(violation, reason)
	f += _check_i("connect_db handler: no reconnect_failed", _reconnect_failed_count, 0)
	f += _check_i("connect_db handler: no disconnected", _disconnected_count, 0)
	f += _check_i("connect_db handler: the new session opened", conn.opened, 1)
	_free_client(restarting)
	return f


# The give-ups that come before a socket is even tried — no token to reconnect with, or no
# tree to run the backoff timer in — end the cycle the same way an exhausted one does:
# reconnect_failed, then disconnected, each once, and nothing left counting toward the next
# cycle's max_reconnect_attempts.
func _test_early_give_ups_end_the_cycle() -> int:
	var f: int = 0

	var tokenless: SpacetimeDBClient = await _make_replaying_client()
	_reset_counts()
	tokenless._on_connection_error(ERR_CONNECTION_ERROR, "dropped")
	f += _check_i("no token: attempt 1 scheduled", tokenless._reconnect_attempt, 1)
	tokenless._token = ""
	tokenless._attempt_reconnect()
	f += _check_s("no token: failed, then disconnected", ",".join(_order), "failed,disconnected")
	f += _check_i("no token: the count is reset", tokenless._reconnect_attempt, 0)
	f += _check_b(
		"no token: the cycle is over",
		tokenless._reconnect_state == tokenless._ReconnectState.IDLE,
		true,
	)
	_free_client(tokenless)

	var treeless: SpacetimeDBClient = await _make_replaying_client()
	root.remove_child(treeless) # IDLE as it leaves, so nothing is suspended
	_reset_counts()
	treeless._reconnect_state = treeless._ReconnectState.RECONNECTING
	treeless._schedule_next_reconnect_attempt()
	f += _check_s("no tree: failed, then disconnected", ",".join(_order), "failed,disconnected")
	f += _check_i("no tree: the count is reset", treeless._reconnect_attempt, 0)
	f += _check_b(
		"no tree: the cycle is over",
		treeless._reconnect_state == treeless._ReconnectState.IDLE,
		true,
	)
	root.add_child(treeless)
	_free_client(treeless)
	return f


# A replaying client one reconnect into its replay window: the identity has arrived and the
# subscriptions went out, so the cycle still owns the session.
func _make_replaying_window() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = await _make_replaying_client()
	client._on_connection_error(ERR_CONNECTION_ERROR, "dropped")
	client._attempt_reconnect()
	client._handle_parsed_message(_identity_token())
	return client


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
	_error_codes.clear()
	_error_reasons.clear()
	_reconnecting_count = 0
	_reconnect_failed_count = 0
	_disconnected_count = 0
	_order.clear()


func _on_reconnecting(_attempt: int, _max_attempts: int) -> void:
	_reconnecting_count += 1


func _on_reconnect_failed() -> void:
	_reconnect_failed_count += 1
	_order.append("failed")


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_connected_count += 1


func _on_connection_error(code: int, reason: String) -> void:
	_error_codes.append(code)
	_error_reasons.append(reason)


func _on_disconnected() -> void:
	_disconnected_count += 1
	_order.append("disconnected")


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
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
	var opened: int = 0
	var up: bool = true
	var violations: PackedStringArray = []


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return up


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
		opened += 1


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

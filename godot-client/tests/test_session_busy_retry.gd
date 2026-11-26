# Unit test for the session-busy retry (SpacetimeDB 2.10.2+, close code 4000).
#
# A reconnect names the session its dropped socket held. Until the server has torn that
# socket down it refuses the new one with 4000 "session busy" right after the upgrade, so
# a refusal on a reconnect attempt is expected rather than a failure: the client retries
# at the initial delay and does not count it against max_reconnect_attempts. The free
# retries are capped per cycle (MAX_SESSION_BUSY_RETRIES); past the cap a refusal counts
# like any other failed attempt.
#
# Driven through the real close handler with a stub connection that only carries the
# close code. The client is in the tree because the scheduler needs get_tree() for its
# timer; the delays are long enough that no attempt fires before the test ends.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_session_busy_retry.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const _INITIAL_DELAY: float = 50.0
const _MAX_ATTEMPTS: int = 3
const _STATE_RECONNECTING: int = 1

var _total: int = 0
var _reconnecting_attempts: PackedInt32Array = []
var _reconnect_failed_count: int = 0


func _initialize() -> void:
	var f: int = 0
	f += await _test_busy_refusal_is_free()
	f += await _test_cap()
	f += await _test_other_close_is_counted()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_busy_refusal_is_free() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client()
	var conn: _CloseCodeConn = client._connection
	client._reconnect_state = _STATE_RECONNECTING
	client._schedule_next_reconnect_attempt() # attempt 1
	client._schedule_next_reconnect_attempt() # attempt 2, backoff 2x initial
	f += _check_i("at attempt 2", client._reconnect_attempt, 2)
	_reconnecting_attempts = PackedInt32Array()

	conn.last_close_code = SpacetimeDBConnection.CLOSE_SESSION_BUSY
	client._on_connection_disconnected()
	f += _check_i("busy: attempt number unchanged", client._reconnect_attempt, 2)
	f += _check_b(
		"busy: waits the initial delay",
		_near(client._reconnect_timer.time_left, _INITIAL_DELAY),
		true,
	)
	f += _check_i("busy: reconnecting re-emitted once", _reconnecting_attempts.size(), 1)
	if _reconnecting_attempts.size() == 1:
		f += _check_i("busy: under the same number", _reconnecting_attempts[0], 2)
	f += _check_i("busy: one free retry used", client._session_busy_retries, 1)

	# The initial-delay wait is one-shot: the next ordinary failure escalates again.
	conn.last_close_code = 1000
	client._on_connection_disconnected()
	f += _check_i("after busy: next close counts", client._reconnect_attempt, 3)
	f += _check_b(
		"after busy: backoff escalates again",
		_near(client._reconnect_timer.time_left, _INITIAL_DELAY * 4.0),
		true,
	)

	# At max_reconnect_attempts a busy refusal still does not end the cycle.
	_reconnect_failed_count = 0
	conn.last_close_code = SpacetimeDBConnection.CLOSE_SESSION_BUSY
	client._on_connection_disconnected()
	f += _check_i("busy at the limit: no reconnect_failed", _reconnect_failed_count, 0)
	f += _check_i(
		"busy at the limit: still reconnecting",
		client._reconnect_state,
		_STATE_RECONNECTING,
	)
	f += _check_i("busy at the limit: attempt unchanged", client._reconnect_attempt, _MAX_ATTEMPTS)

	_free_client(client)
	return f


# Past MAX_SESSION_BUSY_RETRIES a refusal is an ordinary failed attempt, and a new cycle
# gets the full allowance back.
func _test_cap() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client()
	var conn: _CloseCodeConn = client._connection
	client._reconnect_state = _STATE_RECONNECTING
	client._schedule_next_reconnect_attempt() # attempt 1
	conn.last_close_code = SpacetimeDBConnection.CLOSE_SESSION_BUSY
	for i: int in SpacetimeDBClient.MAX_SESSION_BUSY_RETRIES:
		client._on_connection_disconnected()
	f += _check_i(
		"cap: free retries all spent",
		client._session_busy_retries,
		SpacetimeDBClient.MAX_SESSION_BUSY_RETRIES,
	)
	f += _check_i("cap: none of them counted", client._reconnect_attempt, 1)
	client._on_connection_disconnected()
	f += _check_i("cap: the next refusal counts", client._reconnect_attempt, 2)
	f += _check_b(
		"cap: and escalates",
		_near(client._reconnect_timer.time_left, _INITIAL_DELAY * 2.0),
		true,
	)

	client._cancel_reconnection()
	client._start_reconnection()
	f += _check_i("new cycle: allowance reset", client._session_busy_retries, 0)
	_free_client(client)
	return f


# Any other server close on a reconnect attempt is counted as before.
func _test_other_close_is_counted() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client()
	var conn: _CloseCodeConn = client._connection
	client._reconnect_state = _STATE_RECONNECTING
	client._schedule_next_reconnect_attempt() # attempt 1
	conn.last_close_code = 1011
	client._on_connection_disconnected()
	f += _check_i("1011: counted", client._reconnect_attempt, 2)
	f += _check_i("1011: no free retry used", client._session_busy_retries, 0)
	_free_client(client)
	return f


func _make_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = true
	options.reconnect_initial_delay = _INITIAL_DELAY
	options.reconnect_max_delay = _INITIAL_DELAY * 100.0
	options.reconnect_backoff_multiplier = 2.0
	options.reconnect_jitter_fraction = 0.0
	options.max_reconnect_attempts = _MAX_ATTEMPTS
	client.connection_options = options
	root.add_child(client)
	# Inside the tree only on the next frame; the scheduler needs get_tree().
	await process_frame
	client._connection = _CloseCodeConn.new()
	client.reconnecting.connect(_on_reconnecting)
	client.reconnect_failed.connect(_on_reconnect_failed)
	return client


func _free_client(client: SpacetimeDBClient) -> void:
	var conn: _CloseCodeConn = client._connection
	root.remove_child(client)
	client.free()
	conn.free()


func _on_reconnecting(attempt: int, _max_attempts: int) -> void:
	_reconnecting_attempts.append(attempt)


func _on_reconnect_failed() -> void:
	_reconnect_failed_count += 1


func _near(got: float, want: float) -> bool:
	return absf(got - want) < 0.5


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


# Carries a close code and nothing else. Skips the parent _init.
class _CloseCodeConn:
	extends SpacetimeDBConnection

	func _init() -> void:
		pass

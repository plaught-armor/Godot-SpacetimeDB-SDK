# Unit test for the resume-triggered reconnect: when the app regains focus, a
# reconnect attempt still waiting out its backoff is fired immediately instead of
# waiting out a delay that barely ticks while the app is backgrounded (web tabs are
# throttled, suspended mobile apps stop entirely).
#
# Two layers:
#   1. SpacetimeDBClient.should_resume_reconnect — the pure decision, no tree needed.
#   2. The wiring: notification(NOTIFICATION_APPLICATION_FOCUS_IN) replaces the pending
#      backoff timer with a zero-delay one, under the SAME attempt number, so alt-tabbing
#      can neither burn through max_reconnect_attempts nor reset it.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_resume_reconnect.gd
extends SceneTree

# The client's own enum, not a copy: a reordered or newly-inserted variant must break
# this test loudly rather than silently poking the wrong state. Private, which the
# project sanctions from tests.
const _STATE_IDLE: int = SpacetimeDBClient._ReconnectState.IDLE
const _STATE_RECONNECTING: int = SpacetimeDBClient._ReconnectState.RECONNECTING
# Long enough that a live backoff timer provably still has time left when focus returns.
const _LONG_DELAY: float = 30.0

var _total: int = 0
var _reconnecting_attempts: PackedInt32Array = []
var _reconnect_failed_count: int = 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var f: int = 0
	f += _test_predicate()
	f += await _test_focus_fires_pending_attempt()
	f += await _test_no_op_cases()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_predicate() -> int:
	var f: int = 0

	# All three conditions hold → pull the attempt forward.
	f += _check(
		"enabled + reconnecting + waiting",
		SpacetimeDBClient.should_resume_reconnect(true, true, 12.5),
		true,
	)

	# Option off → the backoff runs its course.
	f += _check("disabled", SpacetimeDBClient.should_resume_reconnect(false, true, 12.5), false)

	# Not mid-reconnect → nothing pending to fire (a healthy connection, or a
	# cancelled cycle, must not be poked by a focus change).
	f += _check("idle", SpacetimeDBClient.should_resume_reconnect(true, false, 12.5), false)

	# Timer already elapsed (or none) → _attempt_reconnect is already on its way;
	# firing again would double-connect.
	f += _check("no time left", SpacetimeDBClient.should_resume_reconnect(true, true, 0.0), false)
	f += _check(
		"negative time left",
		SpacetimeDBClient.should_resume_reconnect(true, true, -1.0),
		false,
	)

	return f


func _test_focus_fires_pending_attempt() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client(true)
	_reconnecting_attempts = PackedInt32Array()
	client.reconnecting.connect(_on_reconnecting)

	client._reconnect_state = _STATE_RECONNECTING
	client._schedule_next_reconnect_attempt()
	var pending: SceneTreeTimer = client._reconnect_timer
	f += _check_i("scheduled attempt 1", client._reconnect_attempt, 1)
	f += _check("backoff timer is waiting", pending != null and pending.time_left > 0.0, true)

	client.notification(NOTIFICATION_APPLICATION_FOCUS_IN)

	f += _check("timer replaced", client._reconnect_timer != pending, true)
	f += _check("new timer fires now", client._reconnect_timer.time_left <= 0.001, true)
	# Same number: the stalled attempt is re-scheduled, not consumed.
	f += _check_i("attempt number unchanged", client._reconnect_attempt, 1)
	f += _check_i("reconnecting emitted twice (1, 1)", _reconnecting_attempts.size(), 2)
	f += _check_i("second emit is attempt 1", _reconnecting_attempts[1], 1)
	# The superseded timer must not also call _attempt_reconnect when it elapses.
	f += _check("old timer disconnected", pending.timeout.is_connected(client._attempt_reconnect), false)

	# Let the zero-delay timer actually fire, so the tail is covered too: this client
	# has no _connection and no token, so _attempt_reconnect must give up cleanly
	# rather than wedge in RECONNECTING forever.
	_reconnect_failed_count = 0
	client.reconnect_failed.connect(_on_reconnect_failed)
	await process_frame
	f += _check_i("pending attempt ran → state IDLE", client._reconnect_state, _STATE_IDLE)
	f += _check_i("pending attempt ran → reconnect_failed once", _reconnect_failed_count, 1)
	client.reconnect_failed.disconnect(_on_reconnect_failed)

	client.reconnecting.disconnect(_on_reconnecting)
	_free_client(client)
	return f


func _test_no_op_cases() -> int:
	var f: int = 0

	# Option off → the pending timer is left alone.
	var off: SpacetimeDBClient = await _make_client(false)
	off._reconnect_state = _STATE_RECONNECTING
	off._schedule_next_reconnect_attempt()
	var kept: SceneTreeTimer = off._reconnect_timer
	off.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	f += _check("option off → same timer", off._reconnect_timer == kept, true)
	f += _check_i("option off → attempt untouched", off._reconnect_attempt, 1)
	_free_client(off)

	# Idle client (connected, or never reconnecting) → focus changes nothing.
	var idle: SpacetimeDBClient = await _make_client(true)
	idle.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	f += _check_i("idle → still idle", idle._reconnect_state, _STATE_IDLE)
	f += _check("idle → no timer", idle._reconnect_timer == null, true)
	_free_client(idle)

	return f


func _make_client(resume_enabled: bool) -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = true
	options.reconnect_on_app_resume = resume_enabled
	options.reconnect_initial_delay = _LONG_DELAY
	options.reconnect_jitter_fraction = 0.0
	options.max_reconnect_attempts = 5
	client.connection_options = options
	root.add_child(client)
	# The node is only actually inside the tree on the next frame, and
	# _schedule_next_reconnect_attempt needs get_tree() to build its timer.
	await process_frame
	return client


func _free_client(client: SpacetimeDBClient) -> void:
	root.remove_child(client)
	client.free()


func _on_reconnecting(attempt: int, _max_attempts: int) -> void:
	_reconnecting_attempts.append(attempt)


func _on_reconnect_failed() -> void:
	_reconnect_failed_count += 1


func _check(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %d want %d" % [label, got, want])
	return 1

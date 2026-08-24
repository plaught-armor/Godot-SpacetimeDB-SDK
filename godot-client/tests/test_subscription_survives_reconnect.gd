# Regression test: a SpacetimeDBSubscription handle survives an auto-reconnect.
#
# Before this, `_prepare_for_reconnect` ended every outstanding handle and the
# re-subscribe pass issued the saved queries under FRESH internal handles the caller had
# no reference to. The rows came back, so the drop looked recovered — but the caller's
# handle read `ended` forever and, worse, `unsubscribe()` on it was refused for the rest
# of the session while the query it named kept streaming. The only object that could have
# stopped that query lived inside the client and was never handed out.
#
# The reconnect now carries the caller's own handles: a drop SUSPENDS them (no `end`), and
# the re-subscribe re-registers each one under its new query set id. `end` is reserved for
# a subscription that really is over, which is what this file pins from both directions —
# the cases that must NOT end a handle, and the four that must.
#
# Driven through the real _start_reconnection / _prepare_for_reconnect /
# _resubscribe_saved_queries against a fake socket: the wiring between those three is the
# part that regressed, and a test that suspends and restores by hand cannot see it.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_subscription_survives_reconnect.gd
extends SceneTree

var _total: int = 0
var _fails: int = 0
var _ends: int = 0
var _applies: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_a_drop_suspends_rather_than_ends()
	_test_the_reconnect_restores_the_same_handle()
	_test_unsubscribe_works_after_a_reconnect()
	_test_unsubscribe_while_suspended_cancels_the_restore()
	_test_a_query_already_being_dropped_still_ends()
	_test_a_failed_resubscribe_send_ends_the_handle()
	_test_an_end_handler_can_cancel_a_sibling_mid_loop()
	_test_exhausted_attempts_end_the_handle()
	_test_a_terminal_disconnect_ends_a_suspended_handle()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# The drop itself. `active` goes false because no rows are arriving, but nothing about the
# subscription is over — so `end` must not fire, and the handle must be distinguishable
# from both a live one and a dead one.
func _test_a_drop_suspends_rather_than_ends() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)

	client._start_reconnection()

	_check_b("a drop does not end the handle", sub.ended, false)
	_check_i("and emits no `end`", _ends, 0)
	_check_b("it reads suspended", sub.suspended, true)
	_check_b("and not active", sub.active, false)
	_check_i("the cycle is carrying it", client._saved_subscriptions.size(), 1)

	# The prep half of the same boundary must leave it alone too — it is the step that
	# used to end everything in the maps.
	client._prepare_for_reconnect()
	_check_b("the reconnect prep leaves it suspended", sub.suspended, true)
	_check_i("still no `end`", _ends, 0)
	_check_i("and the maps are empty", client.current_subscriptions.size(), 0)

	_teardown(client)


# The restore. The same OBJECT comes back — identity is the whole point, since that is
# what the caller is holding — under a new query set id, and `applied` fires again.
func _test_the_reconnect_restores_the_same_handle() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)
	var id_before: int = sub.query_id

	client._start_reconnection()
	client._prepare_for_reconnect()
	client._resubscribe_saved_queries()

	_check_b(
		"the restored handle is the caller's own object",
		client.pending_subscriptions.values().has(sub),
		true,
	)
	_check_b("it is no longer suspended", sub.suspended, false)
	_check_b("it carries a fresh query set id", sub.query_id != id_before, true)
	_check_b("and it is registered under that id", client.pending_subscriptions.has(sub.query_id), true)

	# The server confirming, which is what SubscribeApplied does to a pending handle.
	sub.applied.emit()
	_check_b("the server's confirmation makes it active again", sub.active, true)
	_check_i("and `applied` fired a second time", _applies, 2)
	_check_i("the cycle is finished with it", client._saved_subscriptions.size(), 0)

	_teardown(client)


# The defect this whole change exists for: the caller can still stop the query. It has to
# go out naming the NEW query set id — the old one belongs to a set the server dropped
# with the connection, and the id counter resets, so it now names something else entirely.
func _test_unsubscribe_works_after_a_reconnect() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)

	client._start_reconnection()
	client._prepare_for_reconnect()
	client._resubscribe_saved_queries()
	sub.applied.emit()

	var conn: _FakeConn = client._connection as _FakeConn
	conn.sent = 0
	_check_i("unsubscribe after a reconnect is accepted", sub.unsubscribe(), OK)
	_check_i("and it goes out on the socket", conn.sent, 1)
	_check_b("naming the live query set id", client._unsubscribing_query_ids.has(sub.query_id), true)

	_teardown(client)


# There is no socket to send on while suspended, so the request is honoured locally: the
# handle ends and the re-subscribe must not bring the query back. A cancellation the pass
# silently ignored would leave the caller holding an ended handle for a live query — the
# original defect with the roles swapped.
func _test_unsubscribe_while_suspended_cancels_the_restore() -> void:
	var client: SpacetimeDBClient = _client()
	var kept: SpacetimeDBSubscription = _live_subscription(client, 7)
	var dropped: SpacetimeDBSubscription = _live_subscription(client, 8)

	client._start_reconnection()
	client._prepare_for_reconnect()

	_check_i("unsubscribe while suspended is accepted", dropped.unsubscribe(), OK)
	_check_b("and ends the handle", dropped.ended, true)

	var conn: _FakeConn = client._connection as _FakeConn
	conn.sent = 0
	client._resubscribe_saved_queries()
	_check_i("only the query still wanted is re-sent", conn.sent, 1)
	_check_b("the kept handle is restored", kept.suspended, false)
	_check_b("the cancelled one is not", client.pending_subscriptions.values().has(dropped), false)

	# The cycle completes on a count of settles, so a set it will never send has to be out
	# of the total too — otherwise only the watchdog ever finishes it.
	kept.applied.emit()
	_check_i("and the cycle still completes", client._saved_subscriptions.size(), 0)

	_teardown(client)


# A query whose Unsubscribe was in flight when the socket died is deliberately not carried
# across (the caller already dropped it, and the server never answering is not consent to
# bring it back). It is therefore not suspended either — it ends with the connection.
func _test_a_query_already_being_dropped_still_ends() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)
	client._unsubscribing_query_ids[7] = true

	client._start_reconnection()
	client._prepare_for_reconnect()

	_check_b("a query the caller already dropped ends", sub.ended, true)
	_check_i("and says so", _ends, 1)
	_check_i("nothing is carried across", client._saved_subscriptions.size(), 0)

	_teardown(client)


# A re-subscribe whose send fails is the end of that subscription for the session. Unlike
# the same failure on a first subscribe — reported by the handle the call returns, before
# any caller can have connected to it — this handle has been held since before the drop,
# so `end` is the only way its listeners hear about it.
func _test_a_failed_resubscribe_send_ends_the_handle() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)

	client._start_reconnection()
	client._prepare_for_reconnect()
	var conn: _FakeConn = client._connection as _FakeConn
	conn.send_error = ERR_UNAVAILABLE
	client._resubscribe_saved_queries()

	_check_b("a failed re-subscribe ends the handle", sub.ended, true)
	_check_i("and emits `end`, not just a return code", _ends, 1)
	_check_i("carrying the send error", sub.error, ERR_UNAVAILABLE)

	_teardown(client)


# The re-subscribe pass emits `end` on a failed send, and that is game code: a handler is
# free to unsubscribe a sibling still waiting its turn in the same synchronous loop. The
# loop must notice. Without the re-check, mark_reattached() no-ops on the ended handle
# (state) while the send still goes out and still registers it (map) — pending_subscriptions
# ends up holding an ENDED handle under an id that handle does not carry, which nothing can
# settle and nothing can unsubscribe, and a Subscribe goes out for a query the caller just
# dropped.
func _test_an_end_handler_can_cancel_a_sibling_mid_loop() -> void:
	var client: SpacetimeDBClient = _client()
	var failing: SpacetimeDBSubscription = _live_subscription(client, 7)
	var sibling: SpacetimeDBSubscription = _live_subscription(client, 8)

	client._start_reconnection()
	client._prepare_for_reconnect()

	var conn: _FakeConn = client._connection as _FakeConn
	conn.fail_next = 1 # the first re-send only, so the loop reaches the second item
	failing.end.connect(func() -> void: sibling.unsubscribe())

	var ids_before: int = client._next_query_id
	client._resubscribe_saved_queries()

	_check_b("the failing handle ended", failing.ended, true)
	_check_b("its handler's cancellation took effect", sibling.ended, true)
	_check_i("nothing was registered for the cancelled query", client.pending_subscriptions.size(), 0)
	_check_i("and no Subscribe went out for it", conn.sent, 0)
	_check_i("nor was a query id taken for it", client._next_query_id - ids_before, 1)
	# The cancelled set still counts toward the cycle, or only the watchdog finishes it.
	_check_i("the cycle still completed", client._saved_subscriptions.size(), 0)

	_teardown(client)


# Reconnect gave up. A handle left suspended here would read neither active nor ended for
# the rest of the session, which is the one shape a caller cannot act on.
func _test_exhausted_attempts_end_the_handle() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)

	client._start_reconnection()
	_check_b("setup: suspended", sub.suspended, true)

	# The next attempt is the one past the budget.
	client._max_reconnect_attempts = 1
	client._reconnect_attempt = 1
	client._schedule_next_reconnect_attempt()

	_check_b("giving up ends the handle", sub.ended, true)
	_check_i("and emits `end` exactly once", _ends, 1)

	_teardown(client)


# disconnect_db() while a cycle is in flight. The handles it was carrying are no longer in
# current/pending, so the terminal path has to reach them where the cycle left them.
func _test_a_terminal_disconnect_ends_a_suspended_handle() -> void:
	var client: SpacetimeDBClient = _client()
	var sub: SpacetimeDBSubscription = _live_subscription(client, 7)

	client._start_reconnection()
	client.disconnect_db()

	_check_b("a terminal disconnect ends a suspended handle", sub.ended, true)
	_check_i("once", _ends, 1)

	_teardown(client)

# --- harness ---


# In the tree because _schedule_next_reconnect_attempt needs one to time a backoff on;
# without it the cycle self-cancels and every assertion below would pass for the wrong
# reason. The backoff is long enough that the attempt never fires during a test.
func _client() -> SpacetimeDBClient:
	_ends = 0
	_applies = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	client.debug_mode = false
	client.use_threading = false
	root.add_child(client)
	client._is_initialized = true
	# Real serializer: a subscribe serializes before it sends, and a null one faults there,
	# which would unwind the test function and take every assertion after it with it.
	client._serializer = BSATNSerializer.new(false)
	client._connection = _FakeConn.new()
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = true
	options.max_reconnect_attempts = 10
	options.reconnect_initial_delay = 600.0
	options.reconnect_max_delay = 600.0
	options.reconnect_jitter_fraction = 0.0
	client.connection_options = options
	return client


# A subscription the server has confirmed, which is what a drop finds.
func _live_subscription(client: SpacetimeDBClient, query_id: int) -> SpacetimeDBSubscription:
	var queries: PackedStringArray = PackedStringArray(
		["SELECT * FROM entity WHERE entity_id = %d" % query_id]
	)
	var sub: SpacetimeDBSubscription = SpacetimeDBSubscription.create(client, query_id, queries)
	client.current_subscriptions[query_id] = sub
	client._next_query_id = maxi(client._next_query_id, query_id + 1)
	sub.applied.emit()
	sub.end.connect(_on_end)
	sub.applied.connect(_on_applied)
	_applies += 1 # the confirmation above, counted before the listener was attached
	return sub


func _teardown(client: SpacetimeDBClient) -> void:
	if client.get_parent() != null:
		client.get_parent().remove_child(client)
	client.free()


func _on_end() -> void:
	_ends += 1


func _on_applied() -> void:
	_applies += 1


# Reports a live socket and records what the client hands it. Skips the parent _init,
# which wants options and a database name this test never uses.
class _FakeConn:
	extends SpacetimeDBConnection

	var sent: int = 0
	var send_error: Error = OK
	## Fails this many sends before behaving normally, so one item of a batch can fail.
	var fail_next: int = 0


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return true


	func is_websocket_active() -> bool:
		return true


	func send_bytes(_bytes: PackedByteArray) -> Error:
		if fail_next > 0:
			fail_next -= 1
			return ERR_UNAVAILABLE
		if send_error != OK:
			return send_error
		sent += 1
		return OK


	func set_token(_token: String) -> void:
		pass


	func disconnect_from_server(_code: int = 1000, _reason: String = "") -> void:
		pass

# --- assertions ---


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got %d want %d" % [label, got, want])


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got %s want %s" % [label, got, want])

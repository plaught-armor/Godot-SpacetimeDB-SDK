# Regression test: subscriptions the server never answers are bounded, the bound refuses
# the NEW request rather than evicting an old one, and the reconnect cannot re-send an
# unbounded number of them.
#
# Measured on 4.8.dev against a loopback server that accepts Subscribe and answers nothing
# (tests/_probe_long_session.gd):
#   before: 300 subscribes -> 300 pending, 600 -> 600, no bound; each entry holds a
#           SpacetimeDBSubscription and its query strings. (Those runs used 300/600 and
#           200; the probe now bursts 5000 and reports the cap, 4096.)
#   worse:  _start_reconnection saves PENDING subscriptions as well as current ones, so
#           200 unanswered subscribes produced 200 Subscribe messages on the socket after
#           an abnormal drop — an outbound burst proportional to how long the server was
#           mute, at the moment the connection is least healthy.
#
# The cap REFUSES the newcomer, unlike the reducer/procedure caps which evict the oldest
# outstanding call. A dropped call loses a response; a dropped subscription would lose
# ownership of state the server is still streaming, because no Unsubscribe was ever sent —
# the rows keep coming with no handle left to stop them. Refusing also means the refused
# subscribe creates nothing: no query id, no message, no server-side query set.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_pending_subscription_cap.gd
extends SceneTree

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_refuses_at_the_cap()
	_test_the_refusal_costs_nothing()
	_test_room_reopens()
	_test_the_resubscribe_loop_is_exempt()
	_test_the_cap_is_a_backstop_not_a_working_limit()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# At the cap the new subscribe is refused and every existing one is untouched — the
# opposite of the call caps, and the point of the whole design.
func _test_refuses_at_the_cap() -> void:
	var client: SpacetimeDBClient = _client()
	var cap: int = SpacetimeDBClient._MAX_PENDING_SUBSCRIPTIONS
	_fill_pending(client, cap)

	var refused: SpacetimeDBSubscription = client.subscribe(_q(9999))
	_check_i(
		"an unsubscribe for the id a failed handle carries is refused, not serialized",
		client.unsubscribe(refused.query_id),
		ERR_INVALID_PARAMETER,
	)
	_check_i("pending stays at the cap", client.pending_subscriptions.size(), cap)
	_check_i("the refused handle carries ERR_BUSY", refused.error, ERR_BUSY)
	_check_b("and is ended, not left pending", refused.ended, true)
	# The oldest is the one a caller is most likely parked on in wait_for_applied, and the
	# one whose rows the server is most likely already streaming.
	_check_b("the oldest pending subscription survives", client.pending_subscriptions.has(0), true)
	_check_b("and the newest one before the cap does too", client.pending_subscriptions.has(cap - 1), true)
	client._connection.free()
	client.free()


# A refusal must not consume an id or leave state behind: it happens before anything is
# taken or sent, so retrying later is a clean retry.
func _test_the_refusal_costs_nothing() -> void:
	var client: SpacetimeDBClient = _client()
	var cap: int = SpacetimeDBClient._MAX_PENDING_SUBSCRIPTIONS
	_fill_pending(client, cap)
	var query_id_before: int = client._next_query_id
	var request_id_before: int = client._next_request_id

	client.subscribe(_q(1))
	client.subscribe(_q(2))
	_check_i("no query id is consumed", client._next_query_id, query_id_before)
	_check_i("no request id is consumed", client._next_request_id, request_id_before)
	_check_i("nothing was added to pending", client.pending_subscriptions.size(), cap)
	_check_i("and nothing to the unsubscribing set", client._unsubscribing_query_ids.size(), 0)
	# Reported on the way into the backlog, not once per call: a game looping subscribes
	# would otherwise get a paragraph a frame. Counted, not flagged — the flag reads true
	# either way, so a report-per-call regression is invisible to it.
	_check_b("the backlog is reported", client._subscribe_backlog_reported, true)
	_check_i("exactly once for two refusals", client._subscribe_backlog_reports, 1)
	client.subscribe(_q(3))
	_check_i("and still once after a third", client._subscribe_backlog_reports, 1)
	client._connection.free()
	client.free()


# The refusal is a state, not a verdict: room reopening lets the next subscribe through,
# and a session boundary re-arms the report along with the map it was about.
func _test_room_reopens() -> void:
	var client: SpacetimeDBClient = _client()
	var cap: int = SpacetimeDBClient._MAX_PENDING_SUBSCRIPTIONS
	_fill_pending(client, cap)
	client.subscribe(_q(1))
	_check_b("refusing while the backlog stands", client._subscribe_backlog_reported, true)

	client.pending_subscriptions.erase(0)
	_check_b("under the cap the gate opens", client.pending_subscriptions.size() < cap, true)
	# A subscribe that gets PAST the gate re-arms the report, whatever happens to it
	# afterwards (this one's send fails — there is no socket) — otherwise the next backlog,
	# hours later, is silent.
	client.subscribe(_q(3))
	_check_b(
		"a subscribe past the gate re-arms the report",
		client._subscribe_backlog_reported,
		false,
	)

	# Set by hand: the subscribe above already cleared it, so without this the assertion
	# below would pass whatever _end_all_subscriptions does.
	client._subscribe_backlog_reported = true
	client._end_all_subscriptions()
	_check_b("a session end re-arms the report", client._subscribe_backlog_reported, false)
	_check_i("and empties pending", client.pending_subscriptions.size(), 0)
	client._connection.free()
	client.free()


# The reconnect's own resubscribe loop is exempt. It issues every saved set in one
# synchronous pass, so pending climbs to the whole set by construction; applying the cap
# there refused the tail of the game's OWN previously-acknowledged state and lost it
# (measured: 4116 live subscriptions, 20 sets gone, `reconnected` emitted as if it had
# worked).
#
# Driven through the real _resubscribe_saved_queries, not by setting a flag: the wiring
# between the loop and the exemption is the part that regressed, and a test that exempts
# by hand cannot see it.
func _test_the_resubscribe_loop_is_exempt() -> void:
	var client: SpacetimeDBClient = _client()
	var cap: int = SpacetimeDBClient._MAX_PENDING_SUBSCRIPTIONS
	# Pending is AT the cap before the loop runs, which is the state a real reconnect
	# reaches by its own second half: without the exemption every set below is refused.
	_fill_pending(client, cap)
	var sets: int = 20
	for i: int in sets:
		var saved: SpacetimeDBSubscription = SpacetimeDBSubscription.create(client, i, _q(i))
		saved.mark_suspended()
		client._saved_subscriptions.append(saved)
	var query_ids_before: int = client._next_query_id
	client._resubscribe_saved_queries()
	# Every saved set got a query id; none was refused. The sends themselves fail (there is
	# no socket), which is what the loop's own one-line summary reports — that summary's
	# count is log-only and is deliberately not asserted here.
	_check_i(
		"every saved set was issued past the cap",
		client._next_query_id - query_ids_before,
		sets,
	)
	_check_i("and none was refused", client._subscribe_backlog_reports, 0)

	# The exemption is lexical, so an ordinary subscribe right after the loop is capped
	# again — a flag left set by a fault inside the loop would show up here.
	var after: SpacetimeDBSubscription = client.subscribe(_q(1))
	_check_i("an ordinary subscribe is still capped", after.error, ERR_BUSY)
	client._connection.free()
	client.free()


# What the reconnect would re-send is bounded by the same cap, and applied subscriptions
# are deliberately outside it.
func _test_the_cap_is_a_backstop_not_a_working_limit() -> void:
	var client: SpacetimeDBClient = _client()
	var cap: int = SpacetimeDBClient._MAX_PENDING_SUBSCRIPTIONS
	# Pinned as a literal, not as the constant: the point is that the number sits far above
	# any real subscribe burst (a chunked world, a per-entity area of interest, or a
	# reconnect resubscribing everything it held), so it is a runaway backstop rather than
	# a working limit. A cap of, say, 256 would fire on a perfectly healthy server.
	_check_i("the cap is the same runaway backstop the call caps use", cap, 4096)

	_fill_pending(client, cap)
	for i: int in cap * 2:
		client.current_subscriptions[100_000 + i] = SpacetimeDBSubscription.create(
			client,
			100_000 + i,
			_q(i),
		)
	client.subscribe(_q(1))
	_check_i("applied subscriptions are untouched", client.current_subscriptions.size(), cap * 2)

	var would_resend: int = 0
	for sub_id: int in client.pending_subscriptions:
		var sub: SpacetimeDBSubscription = client.pending_subscriptions[sub_id]
		if not sub.queries.is_empty() and not client._unsubscribing_query_ids.has(sub_id):
			would_resend += 1
	_check_i("the reconnect re-sends at most the cap from pending", would_resend, cap)
	client._connection.free()
	client.free()

# --- harness ---


func _fill_pending(client: SpacetimeDBClient, count: int) -> void:
	for i: int in count:
		client.pending_subscriptions[i] = SpacetimeDBSubscription.create(client, i, _q(i))


func _client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	client.debug_mode = false
	# subscribe() gates on is_connected_db() before the cap, and these tests drive the cap
	# rather than a socket: a connection object reporting itself connected satisfies that
	# first gate without a handshake. tests/ is exempt from the private-access rule.
	# Without this the refusals below would be ERR_CONNECTION_ERROR and every assertion
	# after them would pass for the wrong reason.
	client._is_initialized = true
	# Real serializer: a subscribe that passes the gate serializes before it sends, and a
	# null one faults there — the fault would unwind the test function and take every
	# assertion after it with it (which is what run_tests.sh's SCRIPT ERROR gate catches).
	client._serializer = BSATNSerializer.new(false)
	var connection: SpacetimeDBConnection = SpacetimeDBConnection.new(
		SpacetimeDBConnectionOptions.new(),
		"probedb",
	)
	connection._is_connected = true
	client._connection = connection
	return client


func _q(i: int) -> PackedStringArray:
	return PackedStringArray(["SELECT * FROM entity WHERE entity_id = %d" % i])


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

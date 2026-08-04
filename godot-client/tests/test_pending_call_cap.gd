# Regression test for the outstanding-call maps' ceiling.
#
# _pending_reducer_calls / _pending_procedure_calls used to shrink only when the
# matching response arrived or the connection died. A response that never arrives while
# the socket stays up — the parser drops a corrupt buffer and keeps the connection, so
# the reply that packet carried is simply gone — stranded its handle (and everything the
# handle holds) for the rest of the session. SpacetimeDBStats bounds the same
# bookkeeping at MAX_PENDING; these maps now use the same ceiling.
#
# Asserts:
#   - the maps stop growing at _MAX_PENDING_CALLS,
#   - the OLDEST entry is the one dropped, and the newest is kept,
#   - a dropped handle that was still PENDING is stamped TIMEOUT with a reason, so an
#     awaiter is not left holding one nothing can complete,
#   - a dropped handle that already has an outcome keeps it,
#   - the cap matches SpacetimeDBStats.MAX_PENDING (the two count the same requests).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_pending_call_cap.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_reducer_cap()
	fails += _test_procedure_cap()
	fails += _test_settled_handle_keeps_its_outcome()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _test_reducer_cap() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var cap: int = SpacetimeDBClient._MAX_PENDING_CALLS
	f += _check_i("cap matches the stats ceiling", cap, SpacetimeDBStats.MAX_PENDING)

	var oldest: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 0)
	client._track_reducer_call(0, oldest)
	for i: int in range(1, cap):
		client._track_reducer_call(i, SpacetimeDBReducerCall.create(client, i))
	f += _check_i("filled to the cap", client._pending_reducer_calls.size(), cap)
	f += _check_b("oldest still tracked at the cap", client._pending_reducer_calls.has(0), true)

	# One past the cap: the map holds, and it is the oldest that goes.
	var newest: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, cap)
	client._track_reducer_call(cap, newest)
	f += _check_i("size held at the cap", client._pending_reducer_calls.size(), cap)
	f += _check_b("oldest dropped", client._pending_reducer_calls.has(0), false)
	f += _check_b("newest kept", client._pending_reducer_calls.get(cap) == newest, true)
	f += _check_b("second-oldest kept", client._pending_reducer_calls.has(1), true)
	f += _check_b(
		"dropped handle stamped TIMEOUT",
		oldest.outcome == SpacetimeDBReducerCall.Outcome.TIMEOUT,
		true,
	)
	f += _check_b("dropped handle says why", not oldest.error_message.is_empty(), true)

	client.free()
	return f


func _test_procedure_cap() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var cap: int = SpacetimeDBClient._MAX_PENDING_CALLS

	var oldest: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.create(client, 0)
	client._track_procedure_call(0, oldest)
	for i: int in range(1, cap + 1):
		client._track_procedure_call(i, SpacetimeDBProcedureCall.create(client, i))
	f += _check_i("procedure size held at the cap", client._pending_procedure_calls.size(), cap)
	f += _check_b("procedure oldest dropped", client._pending_procedure_calls.has(0), false)
	f += _check_b(
		"dropped procedure handle stamped TIMEOUT",
		oldest.outcome == SpacetimeDBProcedureCall.Outcome.TIMEOUT,
		true,
	)

	client.free()
	return f


# A handle that already reached an outcome (a late response stamped it, then the
# response path erased it — or a disconnect stamped it) must not be re-stamped on the
# way out: the reason it actually ended is the one worth keeping.
func _test_settled_handle_keeps_its_outcome() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var cap: int = SpacetimeDBClient._MAX_PENDING_CALLS

	var settled: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 0)
	settled.outcome = SpacetimeDBReducerCall.Outcome.DISCONNECTED
	settled.error_message = "Connection lost during reducer call"
	client._track_reducer_call(0, settled)
	for i: int in range(1, cap + 1):
		client._track_reducer_call(i, SpacetimeDBReducerCall.create(client, i))

	f += _check_b(
		"settled handle keeps DISCONNECTED",
		settled.outcome == SpacetimeDBReducerCall.Outcome.DISCONNECTED,
		true,
	)
	f += _check_b(
		"settled handle keeps its message",
		settled.error_message == "Connection lost during reducer call",
		true,
	)

	client.free()
	return f


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

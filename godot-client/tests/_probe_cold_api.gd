# Probe: every public entry point on a client that was never connected.
#
# Game code calls these before the connection is up more often than it admits — a
# menu scene that subscribes in _ready, a retry button wired to call_reducer, an
# autoload that queries at boot. Each one has to come back promptly and say what
# happened, not fault on a null the initialize path would have filled in, and not
# suspend on a response that can never arrive.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_cold_api.gd
extends SceneTree

## Every awaited call has to finish inside this budget, or it counts as a wedge.
const WAIT_BUDGET_FRAMES: int = 240
const SHORT_TIMEOUT: float = 0.4

var _total: int = 0
var _fails: int = 0
var _client: SpacetimeDBClient


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var script: GDScript = load("res://spacetime_bindings/schema/module_blackholio_client.gd")
	_client = script.new()
	root.add_child(_client)

	_scenario_readers()
	_scenario_subscription_api()
	await _scenario_call_paths()
	await _scenario_query_sql()
	await _scenario_waiters()
	_scenario_teardown()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _scenario_readers() -> void:
	_check_b("is_connected_db", _client.is_connected_db(), false)
	_check_b("get_local_database is null", _client.get_local_database() == null, true)
	_check_b("get_local_identity is empty", _client.get_local_identity().is_empty(), true)
	_check_b("get_token is empty", _client.get_token().is_empty(), true)
	_check_b("get_stats is not null", _client.get_stats() != null, true)


func _scenario_subscription_api() -> void:
	var sub: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM circle"])
	_check_b("subscribe returns a handle", sub != null, true)
	if sub != null:
		_check_b("subscribe handle carries an error", sub.error != OK, true)
		_check_b("subscribe handle is ended", sub.ended, true)
	_check_b(
		"unsubscribe reports a connection error",
		_client.unsubscribe(0) == ERR_CONNECTION_ERROR,
		true,
	)


func _scenario_call_paths() -> void:
	var frames_before: int = _frames()
	var call: SpacetimeDBReducerCall = _client.call_reducer("enter_game", [], [], &"")
	_check_b("call_reducer returns a handle", call != null, true)
	if call != null:
		_check_b(
			"call_reducer handle is not left pending",
			call.outcome != SpacetimeDBReducerCall.Outcome.PENDING,
			true,
		)
	_check_b("call_reducer did not suspend", _frames() == frames_before, true)

	var proc: SpacetimeDBProcedureCall = _client.call_procedure("probe_vector3", [], [], &"")
	_check_b("call_procedure returns a handle", proc != null, true)
	if proc != null:
		_check_b(
			"call_procedure handle is not left pending",
			proc.outcome != SpacetimeDBProcedureCall.Outcome.PENDING,
			true,
		)


func _scenario_query_sql() -> void:
	var done: Array[bool] = [false]
	var rows: Array[TableUpdateData] = []
	var runner: Callable = func() -> void:
		rows = await _client.query_sql("SELECT * FROM circle", SHORT_TIMEOUT)
		done[0] = true
	runner.call()
	var finished: bool = await _await_flag(done)
	_check_b("query_sql returns within the budget", finished, true)
	_check_b("query_sql returns no rows", rows.is_empty(), true)


func _scenario_waiters() -> void:
	var done: Array[bool] = [false]
	var runner: Callable = func() -> void:
		var _r: TransactionUpdateMessage = await _client.wait_for_reducer_response(
			999,
			SHORT_TIMEOUT,
		)
		var _p: PackedByteArray = await _client.wait_for_procedure_response(999, SHORT_TIMEOUT)
		done[0] = true
	runner.call()
	_check_b("wait_for_* time out rather than wedge", await _await_flag(done), true)


func _scenario_teardown() -> void:
	_client.disconnect_db()
	_check_b("disconnect_db on a cold client is a no-op", _client.is_connected_db(), false)
	_client.disconnect_db()
	_check_b("a second disconnect_db is still fine", _client.is_connected_db(), false)

# --- harness ---


func _frames() -> int:
	return Engine.get_process_frames()


func _await_flag(flag: Array[bool]) -> bool:
	for _i: int in WAIT_BUDGET_FRAMES:
		if flag[0]:
			return true
		await process_frame
	return false


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1

# Regression test: a timeout or delay the SDK cannot wait out is refused, so an await ends
# when the caller meant it to instead of on the next frame or never.
#
# Every awaited call in the public surface takes a seconds argument from game code —
# `query_sql`, `wait_for_reducer_response`, `wait_for_procedure_response`,
# `SpacetimeDBReducerCall.wait_for_response`, `SpacetimeDBProcedureCall.wait_for_response`,
# `SpacetimeDBSubscription.wait_for_applied` / `wait_for_end` — and every one of them went
# straight into `SceneTree.create_timer`. Measured before the fix: `0.0`, a negative value
# and NaN all returned in 0 ms, so the caller was told "the server did not answer" before
# the server could have (`SceneTree.process_timers` reads `time_left` through
# `MAX(time_left, 0.0)`, which launders NaN to zero), and `INF` — the obvious spelling of
# "no timeout" — never returned at all, taking the caller's coroutine, its signal
# connection and its response-cache entry with it for the life of the process.
#
# Two more of the same class in SpacetimeAuth: `backoff_delay` clamped with `minf`, which
# returns its second argument when `a < b` is false, so NaN and INF survived from either
# side; and `request_timeout_seconds`, guarded only by `<= 0.0`, which both NaN and INF
# pass — `HTTPRequest` then starts no timeout timer at all (NaN fails its `timeout > 0`
# gate) or one that never counts down (INF), and the exchange hangs with `_pending` latched
# true, refusing every later exchange on that node.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_timeout_resolution.gd
#
# Not reachable from here, deliberately: whether `_wait_for_response` resolves BEFORE or
# after its response-cache short-circuit. Both orders return the same cached value; the only
# difference is whether the diagnostic fires, and GDScript cannot observe a push_error from
# inside the process. Same for the subscription waiters' hoist above their state checks.
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## A deadline this short is still legal — above the floor — and has to be honoured rather
## than rounded up to the default, or the fix would have made every short wait a long one.
const SHORT_LEGAL_TIMEOUT: float = 0.1
## Window a refused deadline has to still be waiting after. The pre-fix wait returned in
## 0 ms. It does NOT pin which fallback was used — the resolver table above does that —
## only that the wait outlives the frame it started on.
const STILL_WAITING_MS: int = 400
## Bounded-loop backstop for the windows below (NASA rule 2), not the wait itself — a
## headless frame is not 1/60 s, so the wall clock is what bounds them.
const MAX_WINDOW_FRAMES: int = 100000
## Ceiling for a wait that IS expected to end: several times the deadline being waited.
const SHORT_WAIT_BUDGET_MS: int = 3000
## Worst case one exchange may suspend for — every attempt's request timeout plus every
## backoff delay between them, with all three knobs pushed past their ceilings. Minutes is a configuration a caller can
## have asked for; the pre-fix product was hours (500 attempts x an hour-long cap) and
## reachable by accident, which is what this bounds. The response deadline's own ceiling is
## an hour — defensible for "wait for an answer", never for "pause between two tries of one
## exchange" — so this assertion is also what keeps the two constants apart.
const MAX_AUTH_SUSPENSION_SECONDS: float = 1800.0

var _total: int = 0
var _fails: int = 0
var _client: SpacetimeDBClient


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_client = SpacetimeDBClient.new()
	root.add_child(_client)

	_case_resolver_table()
	_case_fallbacks_are_in_range()
	_case_defaults_agree()
	await _case_wait_for_response()
	await _case_public_waiter()
	await _case_subscription_waits()
	await _case_freed_owner()
	_case_auth_backoff()
	await _case_auth_request_timeout()

	_client.queue_free()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- the resolvers themselves ---


func _case_resolver_table() -> void:
	var min_timeout: float = SpacetimeDBClient.MIN_RESPONSE_TIMEOUT_SECONDS
	var max_timeout: float = SpacetimeDBClient.MAX_RESPONSE_TIMEOUT_SECONDS
	var fallback: float = SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS
	# Usable deadlines pass through untouched, including both ends of the range.
	_check_f("resolve 10.0", SpacetimeDBClient.resolve_wait_timeout(10.0, fallback, "t"), 10.0)
	_check_f(
		"resolve the floor itself",
		SpacetimeDBClient.resolve_wait_timeout(min_timeout, fallback, "t"),
		min_timeout,
	)
	_check_f(
		"resolve the ceiling itself",
		SpacetimeDBClient.resolve_wait_timeout(max_timeout, fallback, "t"),
		max_timeout,
	)
	_check_f(
		"resolve a legal short deadline",
		SpacetimeDBClient.resolve_wait_timeout(SHORT_LEGAL_TIMEOUT, fallback, "t"),
		SHORT_LEGAL_TIMEOUT,
	)
	# Below the floor the wait ends on the next frame, which is not what any of these
	# spellings means, so each falls back rather than being read as a request for it.
	for refused: float in [0.0, -5.0, NAN, min_timeout - 0.001]:
		_check_f(
			"resolve %s falls back" % refused,
			SpacetimeDBClient.resolve_wait_timeout(refused, fallback, "t"),
			fallback,
		)
	# The caller's own fallback is used when it passes one — the subscription handle's
	# waiters default to a shorter deadline than the client's, so a refused value there
	# has to land on THEIR default or a refusal would silently double the wait.
	_check_f(
		"a caller's own fallback is honoured",
		SpacetimeDBClient.resolve_wait_timeout(
			0.0,
			SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS,
			"t",
		),
		SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS,
	)
	# Above the ceiling the intent is unambiguous — wait longer — so it is clamped, which
	# is what turns INF from "never returns" into a wait that ends.
	for clamped: float in [INF, max_timeout + 1.0, 1.0e30]:
		_check_f(
			"resolve %s clamps" % clamped,
			SpacetimeDBClient.resolve_wait_timeout(clamped, fallback, "t"),
			max_timeout,
		)
	# The auth retry delay is the same shape, applied to a delay rather than a deadline.
	var retry_fallback: float = SpacetimeAuthProtocol.DEFAULT_BASE_RETRY_DELAY
	_check_f(
		"resolve_retry_delay 0.5",
		SpacetimeAuthProtocol.resolve_retry_delay(0.5, retry_fallback, "t"),
		0.5,
	)
	for refused_delay: float in [0.0, -1.0, NAN]:
		_check_f(
			"resolve_retry_delay %s falls back" % refused_delay,
			SpacetimeAuthProtocol.resolve_retry_delay(refused_delay, retry_fallback, "t"),
			retry_fallback,
		)
	_check_f(
		"resolve_retry_delay INF clamps",
		SpacetimeAuthProtocol.resolve_retry_delay(INF, retry_fallback, "t"),
		SpacetimeAuthProtocol.MAX_RETRY_DELAY_SECONDS,
	)
	# Every ceiling pinned against a LITERAL, not against itself: written symbolically, a
	# ceiling raised to 1e30 leaves every case above still passing while
	# `resolve_wait_timeout(INF)` goes back to producing a timer that never fires.
	_check_b(
		"the response-deadline ceiling stays human-scale (%.0f s)" % max_timeout,
		max_timeout <= 3600.0,
		true,
	)
	_check_b(
		"the response-deadline floor stays under a tenth of a second (%.3f s)" % min_timeout,
		min_timeout <= 0.1,
		true,
	)
	_check_b(
		"the default deadline stays under a minute (%.0f s)" % fallback,
		fallback <= 60.0,
		true,
	)
	# An auth exchange suspends for a request timeout per attempt PLUS a backoff delay
	# between attempts, holds its in-flight guard the whole time and cannot be cancelled,
	# so what has to be bounded is the product of all three ceilings — bounding one factor
	# left 10 hours reachable, and bounding none left days.
	var worst_case: float = (
		SpacetimeAuthProtocol.MAX_REQUEST_TIMEOUT_SECONDS
		* float(SpacetimeAuthProtocol.MAX_ATTEMPTS)
		+ SpacetimeAuthProtocol.MAX_RETRY_DELAY_SECONDS
		* float(SpacetimeAuthProtocol.MAX_ATTEMPTS - 1)
	)
	_check_b(
		"worst-case auth suspension %.0f s stays under %.0f s"
		% [worst_case, MAX_AUTH_SUSPENSION_SECONDS],
		worst_case <= MAX_AUTH_SUSPENSION_SECONDS,
		true,
	)


func _case_fallbacks_are_in_range() -> void:
	# A resolver answers a refused value with its fallback, so a fallback outside the range
	# would answer one unusable value with another — and every expectation written in terms
	# of a fallback constant moves with it, which is what makes this its own case.
	var pairs: Array = [
		[
			"DEFAULT_RESPONSE_TIMEOUT_SECONDS",
			SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS,
			SpacetimeDBClient.MIN_RESPONSE_TIMEOUT_SECONDS,
			SpacetimeDBClient.MAX_RESPONSE_TIMEOUT_SECONDS,
		],
		[
			"SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS",
			SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS,
			SpacetimeDBClient.MIN_RESPONSE_TIMEOUT_SECONDS,
			SpacetimeDBClient.MAX_RESPONSE_TIMEOUT_SECONDS,
		],
		[
			"DEFAULT_BASE_RETRY_DELAY",
			SpacetimeAuthProtocol.DEFAULT_BASE_RETRY_DELAY,
			SpacetimeAuthProtocol.MIN_RETRY_DELAY_SECONDS,
			SpacetimeAuthProtocol.MAX_RETRY_DELAY_SECONDS,
		],
		[
			"DEFAULT_MAX_RETRY_DELAY",
			SpacetimeAuthProtocol.DEFAULT_MAX_RETRY_DELAY,
			SpacetimeAuthProtocol.MIN_RETRY_DELAY_SECONDS,
			SpacetimeAuthProtocol.MAX_RETRY_DELAY_SECONDS,
		],
	]
	for row: Array in pairs:
		_check_b(
			"%s (%s) is inside its own range" % [row[0], row[1]],
			row[1] >= row[2] and row[1] <= row[3],
			true,
		)
	# One row of the backoff table pinned to a literal rather than to a constant, so a
	# constant moved to a degenerate value cannot take the expectation with it.
	_check_f(
		"backoff falls back to a literal 0.5",
		SpacetimeAuthProtocol.backoff_delay(0, 0.0, 4.0),
		0.5,
	)
	# The attempt budget is clamped above and left alone inside the range.
	_check_b(
		"resolve_attempts clamps a huge budget",
		SpacetimeAuthProtocol.resolve_attempts(500) == SpacetimeAuthProtocol.MAX_ATTEMPTS,
		true,
	)
	for unusable_budget: int in [0, -3]:
		_check_b(
			"resolve_attempts(%d) answers with a usable budget" % unusable_budget,
			SpacetimeAuthProtocol.resolve_attempts(unusable_budget) == 1,
			true,
		)
	_check_b(
		"resolve_attempts leaves the default alone",
		SpacetimeAuthProtocol.resolve_attempts(_auth_default_attempts()) == _auth_default_attempts(),
		true,
	)
	# The request timeout is refused below (0.0 answers "refuse") and clamped above — a
	# huge FINITE value is the same wedge as INF and passes any is-finite check.
	_check_f(
		"resolve_request_timeout keeps a usable value",
		SpacetimeAuthProtocol.resolve_request_timeout(15.0),
		15.0,
	)
	for refused_timeout: float in [0.0, -1.0, NAN, 0.01]:
		_check_f(
			"resolve_request_timeout %s refuses" % refused_timeout,
			SpacetimeAuthProtocol.resolve_request_timeout(refused_timeout),
			SpacetimeAuthProtocol.REFUSED_REQUEST_TIMEOUT,
		)
	# The refusal is a value HTTPRequest REJECTS, not 0.0, which it reads as "no timeout" —
	# a caller who assigned the refusal straight to a request would otherwise install the
	# wedge this resolution exists to prevent.
	_check_b(
		"the refusal is not HTTPRequest's no-timeout value",
		SpacetimeAuthProtocol.REFUSED_REQUEST_TIMEOUT < 0.0,
		true,
	)
	for clamped_timeout: float in [INF, 1.0e12]:
		_check_f(
			"resolve_request_timeout %s clamps" % clamped_timeout,
			SpacetimeAuthProtocol.resolve_request_timeout(clamped_timeout),
			SpacetimeAuthProtocol.MAX_REQUEST_TIMEOUT_SECONDS,
		)


func _case_defaults_agree() -> void:
	# A refused deadline has to behave as if the caller had passed nothing, so each
	# waiter's fallback must be its OWN default argument. Read off the engine's method
	# list rather than restating the numbers here — restating them makes the case a
	# tautology that passes after a signature changes.
	var procedure_call: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.new()
	var reducer_call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.new()
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.new()
	var client_default: float = SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS
	var sub_default: float = SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS
	var expected: Array = [
		[_client, "query_sql", 0, client_default],
		[_client, "wait_for_reducer_response", 0, client_default],
		[_client, "wait_for_procedure_response", 0, client_default],
		[reducer_call, "wait_for_response", 0, client_default],
		[procedure_call, "wait_for_response", 0, client_default],
		[subscription, "wait_for_applied", 0, sub_default],
		[subscription, "wait_for_end", 0, sub_default],
	]
	for row: Array in expected:
		_check_f("%s default argument" % row[1], _default_arg(row[0], row[1], row[2]), row[3])
	_check_b(
		"the floor is under the shortest deadline the SDK's own tests use",
		SpacetimeDBClient.MIN_RESPONSE_TIMEOUT_SECONDS < SHORT_LEGAL_TIMEOUT,
		true,
	)


## Default value of [param method_name]'s argument at [param index] among the defaulted
## ones (the engine lists only defaulted arguments, so the deadline is index 0 wherever it
## is the only one), read from the engine's own method list. NAN when the method or the default is
## missing, so a signature change fails the case rather than silently skipping it.
func _default_arg(obj: Object, method_name: String, index: int) -> float:
	for method: Dictionary in obj.get_method_list():
		if method["name"] != method_name:
			continue
		var defaults: Array = method["default_args"]
		if index >= defaults.size():
			return NAN
		return float(defaults[index])
	return NAN


## Default [member SpacetimeAuth.max_attempts], read off a fresh node rather than restated.
func _auth_default_attempts() -> int:
	var auth: SpacetimeAuth = SpacetimeAuth.new()
	var attempts: int = auth.max_attempts
	auth.free()
	return attempts

# --- the client's own await ---


func _case_wait_for_response() -> void:
	# A legal short deadline still ends the wait on its own terms.
	var short: Array = await _timed_wait(SHORT_LEGAL_TIMEOUT, SHORT_WAIT_BUDGET_MS)
	_check_b("a 0.1 s deadline still times out", short[0], true)

	# A refused one no longer resolves before the server could have answered. Nothing
	# will ever answer request id 9999, so "still waiting" is the whole assertion: the
	# pre-fix wait was over in 0 ms.
	for refused: float in [0.0, NAN]:
		var pending: Array = await _timed_wait(refused, STILL_WAITING_MS)
		_check_b("a %s deadline is not an instant timeout" % refused, pending[0], false)

	# WHICH fallback, not just "not instant": the waiter passes its own default, and a
	# fallback swapped for any value above half a second clears the window above.
	var fallback_ms: float = SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS * 1000.0
	var landed: Array = await _timed_wait(0.0, int(fallback_ms * 1.5))
	_check_b(
		"a refused deadline lands on the client's own default (%d ms)" % landed[1],
		(
			landed[0] and float(landed[1]) > fallback_ms * 0.5
			and float(landed[1]) < fallback_ms * 1.5
		),
		true,
	)


func _case_public_waiter() -> void:
	# The same thing through a PUBLIC entry point, so the case still fires if a waiter
	# stops funnelling through _wait_for_response.
	var done: Array[bool] = [false]
	_drive_public_waiter(done)
	var started: int = Time.get_ticks_msec()
	var frames: int = 0
	while not done[0] and frames < MAX_WINDOW_FRAMES:
		if Time.get_ticks_msec() - started > STILL_WAITING_MS:
			break
		await process_frame
		frames += 1
	_check_b("wait_for_reducer_response(id, 0.0) is not an instant timeout", done[0], false)


func _drive_public_waiter(done: Array[bool]) -> void:
	var _r: TransactionUpdateMessage = await _client.wait_for_reducer_response(9998, 0.0)
	done[0] = true


## [returned, elapsed_ms] for a _wait_for_response nothing will ever answer, watched for
## at most [param budget_ms].
func _timed_wait(timeout_seconds: float, budget_ms: int) -> Array:
	var done: Array[bool] = [false]
	var started: int = Time.get_ticks_msec()
	var elapsed: PackedInt32Array = [0]
	_drive_wait(timeout_seconds, done, elapsed, started)
	var frames: int = 0
	while not done[0] and frames < MAX_WINDOW_FRAMES:
		if Time.get_ticks_msec() - started > budget_ms:
			break
		await process_frame
		frames += 1
	return [done[0], elapsed[0]]


func _drive_wait(timeout_seconds: float, done: Array[bool], elapsed: PackedInt32Array, started: int) -> void:
	var _r: Variant = await _client._wait_for_response(
		9999,
		_client._reducer_result_cache,
		_client.reducer_result_received,
		timeout_seconds,
	)
	elapsed[0] = Time.get_ticks_msec() - started
	done[0] = true

# --- the subscription handle's poll loops ---


func _case_subscription_waits() -> void:
	# `timer.time_left > 0.0` is false on the first pass for a refused deadline, so the
	# caller got ERR_TIMEOUT without ever yielding. Both waiters, not just the applied
	# one — they resolve independently.
	for waiter: String in ["wait_for_applied", "wait_for_end"]:
		for refused: float in [0.0, -1.0, NAN]:
			var pending: Array = await _timed_sub_wait(waiter, refused, STILL_WAITING_MS)
			_check_b("%s(%s) is not an instant timeout" % [waiter, refused], pending[0], false)
		var honoured: Array = await _timed_sub_wait(
			waiter,
			SHORT_LEGAL_TIMEOUT,
			SHORT_WAIT_BUDGET_MS,
		)
		_check_b("%s(0.1) still times out" % waiter, honoured[0], true)
		_check_b("%s(0.1) reports ERR_TIMEOUT" % waiter, honoured[1] == ERR_TIMEOUT, true)

	# WHICH fallback a refused deadline lands on, not merely that it is not instant: the
	# handle's waiters default to a shorter deadline than the client's, so passing the
	# client's would silently double every refused wait here. Measured end to end, since
	# the resolver honouring a fallback and the waiter passing its own are different facts.
	var landed: Array = await _timed_sub_wait(
		"wait_for_applied",
		0.0,
		int(SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS * 1000.0),
	)
	var expected_ms: float = SpacetimeDBSubscription.DEFAULT_WAIT_SECONDS * 1000.0
	_check_b(
		"a refused deadline lands on the handle's own default (%d ms)" % landed[2],
		(
			landed[0] and float(landed[2]) > expected_ms * 0.5
			and float(landed[2]) < expected_ms * 1.5
		),
		true,
	)


## [returned, error, elapsed_ms] for a subscription waiter on a handle nothing settles.
func _timed_sub_wait(waiter: String, timeout_sec: float, budget_ms: int) -> Array:
	var handle: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
		_client,
		77,
		PackedStringArray(["SELECT * FROM circle"]),
	)
	var done: Array[bool] = [false]
	var result: PackedInt32Array = [OK]
	if waiter == "wait_for_applied":
		_drive_applied(handle, timeout_sec, done, result)
	else:
		_drive_end(handle, timeout_sec, done, result)
	var started: int = Time.get_ticks_msec()
	var frames: int = 0
	while not done[0] and frames < MAX_WINDOW_FRAMES:
		if Time.get_ticks_msec() - started > budget_ms:
			break
		await process_frame
		frames += 1
	return [done[0], result[0], Time.get_ticks_msec() - started]


func _drive_applied(
	handle: SpacetimeDBSubscription,
	timeout_sec: float,
	done: Array[bool],
	result: PackedInt32Array,
) -> void:
	result[0] = await handle.wait_for_applied(timeout_sec)
	done[0] = true


func _drive_end(
	handle: SpacetimeDBSubscription,
	timeout_sec: float,
	done: Array[bool],
	result: PackedInt32Array,
) -> void:
	result[0] = await handle.wait_for_end(timeout_sec)
	done[0] = true


func _case_freed_owner() -> void:
	# The owner is a Node the caller does not own: a scene change can free it while a
	# handle is still held. Touching a freed instance faults, and a fault unwinds the
	# function to its DEFAULT — Error 0, i.e. OK — so an unguarded waiter reports
	# "applied" (or, for wait_for_end, "ended cleanly") past a single error line.
	var doomed: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(doomed)
	var applied_handle: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
		doomed,
		78,
		PackedStringArray(["SELECT * FROM circle"]),
	)
	var end_handle: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
		doomed,
		79,
		PackedStringArray(["SELECT * FROM circle"]),
	)
	root.remove_child(doomed)
	doomed.free()
	var applied_result: Error = await applied_handle.wait_for_applied(SHORT_LEGAL_TIMEOUT)
	_check_b(
		"wait_for_applied on a freed owner reports ERR_DOES_NOT_EXIST",
		applied_result == ERR_DOES_NOT_EXIST,
		true,
	)
	var end_result: Error = await end_handle.wait_for_end(SHORT_LEGAL_TIMEOUT)
	_check_b(
		"wait_for_end on a freed owner does not report OK",
		end_result == ERR_DOES_NOT_EXIST,
		true,
	)

# --- the auth retry backoff ---


func _case_auth_backoff() -> void:
	var base_default: float = SpacetimeAuthProtocol.DEFAULT_BASE_RETRY_DELAY
	var cap_default: float = SpacetimeAuthProtocol.DEFAULT_MAX_RETRY_DELAY
	var max_delay: float = SpacetimeAuthProtocol.MAX_RETRY_DELAY_SECONDS
	# Attempt 0 returns the base, and the sequence still escalates and still saturates at
	# the cap — the resolution must not have flattened the backoff it protects.
	_check_f("backoff attempt 0 is the base", SpacetimeAuthProtocol.backoff_delay(0, 0.5, 4.0), 0.5)
	_check_f(
		"backoff attempt 2 doubles twice",
		SpacetimeAuthProtocol.backoff_delay(2, 0.5, 4.0),
		2.0,
	)
	_check_f("backoff saturates at the cap", SpacetimeAuthProtocol.backoff_delay(9, 0.5, 4.0), 4.0)
	# Each degenerate bound resolves to a NAMED value, not merely to something in range:
	# `minf` returns its second argument when `a < b` is false, so a NaN or INF on one side
	# alone lands on the other side's value even with the resolvers removed.
	var expected: Array = [
		[0.0, 4.0, base_default],
		[-1.0, 4.0, base_default],
		[NAN, 4.0, base_default],
		[INF, 4.0, 4.0],
		[0.5, 0.0, minf(cap_default, 0.5)],
		[0.5, -1.0, minf(cap_default, 0.5)],
		[0.5, NAN, minf(cap_default, 0.5)],
		[INF, INF, max_delay],
	]
	for row: Array in expected:
		_check_f(
			"backoff_delay(base=%s cap=%s)" % [row[0], row[1]],
			SpacetimeAuthProtocol.backoff_delay(0, row[0], row[1]),
			row[2],
		)


func _case_auth_request_timeout() -> void:
	# NaN and INF both pass a `<= 0.0` guard, and HTTPRequest answers each by never timing
	# the request out — measured against a host that accepts and never answers: no result,
	# no signal, and `_pending` latched true, so every later exchange is refused. Refused
	# before any socket is opened, so this needs no server.
	var auth: SpacetimeAuth = SpacetimeAuth.new()
	# Repointed BEFORE the refusals, not after: this is the regression test for a guard
	# that stops the request, so the day the guard regresses it must fail against a closed
	# loopback port, not POST a credential to the production endpoint with no timeout set.
	auth.token_url = "http://127.0.0.1:1/oidc/token"
	auth.max_attempts = 1
	root.add_child(auth)
	for refused: float in [NAN, 0.0, -1.0, 0.01]:
		auth.request_timeout_seconds = refused
		var result: SpacetimeAuthResult = await auth.exchange(
			"urn:spacetimeauth:steam-ticket",
			{ "steam_ticket": "aa" },
			"client-id",
		)
		_check_b(
			"exchange refuses request_timeout_seconds = %s" % refused,
			result != null and result.error.contains("request_timeout_seconds"),
			true,
		)
		# The message a caller can read has to be true of the value it fired on: a
		# sub-frame deadline IS finite and IS above zero, so "must be > 0" was a rule the
		# code did not implement.
		_check_b(
			"and the refusal names the range, not just a sign",
			(result != null and result.error.contains(
					"%.2f" % SpacetimeAuthProtocol.MIN_REQUEST_TIMEOUT_SECONDS
				)),
			true,
		)
	# The guard must not have swallowed the legal value with it: a finite positive one gets
	# past it and fails later, on the network, with a different error.
	auth.request_timeout_seconds = 0.25
	var reachable: SpacetimeAuthResult = await auth.exchange(
		"urn:spacetimeauth:steam-ticket",
		{ "steam_ticket": "aa" },
		"client-id",
	)
	_check_b(
		"a finite positive timeout gets past the guard",
		reachable != null and not reachable.error.contains("request_timeout_seconds"),
		true,
	)
	_check_f("and reaches HTTPRequest unchanged", auth._http.timeout, 0.25)
	# INF and a huge FINITE value are the same wedge — HTTPRequest starts a timer that will
	# not expire inside the process's life — and the finite one passes any is-finite guard,
	# so both are clamped rather than refused: the exchange runs and ends on the network.
	for clamped_timeout: float in [INF, 1.0e12]:
		auth.request_timeout_seconds = clamped_timeout
		var clamped: SpacetimeAuthResult = await auth.exchange(
			"urn:spacetimeauth:steam-ticket",
			{ "steam_ticket": "aa" },
			"client-id",
		)
		_check_b(
			"request_timeout_seconds = %s is clamped, not refused" % clamped_timeout,
			clamped != null and not clamped.error.contains("request_timeout_seconds"),
			true,
		)
		# The clamp has to REACH the engine. Against a closed port the request fails on
		# transport whatever the timeout holds, so without this the whole fix reverts to
		# reading the raw @export with every case still green.
		_check_f(
			"the clamped timeout reaches HTTPRequest",
			auth._http.timeout,
			SpacetimeAuthProtocol.MAX_REQUEST_TIMEOUT_SECONDS,
		)
	auth.queue_free()


func _check_f(label: String, got: float, want: float) -> void:
	_total += 1
	if is_equal_approx(got, want):
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s (got %s want %s)" % [label, got, want])


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s (got %s want %s)" % [label, got, want])

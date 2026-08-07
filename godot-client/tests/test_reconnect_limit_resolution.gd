# Regression test: a reconnect knob the SDK cannot pace a cycle with is refused, so the
# backoff stays an escalating backoff instead of collapsing into a per-frame connection
# storm.
#
# The socket knobs were resolved and clamped before this; the reconnect knobs went
# straight into `_calculate_backoff`. Five separate values computed a 0.0 delay for every
# attempt — `reconnect_initial_delay` <= 0, `reconnect_max_delay` <= 0,
# `reconnect_backoff_multiplier` <= 0, a NaN anywhere in the four (NaN propagates, and
# `SceneTree.create_timer(NAN)` times out on the NEXT frame), and
# `reconnect_jitter_fraction` > 1.0 (the random offset can then exceed the delay it is
# subtracted from). A 0.0 delay is a reconnect attempt per frame, and
# `max_reconnect_attempts` — documented as "0 means infinite", and silently infinite for
# a negative value too — is what would have bounded it. Measured against a closed port:
# 50 attempts in 120 frames, unbounded, versus 2 for the defaults
# (tests/_probe_reconnect_storm.gd).
#
# Two more shapes the same resolution closes: a negative jitter fraction is ADDED to the
# delay, so the backoff overshoots `reconnect_max_delay` (measured 43.9 s against a 30 s
# cap), and an infinite delay reaches `create_timer(INF)`, which never times out — a cycle
# with no next attempt, no `reconnect_failed` and no `disconnected`.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_reconnect_limit_resolution.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## Shape-valid placeholder so connect_db reaches the socket rather than the token fetch.
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
## Loopback port nothing listens on: every attempt is refused as fast as the transport
## can report it, so the backoff is the only thing pacing the cycle.
const CLOSED_PORT_URL: String = "http://127.0.0.1:1"
## How many attempts each backoff sequence is checked over.
const SEQUENCE_LEN: int = 12
## Wall-clock window the live cycle is watched over. Long enough for the resolved cycle's
## first attempts (~1 s, then ~2 s) to land, short enough to keep the suite quick.
const CYCLE_WINDOW_MS: int = 2500
## Bounded-loop backstop for that window (NASA rule 2), not the wait itself.
const MAX_CYCLE_FRAMES: int = 20000
## Attempts the resolved cycle may make inside [constant CYCLE_WINDOW_MS]. The pre-fix
## cycle made one per ~2 frames, i.e. hundreds.
const MAX_ATTEMPTS_IN_WINDOW: int = 5
## Wall-clock ceiling for the attempt-budget case. The whole budget runs at the delay
## floor, so it needs about DEFAULT_MAX_RECONNECT_ATTEMPTS * MIN_RECONNECT_DELAY_SECONDS
## plus the refused connects; this is several times that.
const BUDGET_WINDOW_MS: int = 15000

var _total: int = 0
var _fails: int = 0
## Counted from the `reconnecting` signal. A member, not a local captured by the handler
## lambda: GDScript captures locals BY VALUE, so a captured counter stays at zero and the
## pacing assertion below would pass for having observed nothing.
var _attempts: int = 0
var _failed: int = 0
var _terminal_disconnects: int = 0
## What `reconnecting` told game code the budget was. Game code sees this number, so it has
## to be the resolved one and not the raw option — an SDK that reports the refused value
## while looping on the resolved one is lying to the handler.
var _last_reported_max_attempts: int = -99


func _initialize() -> void:
	_run.call_deferred()


func _check_f(label: String, got: float, want: float) -> void:
	_total += 1
	if is_equal_approx(got, want):
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %s, want %s" % [label, got, want])


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %d, want %d" % [label, got, want])


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %s, want %s" % [label, got, want])


## Every knob value that computed a zero, NaN or infinite backoff, as data rather than as
## mutating lambdas: an inline lambda is what the formatter mangles (the client carries the
## same note), and a table is what a new case gets added to.
##
## The last row is the one the reviewer found and the rest miss — every value in it passes
## its own resolver untouched, and the cycle still paces under a frame unless the floor is
## applied to the computed backoff itself.
static func _hostile_knob_sets() -> Array[Dictionary]:
	return [
		{ &"reconnect_initial_delay": 0.0 },
		{ &"reconnect_initial_delay": -1.0 },
		{ &"reconnect_initial_delay": NAN },
		{ &"reconnect_initial_delay": INF },
		{ &"reconnect_max_delay": 0.0 },
		{ &"reconnect_max_delay": -5.0 },
		{ &"reconnect_max_delay": NAN },
		{ &"reconnect_backoff_multiplier": 0.0 },
		{ &"reconnect_backoff_multiplier": -2.0 },
		{ &"reconnect_backoff_multiplier": 0.5 },
		{ &"reconnect_backoff_multiplier": NAN },
		{ &"reconnect_jitter_fraction": 2.0 },
		{ &"reconnect_jitter_fraction": -1.0 },
		{ &"reconnect_jitter_fraction": NAN },
		{
			&"reconnect_initial_delay": SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS,
			&"reconnect_max_delay": SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS,
			&"reconnect_backoff_multiplier": 1.0,
			&"reconnect_jitter_fraction": 1.0,
		},
	]


static func _options_from(knobs: Dictionary) -> SpacetimeDBConnectionOptions:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	for knob: StringName in knobs:
		opts.set(knob, knobs[knob])
	return opts


## Values no resolver can produce, written over the pacing members before the act. Without
## them an assertion that a refused knob came back as its DEFAULT is satisfied by a client
## that never resolved anything, because the members are INITIALIZED to those defaults.
func _poison_pacing(client: SpacetimeDBClient) -> void:
	client._reconnect_initial_delay = 999.0
	client._reconnect_max_delay = 998.0
	client._reconnect_backoff_multiplier = 997.0
	client._reconnect_jitter_fraction = 0.123
	client._max_reconnect_attempts = 996


## A client whose reconnect pacing is [param opts] put through the SDK's own resolution,
## i.e. what a connect leaves behind — without a socket. Calls the real helper rather than
## re-applying the four resolvers, so a test cannot pass against a resolution step the
## client does not actually perform.
func _resolved_client(opts: SpacetimeDBConnectionOptions) -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client._resolve_reconnect_pacing(opts)
	return client


func _test_delay_resolution() -> void:
	var fallback: float = SpacetimeDBClient.DEFAULT_RECONNECT_INITIAL_DELAY
	var minimum: float = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	var maximum: float = SpacetimeDBClient.MAX_RECONNECT_DELAY_SECONDS
	var cases: Array = [
		["a usable delay is passed through", 5.0, 5.0],
		["the minimum itself is usable", minimum, minimum],
		["the maximum itself is usable", maximum, maximum],
		["above the maximum clamps down", maximum * 10.0, maximum],
		["INF clamps down (create_timer(INF) never fires)", INF, maximum],
		["a sub-frame delay falls back", minimum * 0.5, fallback],
		["zero falls back (it is not a request for instant retry)", 0.0, fallback],
		["a negative delay falls back", -1.0, fallback],
		["NaN falls back (create_timer(NAN) fires next frame)", NAN, fallback],
	]
	for case: Array in cases:
		_check_f(
			"delay: %s" % case[0],
			SpacetimeDBClient._resolve_reconnect_delay(case[1], fallback, "probe"),
			case[2],
		)
	# The fallback is the caller's, not a constant baked into the resolver — max_delay
	# has to come back as its own default, not the initial delay's.
	_check_f(
		"delay: the caller's fallback is what is used",
		SpacetimeDBClient._resolve_reconnect_delay(
			NAN,
			SpacetimeDBClient.DEFAULT_RECONNECT_MAX_DELAY,
			"probe",
		),
		SpacetimeDBClient.DEFAULT_RECONNECT_MAX_DELAY,
	)


func _test_multiplier_resolution() -> void:
	var fallback: float = SpacetimeDBClient.DEFAULT_BACKOFF_MULTIPLIER
	var maximum: float = SpacetimeDBClient.MAX_BACKOFF_MULTIPLIER
	var cases: Array = [
		["an escalating multiplier is passed through", 3.0, 3.0],
		["1.0 is escalating enough (a flat retry interval)", 1.0, 1.0],
		["the maximum itself is usable", maximum, maximum],
		["above the maximum clamps down", maximum * 10.0, maximum],
		["a shrinking multiplier falls back", 0.5, fallback],
		["zero falls back (every later attempt would be immediate)", 0.0, fallback],
		["a negative multiplier falls back (the sign alternates)", -2.0, fallback],
		["NaN falls back", NAN, fallback],
	]
	for case: Array in cases:
		_check_f(
			"multiplier: %s" % case[0],
			SpacetimeDBClient._resolve_backoff_multiplier(case[1]),
			case[2],
		)


func _test_jitter_resolution() -> void:
	var cases: Array = [
		["a documented fraction is passed through", 0.5, 0.5],
		["0.0 (no jitter) is passed through", 0.0, 0.0],
		["1.0 (full jitter) is passed through", 1.0, 1.0],
		["above 1.0 clamps to full jitter", 2.0, 1.0],
		["a negative fraction clamps to none (it would ADD delay)", -1.0, 0.0],
		["NaN clamps to none", NAN, 0.0],
	]
	for case: Array in cases:
		_check_f(
			"jitter: %s" % case[0],
			SpacetimeDBClient._resolve_jitter_fraction(case[1]),
			case[2],
		)


func _test_attempts_resolution() -> void:
	_check_i(
		"attempts: a positive budget is passed through",
		SpacetimeDBClient._resolve_max_reconnect_attempts(10),
		10,
	)
	_check_i(
		"attempts: zero is passed through (documented as infinite)",
		SpacetimeDBClient._resolve_max_reconnect_attempts(0),
		0,
	)
	_check_i(
		"attempts: a negative budget falls back rather than reading as infinite",
		SpacetimeDBClient._resolve_max_reconnect_attempts(-1),
		SpacetimeDBClient.DEFAULT_MAX_RECONNECT_ATTEMPTS,
	)


## The property that matters, over every hostile combination: every computed backoff is a
## real delay. Asserted per attempt rather than as an average of the sequence — full jitter
## is documented and legal, so a mean-based check passes on a cycle whose individual waits
## are all sub-frame, which is the storm this test exists for. Checked as an invariant
## rather than per case because the failure being guarded is a value reaching
## SceneTree.create_timer, and every way it can be degenerate (sub-frame, infinite, NaN) is
## unusable regardless of which knob produced it.
func _test_backoff_invariants() -> void:
	var min_delay: float = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	var bad_finite: int = 0
	var bad_range: int = 0
	var bad_floor: int = 0
	for knobs: Dictionary in _hostile_knob_sets():
		var client: SpacetimeDBClient = _resolved_client(_options_from(knobs))
		for attempt: int in range(1, SEQUENCE_LEN + 1):
			var backoff: float = client._calculate_backoff(attempt)
			if not is_finite(backoff):
				bad_finite += 1
			elif backoff < 0.0 or backoff > client._reconnect_max_delay:
				bad_range += 1
			elif backoff < min_delay:
				bad_floor += 1
		client.free()
	_check_i("invariant: every resolved backoff is finite", bad_finite, 0)
	_check_i("invariant: every resolved backoff is within [0, the resolved cap]", bad_range, 0)
	_check_i("invariant: no single resolved backoff lands under the floor", bad_floor, 0)


## The defect itself, on the UNRESOLVED values, so the test proves there was one rather
## than only that the resolvers work. Stated as named facts about specific knob values
## instead of a count over the table: a count pins how many rows happen to be broken in
## which way, which is incidental, and two of these are the shapes a count would hide.
func _test_raw_values_were_degenerate() -> void:
	var min_delay: float = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	var zero_rows: Array[Dictionary] = [
		{ &"reconnect_initial_delay": 0.0 },
		{ &"reconnect_initial_delay": -1.0 },
		{ &"reconnect_max_delay": 0.0 },
		{ &"reconnect_max_delay": -5.0 },
	]
	for knobs: Dictionary in zero_rows:
		var opts: SpacetimeDBConnectionOptions = _options_from(knobs)
		var worst: float = 0.0
		for attempt: int in range(1, SEQUENCE_LEN + 1):
			worst = maxf(worst, _raw_backoff(opts, attempt))
		_check_b("raw %s: every attempt was an immediate retry" % str(knobs), worst == 0.0, true)

	# A zero multiplier keeps the first attempt and zeroes every one after it, which is the
	# same storm one attempt later.
	var flat: SpacetimeDBConnectionOptions = _options_from({ &"reconnect_backoff_multiplier": 0.0 })
	_check_b(
		"raw multiplier 0.0: every attempt after the first was immediate",
		_raw_backoff(flat, 2) == 0.0 and _raw_backoff(flat, SEQUENCE_LEN) == 0.0,
		true,
	)

	# NaN propagates through the formula, and create_timer(NAN) times out on the next frame.
	var nan_opts: SpacetimeDBConnectionOptions = _options_from(
		{ &"reconnect_jitter_fraction": NAN }
	)
	_check_b(
		"raw jitter NaN: the backoff was NaN, which fires on the next frame",
		is_nan(_raw_backoff(nan_opts, 1)),
		true,
	)

	# The opposite failure: a negative fraction is ADDED, so the wait runs past the cap the
	# knob beside it sets.
	var negative_jitter: SpacetimeDBConnectionOptions = _options_from(
		{ &"reconnect_jitter_fraction": -1.0 }
	)
	var over_cap: bool = false
	for attempt: int in range(1, SEQUENCE_LEN + 1):
		if _raw_backoff(negative_jitter, attempt) > negative_jitter.reconnect_max_delay:
			over_cap = true
	_check_b("raw jitter -1.0: the backoff overshot reconnect_max_delay", over_cap, true)

	# And the composition the single-knob rows all miss: every value legal, every wait
	# under a frame.
	var composed: SpacetimeDBConnectionOptions = _options_from(_hostile_knob_sets().back())
	var shortest: float = INF
	for attempt: int in range(1, SEQUENCE_LEN + 1):
		shortest = minf(shortest, _raw_backoff(composed, attempt))
	_check_b(
		"raw legal-worst composition: a wait landed under the floor anyway",
		shortest < min_delay,
		true,
	)


## The pre-fix formula, verbatim, so what the raw column claims is what the client computed.
func _raw_backoff(opts: SpacetimeDBConnectionOptions, attempt: int) -> float:
	var base_delay: float = opts.reconnect_initial_delay * pow(
		opts.reconnect_backoff_multiplier,
		attempt - 1,
	)
	base_delay = minf(base_delay, opts.reconnect_max_delay)
	return maxf(0.0, base_delay - randf() * (base_delay * opts.reconnect_jitter_fraction))


## The wiring, not the resolvers: connect_db has to be what applies them. A test of the
## pure statics alone passes with the call sites deleted.
func _test_connect_db_applies_resolution() -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.token = FAKE_TOKEN
	opts.threading = false
	opts.one_time_token = false
	opts.save_token = false
	opts.connect_timeout_seconds = 0.25
	opts.reconnect_initial_delay = 0.0
	opts.reconnect_max_delay = -5.0
	opts.reconnect_backoff_multiplier = 0.0
	opts.reconnect_jitter_fraction = 2.0
	opts.max_reconnect_attempts = -1

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	# Poisoned first: the members start life AT the defaults these assertions expect, so
	# without this every "resolved and refused" check passes just as well on a client that
	# never resolved anything at all.
	_poison_pacing(client)
	client.connect_db(CLOSED_PORT_URL, "probe", opts)
	await process_frame

	_check_f(
		"connect_db resolves reconnect_initial_delay",
		client._reconnect_initial_delay,
		SpacetimeDBClient.DEFAULT_RECONNECT_INITIAL_DELAY,
	)
	_check_f(
		"connect_db resolves reconnect_max_delay",
		client._reconnect_max_delay,
		SpacetimeDBClient.DEFAULT_RECONNECT_MAX_DELAY,
	)
	_check_f(
		"connect_db resolves reconnect_backoff_multiplier",
		client._reconnect_backoff_multiplier,
		SpacetimeDBClient.DEFAULT_BACKOFF_MULTIPLIER,
	)
	_check_f(
		"connect_db resolves reconnect_jitter_fraction",
		client._reconnect_jitter_fraction,
		1.0,
	)
	_check_i(
		"connect_db resolves max_reconnect_attempts",
		client._max_reconnect_attempts,
		SpacetimeDBClient.DEFAULT_MAX_RECONNECT_ATTEMPTS,
	)
	_check_b(
		"the first backoff after connect_db is a real wait",
		client._calculate_backoff(1) >= SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS,
		true,
	)

	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame


## A cap below the delay it caps is the caller's stated ceiling, not a contradiction to
## square up: the two knobs are different quantities, and the floor on the computed backoff
## is what keeps even a tiny cap a real wait. So it is honoured, and the result is still
## paced.
func _test_a_low_cap_is_honoured() -> void:
	var client: SpacetimeDBClient = _resolved_client(
		_options_from({ &"reconnect_initial_delay": 10.0, &"reconnect_max_delay": 1.0 })
	)
	_check_f("a cap under the initial delay is kept", client._reconnect_max_delay, 1.0)
	var worst: float = 0.0
	var shortest: float = INF
	for attempt: int in range(1, SEQUENCE_LEN + 1):
		var backoff: float = client._calculate_backoff(attempt)
		worst = maxf(worst, backoff)
		shortest = minf(shortest, backoff)
	_check_b("and it bounds every attempt", worst <= 1.0, true)
	_check_b(
		"while the floor keeps the cycle paced",
		shortest >= SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS,
		true,
	)
	client.free()


## The cap is load-bearing on its own: an escalating cycle has to stop escalating at it.
## Without this, an SDK that consults reconnect_max_delay only for implausibly large caps
## passes every other assertion here.
func _test_the_cap_bounds_an_escalating_cycle() -> void:
	var client: SpacetimeDBClient = _resolved_client(
		_options_from(
			{
				&"reconnect_initial_delay": 1.0,
				&"reconnect_max_delay": 3.0,
				&"reconnect_backoff_multiplier": 2.0,
				&"reconnect_jitter_fraction": 0.0,
			}
		)
	)
	_check_f("the cycle saturates at the cap, not past it", client._calculate_backoff(10), 3.0)
	client.free()


## The other entry point. A client with `auto_connect` set is connected from _ready on
## whatever was assigned to `connection_options`, never through connect_db — so resolving
## in connect_db alone leaves that path honouring nothing the caller wrote (measured before
## this case existed: options asking for a 7-second initial delay ran on the 1-second
## default, silently).
func _test_initialize_and_connect_applies_resolution() -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.token = FAKE_TOKEN
	opts.threading = false
	opts.one_time_token = false
	opts.save_token = false
	opts.connect_timeout_seconds = 0.25
	opts.reconnect_initial_delay = 7.0 # legal, and not the default
	opts.reconnect_max_delay = 0.0 # refused
	opts.max_reconnect_attempts = -1 # refused

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	_poison_pacing(client)
	client.connection_options = opts
	client.base_url = CLOSED_PORT_URL
	client.database_name = "probe"
	root.add_child(client)
	client.initialize_and_connect()
	await process_frame

	_check_f(
		"initialize_and_connect honours a legal reconnect_initial_delay",
		client._reconnect_initial_delay,
		7.0,
	)
	_check_f(
		"initialize_and_connect refuses an unusable reconnect_max_delay",
		client._reconnect_max_delay,
		SpacetimeDBClient.DEFAULT_RECONNECT_MAX_DELAY,
	)
	_check_i(
		"initialize_and_connect refuses a negative attempt budget",
		client._max_reconnect_attempts,
		SpacetimeDBClient.DEFAULT_MAX_RECONNECT_ATTEMPTS,
	)

	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame


## Assignment order must not decide whether the caller's pacing is honoured. Some knobs on
## this object are read LIVE every time the cycle consults them (auto_reconnect,
## reconnect_on_app_resume) — so resolving at connect time only meant a client added to the
## tree first and configured second had its reconnect cycle turned ON with the pacing left
## on the defaults. That ordering is the ordinary auto_connect shape, and it is the one the
## resolution has to survive.
func _test_options_assigned_after_ready_are_resolved() -> void:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client) # _ready runs here, before there are any options
	await process_frame

	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.reconnect_initial_delay = 7.0 # legal, and not the default
	opts.max_reconnect_attempts = -1 # refused
	opts.reconnect_jitter_fraction = 2.0 # clamped
	_poison_pacing(client)
	client.connection_options = opts

	_check_f(
		"options set after _ready still carry a legal delay through",
		client._reconnect_initial_delay,
		7.0,
	)
	_check_i(
		"options set after _ready still have a refused budget refused",
		client._max_reconnect_attempts,
		SpacetimeDBClient.DEFAULT_MAX_RECONNECT_ATTEMPTS,
	)
	_check_f(
		"options set after _ready still have an out-of-range jitter clamped",
		client._reconnect_jitter_fraction,
		1.0,
	)

	# And clearing the options keeps the last resolution rather than faulting or reverting.
	# Null means "no options object", not "these options say default" — every other reader
	# of connection_options treats null as the cycle being off, so there is nothing for the
	# pacing to describe.
	client.connection_options = null
	_check_f(
		"clearing the options keeps the last resolved pacing",
		client._reconnect_initial_delay,
		7.0,
	)

	client.queue_free()
	await process_frame


## Mutating a field on an options object the client already holds. The natural idiom —
## assign the options, then set one knob — and the one a snapshot taken at assignment
## silently drops: two knobs on that object (auto_reconnect, reconnect_on_app_resume) are
## read live every time the cycle consults them, so a stale snapshot honours the fields
## still read live while running the caller's delays on the defaults. Asserted through the
## cycle rather than the members, because the members are exactly what a stale snapshot
## gets right at assignment time and wrong later.
func _test_a_knob_mutated_after_assignment_is_honoured() -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.token = FAKE_TOKEN
	opts.threading = false
	opts.one_time_token = false
	opts.save_token = false
	opts.connect_timeout_seconds = 0.25
	opts.auto_reconnect = true

	_attempts = 0
	_failed = 0
	_terminal_disconnects = 0
	_last_reported_max_attempts = -99
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	client.reconnecting.connect(_on_reconnecting)
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.disconnected.connect(_on_disconnected)
	client.connection_options = opts

	# Set AFTER the options object was handed over, which is what has to be honoured.
	opts.max_reconnect_attempts = 2
	opts.reconnect_initial_delay = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	opts.reconnect_max_delay = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	opts.reconnect_backoff_multiplier = 1.0
	opts.reconnect_jitter_fraction = 0.0

	client.connect_db(CLOSED_PORT_URL, "probe", opts)
	var started_ms: int = Time.get_ticks_msec()
	var frames: int = 0
	while _failed == 0 and Time.get_ticks_msec() - started_ms < BUDGET_WINDOW_MS:
		if frames >= MAX_CYCLE_FRAMES:
			break
		frames += 1
		await process_frame

	_check_i("a budget set after assignment bounds the cycle", _attempts, 2)
	_check_i("and the cycle ends on it", _failed, 1)
	_check_i(
		"a delay set after assignment is the one resolved",
		int(client._reconnect_initial_delay * 1000.0),
		int(SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS * 1000.0),
	)

	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame


## The same idiom isolated from the setter: mutate a knob on an options object the client
## already holds, WITHOUT re-assigning it, and start a cycle. Only the per-cycle resolution
## can see that value — the live end-to-end case above hands the object to connect_db,
## which re-assigns it, so the setter alone satisfies it.
func _test_a_cycle_re_resolves_what_it_runs_on() -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	client.connection_options = opts # resolves the defaults
	client.reconnecting.connect(_on_reconnecting)
	_attempts = 0
	_last_reported_max_attempts = -99

	opts.max_reconnect_attempts = 3 # never re-assigned, so only the cycle can see it
	opts.reconnect_initial_delay = 4.0
	client._start_reconnection()

	_check_i(
		"the budget the cycle runs on came from the mutated object",
		client._max_reconnect_attempts,
		3,
	)
	_check_f("and so did the delay", client._reconnect_initial_delay, 4.0)
	_check_i("the cycle reported the mutated budget", _last_reported_max_attempts, 3)

	client._cancel_reconnection()
	client.queue_free()
	await process_frame


## End to end: the cycle driven against a closed port with the worst combination stays
## paced. Pre-fix this made one attempt per frame with an unbounded budget.
func _test_cycle_is_paced() -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.token = FAKE_TOKEN
	opts.threading = false
	opts.one_time_token = false
	opts.save_token = false
	opts.connect_timeout_seconds = 0.25
	opts.auto_reconnect = true
	opts.reconnect_initial_delay = 0.0
	opts.max_reconnect_attempts = 0 # documented infinite: nothing else bounds the cycle
	_attempts = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	client.reconnecting.connect(_on_reconnecting)
	client.connect_db(CLOSED_PORT_URL, "probe", opts)
	# Wall clock, not a frame count: the backoff is a SceneTreeTimer on the wall clock, and
	# a headless run does not spend 1/60 s on a frame — a frame-bounded wait measured zero
	# attempts and would have passed for having never started the cycle. The frame ceiling
	# is the bounded-loop backstop (NASA rule 2), not the wait.
	var started_ms: int = Time.get_ticks_msec()
	var frames: int = 0
	while Time.get_ticks_msec() - started_ms < CYCLE_WINDOW_MS and frames < MAX_CYCLE_FRAMES:
		frames += 1
		await process_frame

	# The resolved cycle starts at ~1 s and doubles, so this window holds two or three
	# attempts. The pre-fix cycle managed one every ~2 frames — measured 50 in 120 frames,
	# and with max_reconnect_attempts = 0 it never stopped.
	_check_b(
		"the cycle actually ran (got %d attempts in %d ms)" % [_attempts, CYCLE_WINDOW_MS],
		_attempts >= 1,
		true,
	)
	_check_b(
		"a zero initial delay no longer retries every frame (got %d attempts)" % _attempts,
		_attempts <= MAX_ATTEMPTS_IN_WINDOW,
		true,
	)
	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame


func _on_reconnecting(_attempt: int, max_attempts: int) -> void:
	_attempts += 1
	_last_reported_max_attempts = max_attempts


func _on_reconnect_failed() -> void:
	_failed += 1


func _on_disconnected() -> void:
	_terminal_disconnects += 1


## The bound, not the pacing: a negative attempt budget read as infinite, so the cycle it
## would have stopped never stopped. Asserted through the signals a game sees, because the
## resolved MEMBER being right proves nothing about the loop reading it — reverting
## `_schedule_next_reconnect_attempt` to the raw option left every other assertion passing.
func _test_attempt_budget_bounds_the_cycle() -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.token = FAKE_TOKEN
	opts.threading = false
	opts.one_time_token = false
	opts.save_token = false
	opts.connect_timeout_seconds = 0.25
	opts.auto_reconnect = true
	opts.max_reconnect_attempts = -1 # silently infinite before the fix
	# The floor, so the whole budget is spent inside the window rather than the test
	# waiting out an escalating backoff.
	opts.reconnect_initial_delay = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	opts.reconnect_max_delay = SpacetimeDBClient.MIN_RECONNECT_DELAY_SECONDS
	opts.reconnect_backoff_multiplier = 1.0
	opts.reconnect_jitter_fraction = 0.0

	_attempts = 0
	_failed = 0
	_terminal_disconnects = 0
	_last_reported_max_attempts = -99
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	client.reconnecting.connect(_on_reconnecting)
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.disconnected.connect(_on_disconnected)
	client.connect_db(CLOSED_PORT_URL, "probe", opts)

	var started_ms: int = Time.get_ticks_msec()
	var frames: int = 0
	while _failed == 0 and Time.get_ticks_msec() - started_ms < BUDGET_WINDOW_MS:
		if frames >= MAX_CYCLE_FRAMES:
			break
		frames += 1
		await process_frame

	_check_i(
		"a negative attempt budget gives up after the default number of attempts",
		_attempts,
		SpacetimeDBClient.DEFAULT_MAX_RECONNECT_ATTEMPTS,
	)
	_check_i(
		"the budget reported to game code is the resolved one",
		_last_reported_max_attempts,
		SpacetimeDBClient.DEFAULT_MAX_RECONNECT_ATTEMPTS,
	)
	_check_i("the exhausted cycle reports reconnect_failed exactly once", _failed, 1)
	_check_i("the exhausted cycle reports disconnected exactly once", _terminal_disconnects, 1)

	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame


## The floor's rationale is that instant retry does not come through _calculate_backoff:
## the stall path — a socket dropped by a local frame-loop freeze, not a network fault —
## sets its backoff to zero directly. Route it through the floored expression and fast
## reconnect quietly becomes a floor-length wait, which nothing else here would notice.
func _test_the_stall_path_still_bypasses_the_floor() -> void:
	var client: SpacetimeDBClient = _resolved_client(SpacetimeDBConnectionOptions.new())
	root.add_child(client)
	client._reconnect_immediate = true
	client._reconnect_state = client._ReconnectState.RECONNECTING
	client.reconnecting.connect(_on_reconnecting)
	_attempts = 0
	_last_reported_max_attempts = -99
	client._schedule_next_reconnect_attempt()
	_check_i("a stall-induced attempt is still scheduled", _attempts, 1)
	_check_b(
		"and it waits no time at all",
		client._reconnect_timer != null and client._reconnect_timer.time_left == 0.0,
		true,
	)
	_check_b("the immediate flag is one-shot", not client._reconnect_immediate, true)
	client.queue_free()


func _run() -> void:
	_test_delay_resolution()
	_test_multiplier_resolution()
	_test_jitter_resolution()
	_test_attempts_resolution()
	_test_backoff_invariants()
	_test_raw_values_were_degenerate()
	await _test_connect_db_applies_resolution()
	_test_a_low_cap_is_honoured()
	_test_the_cap_bounds_an_escalating_cycle()
	await _test_initialize_and_connect_applies_resolution()
	await _test_options_assigned_after_ready_are_resolved()
	await _test_cycle_is_paced()
	_test_the_stall_path_still_bypasses_the_floor()
	await _test_attempt_budget_bounds_the_cycle()
	await _test_a_knob_mutated_after_assignment_is_honoured()
	await _test_a_cycle_re_resolves_what_it_runs_on()

	print("")
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("FAILED %d of %d" % [_fails, _total])
	quit(_fails)

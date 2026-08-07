# Probe: what a degenerate reconnect knob in SpacetimeDBConnectionOptions computes, before
# and after resolution. The socket knobs are resolved and clamped
# (SpacetimeDBConnection.resolve_buffer_size / resolve_interval_seconds); the RECONNECT
# knobs went straight into SpacetimeDBClient._calculate_backoff, which is the residue the
# socket-limit pass named and did not measure.
#
# The RAW column is what the pre-fix client computed — the backoff formula fed the option
# values directly. The RESOLVED column is what it computes now. Every 0.0000 in the raw
# column is a reconnect attempt on the next frame; paired with the documented
# `max_reconnect_attempts = 0` that is an unbounded connection storm, measured end to end
# in _probe_reconnect_storm.gd.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_reconnect_knobs.gd
extends SceneTree

const ATTEMPTS: int = 6


func _initialize() -> void:
	_run.call_deferred()


## The pre-fix formula, verbatim, so the raw column is what the client really computed.
func _raw_backoff(o: SpacetimeDBConnectionOptions, attempt: int) -> float:
	var base_delay: float = o.reconnect_initial_delay * pow(
		o.reconnect_backoff_multiplier,
		attempt - 1,
	)
	base_delay = minf(base_delay, o.reconnect_max_delay)
	var jitter_offset: float = randf() * (base_delay * o.reconnect_jitter_fraction)
	return maxf(0.0, base_delay - jitter_offset)


## Assigns the options to a real client, which resolves them in the setter — rather than
## re-applying the resolvers here, which would print numbers the client does not compute
## the moment the resolution grows a step (it already has: the cap and the floor).
func _resolved_backoffs(o: SpacetimeDBConnectionOptions) -> String:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.connection_options = o
	var out: PackedStringArray = []
	for attempt: int in range(1, ATTEMPTS + 1):
		out.append("%6.2f" % client._calculate_backoff(attempt))
	client.free()
	return " ".join(out)


func _raw_backoffs(o: SpacetimeDBConnectionOptions) -> String:
	var out: PackedStringArray = []
	for attempt: int in range(1, ATTEMPTS + 1):
		out.append("%6.2f" % _raw_backoff(o, attempt))
	return " ".join(out)


func _case(label: String, mutate: Callable) -> void:
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	mutate.call(opts)
	print("%-34s raw: %s" % [label, _raw_backoffs(opts)])
	print("%-34s res: %s" % ["", _resolved_backoffs(opts)])


func _run() -> void:
	print("=== backoff, attempts 1..%d (defaults: initial 1.0, x2, cap 30, jitter 0.5)" % ATTEMPTS)
	_case(
		"baseline (defaults)",
		func(_o: SpacetimeDBConnectionOptions) -> void:
			pass,
	)
	_case(
		"jitter_fraction = 2.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_jitter_fraction = 2.0,
	)
	_case(
		"jitter_fraction = -1.0 (overshoots cap)",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_jitter_fraction = -1.0,
	)
	_case(
		"jitter_fraction = NAN",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_jitter_fraction = NAN,
	)
	_case(
		"initial_delay = 0.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_initial_delay = 0.0,
	)
	_case(
		"initial_delay = -1.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_initial_delay = -1.0,
	)
	_case(
		"backoff_multiplier = 0.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_backoff_multiplier = 0.0,
	)
	_case(
		"backoff_multiplier = -2.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_backoff_multiplier = -2.0,
	)
	_case(
		"backoff_multiplier = 0.5",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_backoff_multiplier = 0.5,
	)
	_case(
		"max_delay = 0.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_max_delay = 0.0,
	)
	_case(
		"max_delay = -5.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_max_delay = -5.0,
	)
	_case(
		"max_delay = NAN",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_max_delay = NAN,
	)
	_case(
		"initial+max delay INF",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_initial_delay = INF
			o.reconnect_max_delay = INF,
	)

	print("")
	print("=== SceneTreeTimer for the degenerate waits the raw column produces")
	var t_inf: SceneTreeTimer = create_timer(INF, true, false, true)
	var t_nan: SceneTreeTimer = create_timer(NAN, true, false, true)
	var t_neg: SceneTreeTimer = create_timer(-5.0, true, false, true)
	print("create_timer(INF).time_left  = %s" % t_inf.time_left)
	print("create_timer(NAN).time_left  = %s" % t_nan.time_left)
	print("create_timer(-5.0).time_left = %s" % t_neg.time_left)
	var fired: Dictionary = { "inf": false, "nan": false, "neg": false }
	t_inf.timeout.connect(
		func() -> void:
			fired["inf"] = true,
	)
	t_nan.timeout.connect(
		func() -> void:
			fired["nan"] = true,
	)
	t_neg.timeout.connect(
		func() -> void:
			fired["neg"] = true,
	)
	for _i: int in 10:
		await process_frame
	print("after 10 frames fired = %s  (INF never times out: a cycle with no next attempt)" % fired)

	print("")
	print("=== max_reconnect_attempts, resolved")
	for v: int in [10, 0, -1, -100]:
		print("  %4d -> %d" % [v, SpacetimeDBClient._resolve_max_reconnect_attempts(v)])

	quit(0)

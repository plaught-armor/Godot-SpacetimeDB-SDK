# Probe: what a degenerate reconnect knob costs once the cycle is actually running.
# Companion to _probe_reconnect_knobs.gd, which measures the computed backoff alone.
#
# THIS IS NOW A POST-FIX CONFIRMATION. Every row below is paced, and that is the point —
# what it showed before the knobs were resolved was:
#
#   baseline (defaults, max_attempts 10)          attempts=  2 in 120 frames
#   initial_delay = 0.0, max_attempts = 0         attempts= 50 in 120 frames
#   backoff_multiplier = 0.0, max_attempts = -1   attempts=  9 in 120 frames
#   max_delay = 0.0, max_attempts = 0             attempts= 49 in 120 frames
#   jitter_fraction = NAN, max_attempts = 0       attempts= 50 in 120 frames
#   initial+max delay INF, jitter 0.0             attempts= 10 in 120 frames
#
# i.e. one connection opened every ~2 frames, and with the documented
# `max_reconnect_attempts = 0` it never ended. The INF row is the one that reads oddly:
# an infinite delay CANNOT wedge the cycle, because `INF * 0.0` and `INF - INF` are both
# NaN, and `create_timer(NAN)` fires on the next frame — so the wedge shape needs a large
# FINITE delay, which is why the resolution clamps rather than only refusing.
#
# Re-run it after any change to the pacing; a row climbing back toward the numbers above is
# the regression.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_reconnect_storm.gd
extends SceneTree

const RUN_FRAMES: int = 120

var _attempts: int = 0
var _failed: int = 0
var _disconnected: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _reset_counts() -> void:
	_attempts = 0
	_failed = 0
	_disconnected = 0


## Drives a real client at a closed port with [param mutate] applied to its options,
## and reports how many reconnect attempts it made in [constant RUN_FRAMES] frames.
func _drive(label: String, mutate: Callable) -> void:
	_reset_counts()
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.auto_reconnect = true
	opts.one_time_token = false
	opts.save_token = false
	opts.token = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
	opts.threading = false
	opts.connect_timeout_seconds = 0.25
	mutate.call(opts)

	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	client.reconnecting.connect(
		func(_a: int, _m: int) -> void:
			_attempts += 1,
	)
	client.reconnect_failed.connect(
		func() -> void:
			_failed += 1,
	)
	client.disconnected.connect(
		func() -> void:
			_disconnected += 1,
	)

	# Port 1 on loopback refuses immediately, so every attempt fails as fast as the
	# transport can report it — the backoff is then the only thing pacing the cycle.
	client.connect_db("http://127.0.0.1:1", "probe", opts)
	for _i: int in RUN_FRAMES:
		await process_frame

	print(
		(
			"%-46s attempts=%4d in %d frames  reconnect_failed=%d disconnected=%d"
			% [label, _attempts, RUN_FRAMES, _failed, _disconnected]
		)
	)
	client.disconnect_db()
	await process_frame
	client.queue_free()
	await process_frame


func _run() -> void:
	print("=== reconnect cycle driven against a closed port, %d frames" % RUN_FRAMES)
	await _drive(
		"baseline (defaults, max_attempts 10)",
		func(_o: SpacetimeDBConnectionOptions) -> void:
			pass,
	)
	await _drive(
		"initial_delay = 0.0, max_attempts = 0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_initial_delay = 0.0
			o.max_reconnect_attempts = 0,
	)
	await _drive(
		"backoff_multiplier = 0.0, max_attempts = -1",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_backoff_multiplier = 0.0
			o.max_reconnect_attempts = -1,
	)
	await _drive(
		"max_delay = 0.0, max_attempts = 0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_max_delay = 0.0
			o.max_reconnect_attempts = 0,
	)
	await _drive(
		"jitter_fraction = NAN, max_attempts = 0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_jitter_fraction = NAN
			o.max_reconnect_attempts = 0,
	)
	await _drive(
		"initial+max delay INF, jitter 0.0",
		func(o: SpacetimeDBConnectionOptions) -> void:
			o.reconnect_initial_delay = INF
			o.reconnect_max_delay = INF
			o.reconnect_jitter_fraction = 0.0,
	)

	quit(0)

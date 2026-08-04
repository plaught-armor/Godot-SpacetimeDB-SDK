# Regression test: the SDK's timeouts run on the wall clock, not the game clock.
#
# Every timer here was created with SceneTree.create_timer's default
# ignore_time_scale = false, so all of them stopped dead at Engine.time_scale = 0 — the
# usual Godot pause idiom. Measured on 4.8.dev: over 255 ms of real time and 40 frames
# at scale 0, a default timer did not move while an ignore_time_scale one counted
# 0.759 -> 0.561. The consequences were a paused game never retrying a dropped
# connection (the same stalled-backoff failure reconnect_on_app_resume exists for, from
# a different cause), an `await ...wait_for_response()` suspended for the length of the
# freeze, and every network timeout stretched by 1/time_scale under slow motion.
#
# Frames still run at scale 0, so the waits below resolve promptly once their deadline
# is on the right clock.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_timeouts_wall_clock.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## Long enough to outlast several frames, short enough to keep the test quick.
const TIMEOUT: float = 0.15
## 60 frames is ~1 s of real time headless — well past TIMEOUT.
const FRAMES: int = 60

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# The engine behaviour the fix relies on, asserted rather than assumed: at scale 0 a
	# default timer is frozen and an ignore_time_scale one is not.
	Engine.time_scale = 0.0
	var game_clock: SceneTreeTimer = create_timer(10.0)
	var wall_clock: SceneTreeTimer = create_timer(10.0, true, false, true)
	# Settle first: the frame in flight when the scale changes still carries its own
	# delta, and it lands a frame later, so the baseline has to be taken after that.
	await _wait_frames(3)
	var game_base: float = game_clock.time_left
	var wall_base: float = wall_clock.time_left
	var real_start: int = Time.get_ticks_msec()
	await _wait_frames(FRAMES)
	var real_elapsed: float = (Time.get_ticks_msec() - real_start) / 1000.0
	_check_b(
		"a default timer does not move at time_scale 0",
		is_equal_approx(game_clock.time_left, game_base),
		true,
	)
	# Compared against the real time this loop actually took, rather than a fixed
	# threshold that assumes a per-frame floor a faster headless run could beat.
	_check_b(
		"an ignore_time_scale timer counted the real time that passed",
		is_equal_approx_loose(wall_base - wall_clock.time_left, real_elapsed),
		true,
	)

	# A subscription that never applies must still time out while the game is frozen.
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	root.add_child(client)
	var sub: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
		client,
		1,
		PackedStringArray(["SELECT * FROM x"]),
	)
	# S6 ignored: a lambda captures locals by value and Packed*Array is copy-on-write, so
	# the result has to come back through a reference type for the caller to see it.
	var applied_result: Array[int] = [-1] # gdlint: ignore[S6]
	var applied_waiter: Callable = func() -> void:
		applied_result[0] = await sub.wait_for_applied(TIMEOUT)
	applied_waiter.call()
	await _wait_frames(FRAMES)
	_check_i("wait_for_applied timed out while frozen", applied_result[0], ERR_TIMEOUT)

	# Same for the end-of-subscription wait.
	var end_result: Array[int] = [-1] # gdlint: ignore[S6]
	var end_waiter: Callable = func() -> void:
		end_result[0] = await sub.wait_for_end(TIMEOUT)
	end_waiter.call()
	await _wait_frames(FRAMES)
	_check_i("wait_for_end timed out while frozen", end_result[0], ERR_TIMEOUT)

	# And the response wait every reducer / procedure / one-off await goes through.
	var response_done: Array[bool] = [false]
	var response_waiter: Callable = func() -> void:
		var _r: Variant = await client.wait_for_reducer_response(4242, TIMEOUT)
		response_done[0] = true
	response_waiter.call()
	await _wait_frames(FRAMES)
	_check_b("a reducer response wait timed out while frozen", response_done[0], true)

	Engine.time_scale = 1.0
	client.queue_free()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# Within a frame's worth of slack: the timer stops decaying at the last process step
# before the measurement, so a small lag behind the bracket is expected.
func is_equal_approx_loose(got: float, want: float) -> bool:
	return absf(got - want) < 0.05


func _wait_frames(count: int) -> void:
	for _i: int in count:
		await process_frame


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	_fails += 1

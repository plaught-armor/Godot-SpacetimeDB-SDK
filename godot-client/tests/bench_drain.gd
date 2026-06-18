# Benchmark: NEW adaptive time-budget drain vs OLD fixed 5-messages/frame.
# Two axes:
#   A. Backlog clearance — frames (and wall-time @60fps) to drain a burst. This
#      is the value proposition: old drains a flat 5/frame regardless of how
#      cheap a message is; new drains as many as fit the per-frame time budget.
#   B. Per-message loop overhead — the cost: the new loop calls a predicate +
#      Time.get_ticks_usec() every iteration; the old loop is a bare counted for.
#      Measured against a no-op handle so only loop control is timed.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_drain.gd
#
# Not a pass/fail test — prints comparison tables. Exit code always 0.
extends SceneTree

const OLD_LIMIT: int = 5  # main's _message_limit_in_frame
const FRAME_US: float = 1000000.0 / 60.0  # 16666.7us per frame @60fps

var _sink: int = 0  # written by the no-op handle so the loop isn't optimized out


func _initialize() -> void:
	print("=== Bench A: backlog clearance (frames to drain) ===")
	print("backlog | cost/msg | OLD frames | OLD ms | NEW frames | NEW ms | frame speedup")
	var backlogs: Array[int] = [100, 1000, 10000, 100000]
	var costs_us: Array[int] = [1, 10, 50, 200]
	for b: int in backlogs:
		for c: int in costs_us:
			_bench_clearance(b, c)
	print("")
	print("(NEW budget 4000us default, ceiling 256/frame; auto-tune off for a")
	print(" fixed-budget comparison. cost/msg = simulated _handle_parsed_message cost.)")

	print("")
	print("=== Bench B: per-message loop overhead (no-op handle) ===")
	_bench_overhead()

	print("")
	print("=== Bench C: per-frame auto-tune cost (_compute_tuned_budget) ===")
	_bench_autotune()

	quit(0)


# --- Bench A: deterministic frame count via the REAL stop predicate ---
func _bench_clearance(backlog: int, cost_us: int) -> void:
	var old_frames: int = _frames_old(backlog)
	var new_frames: int = _frames_new(backlog, cost_us, 4000, 256)
	var old_ms: float = old_frames * FRAME_US / 1000.0
	var new_ms: float = new_frames * FRAME_US / 1000.0
	var speedup: float = float(old_frames) / float(new_frames) if new_frames > 0 else 0.0
	print(
		"%7d | %6dus | %10d | %7.1f | %10d | %7.1f | %.1fx"
		% [backlog, cost_us, old_frames, old_ms, new_frames, new_ms, speedup]
	)


# OLD: a flat OLD_LIMIT messages per frame regardless of cost.
func _frames_old(backlog: int) -> int:
	return int(ceil(float(backlog) / float(OLD_LIMIT)))


# NEW: drive the real _should_stop_drain with a simulated constant per-msg cost
# to count how many drain per frame, then how many frames clear the backlog.
func _frames_new(backlog: int, cost_us: int, budget_us: int, ceiling: int) -> int:
	var remaining: int = backlog
	var frames: int = 0
	# Bounded by backlog+1 — each frame drains >=1, so this always terminates.
	while remaining > 0 and frames < backlog + 1:
		var this_frame: int = _drain_one_frame(remaining, cost_us, budget_us, ceiling)
		remaining -= this_frame
		frames += 1
	return frames


func _drain_one_frame(batch_size: int, cost_us: int, budget_us: int, ceiling: int) -> int:
	var processed: int = 0
	var elapsed: int = 0
	for _i: int in batch_size + 1:
		if SpacetimeDBClient._should_stop_drain(processed, batch_size, ceiling, elapsed, budget_us):
			break
		processed += 1
		elapsed += cost_us
	return processed


# --- Bench B: real wall-clock loop overhead, no-op handle ---
func _bench_overhead() -> void:
	var n: int = 2000000
	# Warm up both paths.
	_run_old_loop(10000)
	_run_new_loop(10000, 1000000000)

	var t0: int = Time.get_ticks_usec()
	_run_old_loop(n)
	var old_us: int = Time.get_ticks_usec() - t0

	# Budget huge so the new loop never breaks early — drains all n, paying the
	# per-iter predicate + Time call every message (the overhead under test).
	var t1: int = Time.get_ticks_usec()
	_run_new_loop(n, 1000000000)
	var new_us: int = Time.get_ticks_usec() - t1

	var old_ns: float = old_us * 1000.0 / float(n)
	var new_ns: float = new_us * 1000.0 / float(n)
	print("messages: %d (no-op handle)" % n)
	print("OLD loop: %d us total, %.2f ns/msg" % [old_us, old_ns])
	print("NEW loop: %d us total, %.2f ns/msg" % [new_us, new_ns])
	print("overhead delta: %.2f ns/msg" % (new_ns - old_ns))
	print(
		"context: at 60fps a frame is %.0f us; new overhead per 256-msg frame ~= %.1f us"
		% [FRAME_US, (new_ns - old_ns) * 256.0 / 1000.0]
	)


# OLD inner drain: bare counted for over the per-frame limit (flattened to n).
func _run_old_loop(n: int) -> void:
	for _i: int in n:
		_handle_stub()


# NEW inner drain: the real predicate + per-iter Time call, exactly as the
# shipped loop in _process_results_asynchronously.
func _run_new_loop(n: int, budget_us: int) -> void:
	var start_us: int = Time.get_ticks_usec()
	var processed: int = 0
	while not SpacetimeDBClient._should_stop_drain(
		processed, n, 1000000000, Time.get_ticks_usec() - start_us, budget_us
	):
		_handle_stub()
		processed += 1


func _handle_stub() -> void:
	_sink += 1


# --- Bench C: auto-tune controller cost (runs once per frame in NEW) ---
func _bench_autotune() -> void:
	var n: int = 1000000
	SpacetimeDBClient._compute_tuned_budget(4000, 58.0, 60, 100, 1000, 8000)  # warm
	var t0: int = Time.get_ticks_usec()
	var acc: int = 0
	for i: int in n:
		acc += SpacetimeDBClient._compute_tuned_budget(4000, 58.0, 60, i, 1000, 8000)
	var us: int = Time.get_ticks_usec() - t0
	_sink += acc
	print("_compute_tuned_budget: %d calls, %.2f ns/call (once per frame)" % [n, us * 1000.0 / float(n)])

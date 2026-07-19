extends SceneTree
const N: int = 1000000
const REPS: int = 7
func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for r: int in REPS:
		var s: int = Time.get_ticks_usec()
		fn.call()
		var el: int = Time.get_ticks_usec() - s
		if el < best: best = el
	return best
func _initialize() -> void:
	# Idle-tick drain proxy: the work _process_results_asynchronously does when the
	# queue is empty -> mutex lock/unlock + Array.is_empty + early return.
	var m: Mutex = Mutex.new()
	var q: Array = []
	var idle_us: int = _best(func() -> void:
		for i: int in N:
			m.lock()
			var empty: bool = q.is_empty()
			m.unlock())
	var idle_ns: float = idle_us * 1000.0 / N
	print("idle-tick drain proxy (mutex pair + is_empty): %.1f ns/tick" % idle_ns)
	print("")
	print("fixed drain overhead per SECOND at tick rates (idle, no traffic):")
	for hz: int in [60, 120, 144, 240]:
		var per_sec_us: float = idle_ns * hz / 1000.0
		var pct_of_sec: float = idle_ns * hz / 1e9 * 100.0
		print("  %3d Hz : %6.1f us/sec  (%.5f%% of one core)" % [hz, per_sec_us, pct_of_sec])
	print("")
	# Per-row costs are NOT measured here — they come from bench_apply_profile.gd and
	# are restated so the tick-invariance point lands with numbers attached. They were
	# stale once (the pre-value-equality update figures outlived a change to
	# LocalDatabase._rows_equal); re-run bench_apply_profile and update both these
	# lines and docs/performance.md together whenever the apply path changes.
	print("apply headroom is tick-INVARIANT (rows/sec of pure main-thread apply):")
	print("  insert  ~570 ns/row -> ~1.75M rows/sec   (bench_apply_profile.gd, prim row)")
	print("  update ~2410 ns/row -> ~0.41M rows/sec   (~3830 ns/row nested -> ~0.26M)")
	print("  delete  ~650 ns/row -> ~1.54M rows/sec")
	print("  (AIMD caps the per-tick slice; flood -> latency, spread over ticks)")
	quit()

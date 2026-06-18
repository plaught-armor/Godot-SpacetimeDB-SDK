# Benchmark: full-burst drain, OLD slice-and-reprepend vs NEW cursor.
# Both drain a backlog of B messages at CEIL/frame with a no-op handle. The OLD
# shape re-slices the unprocessed tail every frame (O(remaining) copy/frame →
# O(B^2/CEIL) total); the NEW shape advances a cursor (O(1)/frame). Measures the
# total copy/control wall-time across the whole burst.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_burst.gd
extends SceneTree

const CEIL: int = 256

var _sink: int = 0


func _initialize() -> void:
	print("backlog | OLD slice/frame total | NEW cursor total | speedup")
	for b: int in [5000, 20000, 50000, 100000]:
		_bench(b)
	print("")
	print("(no-op handle, %d msgs/frame; isolates re-queue overhead, not handler work)" % CEIL)
	quit(0)


func _bench(backlog: int) -> void:
	var src: Array[SpacetimeDBServerMessage] = []
	for _i: int in backlog:
		src.append(SpacetimeDBServerMessage.new())

	# OLD: queue + slice(processed) + reprepend each frame.
	var old_queue: Array[SpacetimeDBServerMessage] = src.duplicate()
	var t0: int = Time.get_ticks_usec()
	# Bounded by backlog frames — each frame drains >=1.
	for _frame: int in backlog:
		if old_queue.is_empty():
			break
		var limit: int = mini(old_queue.size(), CEIL)
		for i: int in limit:
			_sink += 1  # no-op handle
		old_queue = old_queue.slice(limit)  # the O(remaining) re-queue copy
	var old_us: int = Time.get_ticks_usec() - t0

	# NEW: held batch + cursor, no slicing.
	var batch: Array[SpacetimeDBServerMessage] = src
	var cursor: int = 0
	t0 = Time.get_ticks_usec()
	for _frame: int in backlog:
		if cursor >= batch.size():
			break
		var n: int = batch.size()
		var processed: int = 0
		while cursor < n and processed < CEIL:
			_sink += 1  # no-op handle
			cursor += 1
			processed += 1
	var new_us: int = Time.get_ticks_usec() - t0

	var speedup: float = float(old_us) / float(new_us) if new_us > 0 else 0.0
	print("%7d | %18d us | %13d us | %.1fx" % [backlog, old_us, new_us, speedup])

# Bench: cost of guarding a listener dispatch with Callable.is_valid().
#
# LocalDatabase dispatches row callbacks as `listener.call(row)` over a snapshot of
# the table's listener array. A listener freed by an earlier callback in the same
# batch leaves a dead Callable in that snapshot, and calling it aborts the whole
# apply. The guard is `if listener.is_valid():` — this measures what it costs on
# the hot path.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_bench_listener_valid.gd
extends SceneTree

const ITERATIONS: int = 1_000_000
const LISTENERS: int = 4
const REPEATS: int = 7


class _Sink:
	extends RefCounted
	var seen: int = 0


	func on_row(_row: Object) -> void:
		seen += 1


func _initialize() -> void:
	var sinks: Array[_Sink] = []
	var listeners: Array = []
	for _i: int in LISTENERS:
		var s: _Sink = _Sink.new()
		sinks.append(s)
		listeners.append(s.on_row)
	var row: Object = RefCounted.new()

	var bare: int = _best(
		func() -> int:
			return _bare(listeners, row),
	)
	var guarded: int = _best(
		func() -> int:
			return _guarded(listeners, row),
	)
	var obj_guard: int = _best(
		func() -> int:
			return _obj_guarded(listeners, row),
	)
	var calls: int = ITERATIONS * LISTENERS
	print("dispatches: %d x %d listeners = %d calls" % [ITERATIONS, LISTENERS, calls])
	print("bare    : %8d usec  (%.1f ns/call)" % [bare, float(bare) * 1000.0 / calls])
	print("guarded : %8d usec  (%.1f ns/call)" % [guarded, float(guarded) * 1000.0 / calls])
	print("obj     : %8d usec  (%.1f ns/call)" % [obj_guard, float(obj_guard) * 1000.0 / calls])
	print("delta is_valid  : %+.1f%%" % ((float(guarded) / float(bare) - 1.0) * 100.0))
	print("delta get_object: %+.1f%%" % ((float(obj_guard) / float(bare) - 1.0) * 100.0))
	quit(0)


func _best(f: Callable) -> int:
	var best: int = 1 << 62
	for _i: int in REPEATS:
		var t: int = f.call()
		if t < best:
			best = t
	return best


func _bare(listeners: Array, row: Object) -> int:
	var start: int = Time.get_ticks_usec()
	for _i: int in ITERATIONS:
		for listener: Callable in listeners:
			listener.call(row)
	return Time.get_ticks_usec() - start


func _guarded(listeners: Array, row: Object) -> int:
	var start: int = Time.get_ticks_usec()
	for _i: int in ITERATIONS:
		for listener: Callable in listeners:
			if listener.is_valid():
				listener.call(row)
	return Time.get_ticks_usec() - start


func _obj_guarded(listeners: Array, row: Object) -> int:
	var start: int = Time.get_ticks_usec()
	for _i: int in ITERATIONS:
		for listener: Callable in listeners:
			if listener.get_object() != null:
				listener.call(row)
	return Time.get_ticks_usec() - start

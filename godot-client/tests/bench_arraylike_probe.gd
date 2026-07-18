# Sizes the guard added to _read_value_from_bsatn_type by the native-arraylike
# return fix. That branch runs `_native_arraylike_regex.search(bsatn_type_str)`
# before the schema-type lookup, so EVERY non-primitive, non-vec_, non-opt_ type
# string now pays a regex search — including nested struct elements inside a
# Vec<T>, which is a per-element cost on a hot decode path.
#
# Measures, per call, on a type string that does NOT match (the common case —
# a nested schema type like "dbvector2"):
#
#   1. RegEx.search            — what the branch costs today
#   2. ends_with("]") guard    — the proposed cheap gate before the regex
#   3. RegEx.search on a MATCHING string ("vector3[f32,f32,f32]") — the real path
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_arraylike_probe.gd
extends SceneTree

const N: int = 1000000
const REPS: int = 7

var _sink: int = 0


func _initialize() -> void:
	var regex: RegEx = RegEx.new()
	regex.compile("^(?<struct>.+)\\[(?<components>.*)\\]$")

	var miss: StringName = &"dbvector2"
	var hit: StringName = &"vector3[f32,f32,f32]"

	var regex_miss_ns: float = _best(func() -> void:
			_run_regex(regex, miss))
	var guard_miss_ns: float = _best(func() -> void:
			_run_guard(miss))
	var regex_hit_ns: float = _best(func() -> void:
			_run_regex(regex, hit))
	var guard_hit_ns: float = _best(func() -> void:
			_run_guard(hit))

	print("--- per call, N=%d, best of %d ---" % [N, REPS])
	print("regex search  (miss, 'dbvector2')            : %6.1f ns" % regex_miss_ns)
	print("ends_with ']' (miss, 'dbvector2')            : %6.1f ns" % guard_miss_ns)
	print("regex search  (hit,  'vector3[f32,f32,f32]') : %6.1f ns" % regex_hit_ns)
	print("ends_with ']' (hit,  'vector3[f32,f32,f32]') : %6.1f ns" % guard_hit_ns)
	print("")
	print(
		"guard saves on miss : %6.1f ns/call (%.2fx)"
		% [
			regex_miss_ns - guard_miss_ns,
			regex_miss_ns / maxf(guard_miss_ns, 0.0001),
		]
	)
	print("")
	print("Frame-budget context (16_666_667 ns @ 60fps):")
	for calls: int in [1000, 10000, 100000]:
		print(
			"  %7d nested-struct decodes/frame: regex %8.0f ns (%.2f%% frame) -> guard %8.0f ns (%.2f%% frame)"
			% [
				calls,
				regex_miss_ns * calls,
				regex_miss_ns * calls / 166666.67,
				guard_miss_ns * calls,
				guard_miss_ns * calls / 166666.67,
			]
		)
	print("sink=%d" % _sink)
	quit()


func _run_regex(regex: RegEx, s: StringName) -> void:
	for i: int in N:
		if regex.search(s) != null:
			_sink += 1


func _run_guard(s: StringName) -> void:
	for i: int in N:
		if s.ends_with("]"):
			_sink += 1


func _best(body: Callable) -> float:
	var best_us: int = 1 << 62
	for r: int in REPS:
		var t0: int = Time.get_ticks_usec()
		body.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best_us:
			best_us = dt
	return float(best_us) * 1000.0 / float(N)

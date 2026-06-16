# Pinpoints the per-field deserialization overhead (71% of row-parse time per
# bench_row_profile). Isolates: Callable.call vs direct call, Dictionary-plan
# access vs typed-record access, and dynamic property set. Tells us which lever
# to pull for a real deserializer speedup (applies to ALL resource parsing).
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/bench_dispatch.gd
extends SceneTree

const SMALL_PATH: String = "res://addons/SpacetimeDB/tests/_test_row_type.gd"
const N: int = 200000 # "rows", each with 2 u32 fields
const REPS: int = 5

var _small: GDScript = load(SMALL_PATH)
var _d: BSATNDeserializer = BSATNDeserializer.new(null, false)
var _sink: int = 0


# Typed plan step (the candidate replacement for the per-field Dictionary).
class PlanStep:
	var reader: Callable
	var prop_name: StringName
	var prop_type: int


func _initialize() -> void:
	var bytes: PackedByteArray = _build(N)

	# Two plan representations for the same 2 u32 fields.
	var dict_plan: Array = [
		{ "reader": _d.read_u32_le, "name": &"a", "type": TYPE_INT },
		{ "reader": _d.read_u32_le, "name": &"b", "type": TYPE_INT },
	]
	var typed_plan: Array[PlanStep] = []
	for entry: Dictionary in dict_plan:
		var s: PlanStep = PlanStep.new()
		s.reader = entry["reader"]
		s.prop_name = entry["name"]
		s.prop_type = entry["type"]
		typed_plan.append(s)

	print("%d rows x 2 u32 fields, best of %d" % [N, REPS])
	print("direct read (2x read_u32, no resource): %6.1f ms" % (_best(_run_direct.bind(bytes)) / 1000.0))
	print("callable.call read (no resource):       %6.1f ms" % (_best(_run_callable.bind(bytes)) / 1000.0))
	print("dict-plan + new + set (≈ current):      %6.1f ms" % (_best(_run_dict.bind(bytes, dict_plan)) / 1000.0))
	print("typed-plan + new + set (candidate):     %6.1f ms" % (_best(_run_typed.bind(bytes, typed_plan)) / 1000.0))
	print("typed-plan + new + .set() method:       %6.1f ms" % (_best(_run_typed_setmethod.bind(bytes, typed_plan)) / 1000.0))
	quit(0)


func _best(thunk: Callable) -> int:
	var best: int = 1 << 62
	for _r: int in REPS:
		var t0: int = Time.get_ticks_usec()
		thunk.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best:
			best = dt
	return best


func _reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var r: StreamPeerBuffer = StreamPeerBuffer.new()
	r.data_array = bytes
	r.seek(0)
	return r


func _run_direct(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	for i: int in N:
		_sink += _d.read_u32_le(spb)
		_sink += _d.read_u32_le(spb)


func _run_callable(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	var rd: Callable = _d.read_u32_le
	for i: int in N:
		_sink += rd.call(spb)
		_sink += rd.call(spb)


func _run_dict(bytes: PackedByteArray, plan: Array) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	for i: int in N:
		var res: Variant = _small.new()
		for instruction: Dictionary in plan:
			var value: Variant = instruction["reader"].call(spb)
			res[instruction["name"]] = value
		_sink += 1


func _run_typed(bytes: PackedByteArray, plan: Array) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	for i: int in N:
		var res: Variant = _small.new()
		for step: PlanStep in plan:
			var value: Variant = step.reader.call(spb)
			res[step.prop_name] = value
		_sink += 1


func _run_typed_setmethod(bytes: PackedByteArray, plan: Array) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	for i: int in N:
		var res: Object = _small.new()
		for step: PlanStep in plan:
			var value: Variant = step.reader.call(spb)
			res.set(step.prop_name, value)
		_sink += 1


func _build(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	for i: int in range(n):
		w.put_u32(i)
		w.put_u32(i)
	return w.data_array

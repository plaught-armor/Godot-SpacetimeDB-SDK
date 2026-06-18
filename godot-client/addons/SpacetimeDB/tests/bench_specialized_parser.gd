# Puts a real number on the codegen-specialized-parser lever (the one unmeasured
# datapoint from project_parse_perf_floor). Parses N BlackholioEntity rows
# (i32 entity_id, BlackholioDbVector2 position {f32 x, f32 y}, i32 mass = 16B) via:
#
#   1. GENERIC  — the shipped cached-plan path (_populate_from_plan). Per field:
#                 Callable.call + StringName property-set; position = recursive
#                 nested-resource plan.
#   2. SPECIAL  — hand-written monomorphic parser calling the same read_*_le
#                 methods. Eliminates Callable indirection, name-keyed sets, and
#                 the nested-resource plan machinery. Keeps per-read bounds checks.
#   3. INLINE   — ceiling: direct spb.get_32()/get_float(), one bounds check/row.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/bench_specialized_parser.gd
extends SceneTree

const N: int = 300000
const REPS: int = 5
const ROW_BYTES: int = 16

var _d: BSATNDeserializer = BSATNDeserializer.new(SpacetimeDBSchema.new("blackholio"), false)
var _flat: GDScript = load("res://addons/SpacetimeDB/tests/_test_row_flat16.gd")
var _sink: int = 0


func _initialize() -> void:
	var bytes: PackedByteArray = _build(N)

	# Validate all three agree on row 0 before timing.
	if not _validate(bytes):
		push_error("bench_specialized_parser: variants disagree — aborting")
		quit(1)
		return

	# Warm.
	_generic(bytes)
	_special(bytes)
	_inline(bytes)

	var gen_us: int = _best(func() -> void: _generic(bytes))
	var flat_us: int = _best(func() -> void: _generic_flat(bytes))
	var spec_us: int = _best(func() -> void: _special(bytes))
	var inl_us: int = _best(func() -> void: _inline(bytes))

	print("rows=%d  row=%dB" % [N, ROW_BYTES])
	print("1. GENERIC nested (cached plan) : %7.2f ms  (1.00x)" % [gen_us / 1000.0])
	print("2. GENERIC flat (no nesting)    : %7.2f ms  (%.2fx)  <- hoistable: nested re-resolve removed" % [flat_us / 1000.0, float(gen_us) / float(flat_us)])
	print("3. SPECIAL (mono, read_*)       : %7.2f ms  (%.2fx)" % [spec_us / 1000.0, float(gen_us) / float(spec_us)])
	print("4. INLINE  (get_* direct)       : %7.2f ms  (%.2fx)" % [inl_us / 1000.0, float(gen_us) / float(inl_us)])
	print("(sink=%d)" % _sink)
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


# 1. Shipped generic path: fetch plan once, populate each row from it.
func _generic(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var script: GDScript = BlackholioEntity
	var plan: Array = _d._get_or_build_plan(script)
	for _i: int in range(N):
		var e: BlackholioEntity = BlackholioEntity.new()
		_d._populate_from_plan(e, spb, plan)
		_sink += e.entity_id


# 1b. Generic cached-plan path on a FLAT 16B row (no nested resource). Same
#     field count/bytes as nested; the only delta is _read_nested_resource's
#     per-row schema get_type + plan-cache hashes are gone. Measures the
#     hoistable headroom (move nested script+plan into the plan step).
func _generic_flat(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var plan: Array = _d._get_or_build_plan(_flat)
	for _i: int in range(N):
		var e: Variant = _flat.new()
		_d._populate_from_plan(e, spb, plan)
		_sink += e.a


# 2. Monomorphic parser: same read_*_le calls, direct typed field assignment,
#    nested vector built inline (no schema lookup, no recursive plan).
func _special(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	for _i: int in range(N):
		var e: BlackholioEntity = BlackholioEntity.new()
		e.entity_id = _d.read_i32_le(spb)
		var v: BlackholioDbVector2 = BlackholioDbVector2.new()
		v.x = _d.read_f32_le(spb)
		v.y = _d.read_f32_le(spb)
		e.position = v
		e.mass = _d.read_i32_le(spb)
		_sink += e.entity_id


# 3. Inline ceiling: one bounds check per fixed-size row, raw StreamPeerBuffer.
func _inline(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	for _i: int in range(N):
		var e: BlackholioEntity = BlackholioEntity.new()
		e.entity_id = spb.get_32()
		var v: BlackholioDbVector2 = BlackholioDbVector2.new()
		v.x = spb.get_float()
		v.y = spb.get_float()
		e.position = v
		e.mass = spb.get_32()
		_sink += e.entity_id


func _validate(bytes: PackedByteArray) -> bool:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var script: GDScript = BlackholioEntity
	var plan: Array = _d._get_or_build_plan(script)
	var g: BlackholioEntity = BlackholioEntity.new()
	_d._populate_from_plan(g, spb, plan)
	if g.entity_id != 0 or g.mass != _mass(0):
		return false
	if not is_equal_approx(g.position.x, _fx(0)) or not is_equal_approx(g.position.y, _fy(0)):
		return false
	return true


func _eid(i: int) -> int:
	return i % 2147483647


func _mass(i: int) -> int:
	return (i * 3 + 7) % 2147483647


func _fx(i: int) -> float:
	return float(i) * 0.5


func _fy(i: int) -> float:
	return float(i) * -0.25


# N rows: i32 entity_id, f32 x, f32 y, i32 mass.
func _build(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	for i: int in range(n):
		w.put_32(_eid(i))
		w.put_float(_fx(i))
		w.put_float(_fy(i))
		w.put_32(_mass(i))
	return w.data_array

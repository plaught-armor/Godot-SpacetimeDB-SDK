# Measures the hot-path-match conversions (PR #25) on a schema that actually hits
# them: 4 native Vector3 fields per row. Each field exercises both converted matches:
#   - _read_native_arraylike (was match prop.type)      — 1x per field
#   - _get_primitive_reader/_writer_from_bsatn_type      — 1x per f32 component (3x/field)
# Run on main (match) and on perf/hot-path-matches (if-elif); the rows/sec delta is
# the conversion's win on a native-vector schema. Read + write both timed.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_native_vector.gd
extends SceneTree

const ROW_PATH: String = "res://tests/_bench_vec_row.gd"
const N: int = 200000
const REPS: int = 7
const ROW_BYTES: int = 48 # 4 Vector3 x 3 f32 x 4 bytes

var _row: GDScript = load(ROW_PATH)
var _sink: float = 0.0


func _initialize() -> void:
	var bytes: PackedByteArray = _build(N)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)

	# Validate read before timing.
	var spb0: StreamPeerBuffer = StreamPeerBuffer.new()
	spb0.data_array = bytes
	var r0: Variant = _row.new()
	d._populate_resource_from_bytes(r0, spb0)
	if d.has_error() or not is_equal_approx(r0.a.x, 0.0) or not is_equal_approx(r0.b.y, 1.0):
		push_error("bench_native_vector: read validation failed — aborting")
		quit(1)
		return

	var read_us: int = _best(func() -> void: _read(d, bytes))
	var write_us: int = _best(func() -> void: _write())

	print("rows=%d  row=%dB  (4x Vector3)" % [N, ROW_BYTES])
	print("READ  : %7.2f ms  %8.0f rows/s" % [read_us / 1000.0, N * 1000000.0 / read_us])
	print("WRITE : %7.2f ms  %8.0f rows/s" % [write_us / 1000.0, N * 1000000.0 / write_us])
	print("(sink=%.1f)" % _sink)
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


func _read(d: BSATNDeserializer, bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	for _i: int in range(N):
		var r: Variant = _row.new()
		d._populate_resource_from_bytes(r, spb)
		_sink += r.a.x


func _write() -> void:
	var rows: Array[Object] = []
	for i: int in range(8): # small set reused; serializer reset per call
		var r: Object = _row.new()
		r.a = Vector3(i, i + 1, i + 2)
		r.b = Vector3(i, i + 1, i + 2)
		r.c = Vector3(i, i + 1, i + 2)
		r.d = Vector3(i, i + 1, i + 2)
		rows.append(r)
	var ser: BSATNSerializer = BSATNSerializer.new(false)
	for _i: int in range(N):
		ser._spb.seek(0)
		ser._serialize_resource_fields(rows[_i & 7])
		_sink += ser._spb.get_position()


func _build(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	for i: int in range(n):
		for _f: int in range(4): # 4 Vector3 fields
			w.put_float(0.0)
			w.put_float(1.0)
			w.put_float(2.0)
	return w.data_array

# Measures the cost of the per-element context-string format on the parse
# success path (bsatn_deserializer.gd:738 — `"%s[%d]" % [context_prop_name, i]`).
#
# That line lives in _read_value_from_bsatn_type, the recursive Vec<T> reader.
# This bench drives it directly: parse N vecs of K ints (K formats each at :738),
# then isolates the exact same count of `"%s[%d]"` formats in a tight loop. The
# ratio = upper bound on what deferring the format (drop the [i] suffix, rebuild
# only at error sites) would save on this path.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/bench_vec_ctx.gd
extends SceneTree

const N: int = 200000 # vec reads
const K: int = 16 # ints per vec
const REPS: int = 5

var _sink: int = 0
var _str_sink: int = 0


func _initialize() -> void:
	var one_vec: PackedByteArray = _build_vec(K)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = one_vec

	# Validate output once before timing.
	spb.seek(0)
	var out: Variant = d._read_value_from_bsatn_type(spb, &"vec_i32", &"grid")
	if typeof(out) != TYPE_ARRAY or (out as Array).size() != K or int(out[2]) != _val(2):
		push_error("bench_vec_ctx: parse output failed validation — aborting")
		quit(1)
		return

	# Warm.
	_parse(d, spb)
	_formats()

	var parse_us: int = _best(func() -> void: _parse(d, spb))
	var fmt_us: int = _best(func() -> void: _formats())
	var pct: float = 100.0 * float(fmt_us) / float(parse_us) if parse_us > 0 else 0.0

	print("vec reads=%d  ints/vec=%d  formats=%d (one :738 per int)" % [N, K, N * K])
	print("full vec parse (current)  : %7.2f ms" % [parse_us / 1000.0])
	print("isolated :738 formats only: %7.2f ms" % [fmt_us / 1000.0])
	print("format share of parse     : %6.2f%%  <- upper bound on deferral savings" % [pct])
	print("(sink=%d str_sink=%d)" % [_sink, _str_sink])
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


func _parse(d: BSATNDeserializer, spb: StreamPeerBuffer) -> void:
	for _i: int in range(N):
		spb.seek(0)
		var out: Variant = d._read_value_from_bsatn_type(spb, &"vec_i32", &"grid")
		_sink += (out as Array).size()


# Exactly the format :738 performs, once per int: K per vec, N vecs.
func _formats() -> void:
	var ctx: StringName = &"grid"
	for _i: int in range(N):
		for k: int in range(K):
			var s: String = "%s[%d]" % [ctx, k]
			_str_sink += s.length()


func _val(k: int) -> int:
	return (k * 7 + 3) % 2147483647


# u32 length K, then K x i32 LE.
func _build_vec(k: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u32(k)
	for i: int in range(k):
		w.put_32(_val(i))
	return w.data_array

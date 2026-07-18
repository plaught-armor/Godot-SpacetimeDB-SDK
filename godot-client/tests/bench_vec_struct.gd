# Drives the ONE path the native-arraylike return fix put a regex on:
# Vec<T> where T is not a primitive. _read_value_from_bsatn_type strips the
# "vec_" prefix and recurses per element, so each element reaches the
# arraylike probe before falling through to the schema/native lookup.
#
# bench_e2e_receive does NOT cover this — its nested struct is decoded through
# the cached plan path (_read_nested_resource), which never enters this function.
#
# Covers the MATCH exit only: "vec_vector3[f32,f32,f32]", which ends in ']', so it
# passes the gate, matches the regex, and decodes via _read_native_arraylike. The
# MISS exit (a nested schema type like "vec_dbvector2", which pays the gate and
# falls through) needs a populated schema to decode against and is measured in
# isolation by tests/bench_arraylike_probe.gd instead — 152 ns regex vs 18 ns gate.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_vec_struct.gd
extends SceneTree

const ELEMENTS: int = 100000
const REPS: int = 7

var _sink: float = 0.0


func _initialize() -> void:
	var vec3_bytes: PackedByteArray = _build_vector3_vec(ELEMENTS)
	var per_element_ns: float = _best(&"vec_vector3[f32,f32,f32]", vec3_bytes)

	print("--- Vec<Vector3>, %d elements, best of %d ---" % [ELEMENTS, REPS])
	print("per element : %6.1f ns" % per_element_ns)
	print("")
	print("Frame-budget context (16_666_667 ns @ 60fps):")
	for count: int in [1000, 10000, 50000]:
		print(
			"  %6d elements/frame: %9.0f ns (%.2f%% of frame)"
			% [count, per_element_ns * count, per_element_ns * count / 166666.67]
		)
	print("sink=%.1f" % _sink)
	quit()


# u32 length prefix, then ELEMENTS * 3 little-endian f32.
func _build_vector3_vec(count: int) -> PackedByteArray:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(count)
	for i: int in count:
		spb.put_float(float(i))
		spb.put_float(float(i) + 0.5)
		spb.put_float(float(i) + 1.5)
	return spb.data_array


func _best(type_str: StringName, bytes: PackedByteArray) -> float:
	var best_us: int = 1 << 62
	for r: int in REPS:
		var deserializer: BSATNDeserializer = BSATNDeserializer.new(null, false)
		var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
		buffer.big_endian = false
		buffer.data_array = bytes
		buffer.seek(0)

		var t0: int = Time.get_ticks_usec()
		var out: Variant = deserializer._read_value_from_bsatn_type(buffer, type_str, &"ret")
		var dt: int = Time.get_ticks_usec() - t0

		if deserializer.has_error():
			push_error("bench_vec_struct: decode failed — %s" % deserializer.get_last_error())
			quit(1)
			return 0.0
		_sink += (out as Array)[0].x
		if dt < best_us:
			best_us = dt
	return float(best_us) * 1000.0 / float(ELEMENTS)

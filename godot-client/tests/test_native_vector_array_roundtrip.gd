# A column holding a list of native array-like values (Vec<Vector3>, Vec<Color>, ...)
# must survive a serialize -> deserialize round trip.
#
# It did not: the writer resolved the element writer with the column's BSATN type,
# but the reader resolved the element reader with an EMPTY one, and a native
# array-like value carries its component layout in exactly that string
# (`vector3[f32,f32,f32]`). Every such column failed to decode with
# "Missing BSATN_TYPES entry", which takes down the whole row, not just the column.
#
# The first check pins the pair codegen emits, so the round trip below is testing
# the shape the SDK actually produces rather than one invented here.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_native_vector_array_roundtrip.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_PATH: String = "res://tests/_test_vector_array_row.gd"

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_codegen_emits_this_shape()
	fails += _test_roundtrip()
	fails += _test_empty_lists_roundtrip()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# `Vec<Vector3>` reaches codegen as nested ["Array"] over base "Vector3", and the
# outer Array is expressed in the GDScript type — so BSATN_TYPES keeps the ELEMENT
# type, with no `vec_` prefix. That asymmetry is what makes the fixture above the
# real emitted shape.
func _test_codegen_emits_this_shape() -> int:
	var f: int = 0
	f += _check_s(
		"gd type for Vec<Vector3>",
		SpacetimeCodegen._gd_type_from_nested(["Array"], "Vector3"),
		"Array[Vector3]",
	)
	f += _check_s(
		"bsatn type for Vec<Vector3>",
		SpacetimeCodegen._build_bsatn_type(["Array"], "vector3[f32,f32,f32]"),
		"vector3[f32,f32,f32]",
	)
	return f


func _test_roundtrip() -> int:
	var script: GDScript = load(ROW_PATH)
	var src: Object = script.new()
	src.points = [Vector3(1.5, -2.0, 3.25), Vector3(0.0, 0.0, 0.0)] as Array[Vector3] # gdlint: ignore[S6]
	src.cells = [Vector2i(-7, 9)] as Array[Vector2i]
	src.tint = [Color(0.25, 0.5, 0.75, 1.0)] as Array[Color] # gdlint: ignore[S6]
	src.spins = [Quaternion(0.0, 0.0, 0.0, 1.0)] as Array[Quaternion]

	var dst: Object = _codec(script, src)
	var f: int = 0
	if dst == null:
		return _check_b("round trip decodes", false, true)
	f += _check_b("round trip decodes", true, true)
	f += _check_i("points size", (dst.points as Array).size(), 2)
	f += _check_b("points[0]", dst.points[0] == Vector3(1.5, -2.0, 3.25), true)
	f += _check_b("points[1]", dst.points[1] == Vector3.ZERO, true)
	f += _check_b("cells[0]", dst.cells[0] == Vector2i(-7, 9), true)
	f += _check_b("tint[0]", dst.tint[0] == Color(0.25, 0.5, 0.75, 1.0), true)
	f += _check_b("spins[0]", dst.spins[0] == Quaternion(0.0, 0.0, 0.0, 1.0), true)
	return f


# An empty list writes a bare length prefix and never reaches the element reader,
# so it passed even while a populated one could not decode — pin both.
func _test_empty_lists_roundtrip() -> int:
	var script: GDScript = load(ROW_PATH)
	var dst: Object = _codec(script, script.new())
	var f: int = 0
	if dst == null:
		return _check_b("empty round trip decodes", false, true)
	f += _check_b("empty round trip decodes", true, true)
	f += _check_i("empty points size", (dst.points as Array).size(), 0)
	return f


# Serializes [param src], reads the bytes back into a fresh instance, and returns it
# — or null (having reported why) if either half failed or the reader stopped short
# of the bytes the writer produced.
func _codec(script: GDScript, src: Object) -> Object:
	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	if not ser._serialize_resource_fields(src) or ser.has_error():
		printerr("serialize failed: %s" % ser.get_last_error())
		return null
	var bytes: PackedByteArray = ser._spb.data_array.slice(0, ser._spb.get_position())

	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	var d: BSATNDeserializer = BSATNDeserializer.new(schema, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.data_array = bytes
	spb.seek(0)
	var dst: Object = script.new()
	if not d._populate_resource_from_bytes(dst, spb) or d.has_error():
		printerr("deserialize failed: %s" % d.get_last_error())
		return null
	if spb.get_position() != bytes.size():
		printerr("short read: wrote %d, consumed %d" % [bytes.size(), spb.get_position()])
		return null
	return dst


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %d, want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got '%s', want '%s'" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
	return 1

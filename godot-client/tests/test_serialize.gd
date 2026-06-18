# Round-trip correctness test for the BSATN serializer's resource-field write
# path (the typed-plan loop). Serializes a resource, deserializes the bytes back,
# and checks field equality + that the byte length matches the schema. The
# serializer had no coverage; this guards the typed-plan change.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_serialize.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_TYPE_PATH: String = "res://tests/_test_row_type.gd"

var _total: int = 0
var _row_script: GDScript = load(ROW_TYPE_PATH)


func _initialize() -> void:
	var fails: int = 0
	fails += _test_roundtrip(123, 456)
	fails += _test_roundtrip(0, 0)
	fails += _test_roundtrip(4294967295, 1) # u32 max
	fails += _test_byte_length()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _serialize(a: int, b: int) -> PackedByteArray:
	var src: Object = _row_script.new()
	src.a = a
	src.b = b
	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	var ok: bool = ser._serialize_resource_fields(src)
	if not ok or ser.has_error():
		return PackedByteArray()
	return ser._spb.data_array.slice(0, ser._spb.get_position())


func _test_roundtrip(a: int, b: int) -> int:
	var bytes: PackedByteArray = _serialize(a, b)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	var dst: Object = _row_script.new()
	var ok: bool = d._populate_resource_from_bytes(dst, spb)
	var f: int = 0
	f += _check_b("roundtrip(%d,%d) ok" % [a, b], ok and not d.has_error(), true)
	f += _check_i("roundtrip(%d,%d) a" % [a, b], dst.a, a)
	f += _check_i("roundtrip(%d,%d) b" % [a, b], dst.b, b)
	return f


# Two u32 fields → exactly 8 bytes.
func _test_byte_length() -> int:
	var bytes: PackedByteArray = _serialize(1, 2)
	return _check_i("2x u32 → 8 bytes", bytes.size(), 8)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

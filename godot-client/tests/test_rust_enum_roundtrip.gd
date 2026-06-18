# Round-trip for a tagged-sum (enum-with-payload) value through the BSATN writer and
# reader — the path used by enum-with-payload table columns. Covers write_rust_enum,
# the write_nested_resource -> write_rust_enum delegation (RustEnum subclasses reach
# the nested-resource writer as generic Objects), and _populate_enum_from_bytes.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_rust_enum_roundtrip.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


class _TestEnum:
	extends RustEnum
	const ENUM_OPTIONS: Array[StringName] = [&"u32", &"u32", &""]


func _initialize() -> void:
	var fails: int = 0
	# Variant 0 (payload u32) via write_rust_enum.
	fails += _roundtrip("direct circle", 0, 7, true)
	# Variant 1 (payload u32) via the write_nested_resource delegation.
	fails += _roundtrip("nested square", 1, 99, false)
	# Variant 2 (no payload).
	fails += _roundtrip("unit nothing", 2, null, true)

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _roundtrip(label: String, tag: int, payload: Variant, via_direct: bool) -> int:
	var val: _TestEnum = _TestEnum.new()
	val.value = tag
	val.data = payload

	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	if via_direct:
		ser.write_rust_enum(val)
	else:
		ser.write_nested_resource(val, &"", { "name": &"x", "class_name": &"_TestEnum" })
	var bytes: PackedByteArray = ser._spb.data_array.slice(0, ser._spb.get_position())

	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	var dst: _TestEnum = _TestEnum.new()
	var ok: bool = d._populate_resource_from_bytes(dst, spb)

	var f: int = 0
	f += _check_b("%s: ok" % label, ok and not d.has_error(), true)
	f += _check_i("%s: tag" % label, dst.value, tag)
	if payload != null:
		f += _check_i("%s: payload" % label, dst.data, payload)
	return f


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

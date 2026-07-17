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


# Variants whose payload is prefix-typed: Option<T> and Vec<T>. These exercise
# write_rust_enum's delegation to _write_value_from_bsatn_type for opt_/vec_
# sub_class strings — the path that regressed when the prefix was stripped before
# delegation (tag/length byte dropped, wire desynced from the reader).
class _PayloadEnum:
	extends RustEnum
	const ENUM_OPTIONS: Array[StringName] = [&"opt_string", &"vec_u32", &"opt_u32", &"vec_opt_u32"]


func _initialize() -> void:
	var fails: int = 0
	# Variant 0 (payload u32) via write_rust_enum.
	fails += _roundtrip("direct circle", 0, 7, true)
	# Variant 1 (payload u32) via the write_nested_resource delegation.
	fails += _roundtrip("nested square", 1, 99, false)
	# Variant 2 (no payload).
	fails += _roundtrip("unit nothing", 2, null, true)

	# Prefix-typed payload variants (Option<T> / Vec<T>) — regression guard.
	fails += _roundtrip_opt_string("opt_string some", Option.some("hi"), false, "hi")
	fails += _roundtrip_opt_string("opt_string none", Option.none(), true, "")
	fails += _roundtrip_vec_u32("vec_u32", [1, 2, 3] as Array)
	fails += _roundtrip_opt_u32("opt_u32 some", Option.some(42), false, 42)
	# Compound prefix Vec<Option<u32>> — codegen emits these; pins the recursive
	# prefix peeling in _write_value_from_bsatn_type / _read_value_from_bsatn_type.
	fails += _roundtrip_vec_opt_u32("vec_opt_u32", [Option.some(1), Option.none(), Option.some(3)] as Array)

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


# Serialize a payload-carrying enum via write_rust_enum and read it back. Returns
# the decoded enum (value + data) so the typed checks below can assert the
# reconstructed payload — the opt_/vec_ path that regressed on prefix-stripping.
func _codec(tag: int, payload: Variant) -> _PayloadEnum:
	var val: _PayloadEnum = _PayloadEnum.new()
	val.value = tag
	val.data = payload

	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	ser.write_rust_enum(val)
	var bytes: PackedByteArray = ser._spb.data_array.slice(0, ser._spb.get_position())

	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	var dst: _PayloadEnum = _PayloadEnum.new()
	var ok: bool = d._populate_resource_from_bytes(dst, spb)
	if not ok or d.has_error():
		printerr("codec error tag=%d: %s" % [tag, d.get_last_error()])
	return dst


func _roundtrip_opt_string(label: String, opt_in: Option, want_none: bool, want_val: String) -> int:
	var dst: _PayloadEnum = _codec(0, opt_in)
	var f: int = 0
	f += _check_b("%s: tag" % label, dst.value == 0, true)
	f += _check_b("%s: is Option" % label, dst.data is Option, true)
	if dst.data is Option:
		f += _check_b("%s: none" % label, (dst.data as Option).is_none(), want_none)
		if not want_none:
			f += _check_b("%s: val" % label, (dst.data as Option).unwrap() == want_val, true)
	return f


func _roundtrip_vec_u32(label: String, want: Array) -> int:
	var dst: _PayloadEnum = _codec(1, want)
	var f: int = 0
	f += _check_b("%s: tag" % label, dst.value == 1, true)
	f += _check_b("%s: is Array" % label, dst.data is Array, true)
	if dst.data is Array:
		f += _check_i("%s: size" % label, (dst.data as Array).size(), want.size())
		f += _check_b("%s: elems" % label, (dst.data as Array) == want, true)
	return f


func _roundtrip_opt_u32(label: String, opt_in: Option, want_none: bool, want_val: int) -> int:
	var dst: _PayloadEnum = _codec(2, opt_in)
	var f: int = 0
	f += _check_b("%s: tag" % label, dst.value == 2, true)
	f += _check_b("%s: is Option" % label, dst.data is Option, true)
	if dst.data is Option and not want_none:
		f += _check_i("%s: val" % label, (dst.data as Option).unwrap(), want_val)
	return f


func _roundtrip_vec_opt_u32(label: String, want: Array) -> int:
	var dst: _PayloadEnum = _codec(3, want)
	var f: int = 0
	f += _check_b("%s: tag" % label, dst.value == 3, true)
	f += _check_b("%s: is Array" % label, dst.data is Array, true)
	if dst.data is Array:
		var arr: Array = dst.data
		f += _check_i("%s: size" % label, arr.size(), want.size())
		for i: int in arr.size():
			var got_opt: Variant = arr[i]
			var want_opt: Option = want[i]
			f += _check_b("%s[%d]: is Option" % [label, i], got_opt is Option, true)
			if got_opt is Option:
				f += _check_b("%s[%d]: none" % [label, i], (got_opt as Option).is_none(), want_opt.is_none())
				if not want_opt.is_none():
					f += _check_i("%s[%d]: val" % [label, i], (got_opt as Option).unwrap(), want_opt.unwrap())
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

# Guards native array-like (Vector3, Color, ...) RETURN types on reducers and
# procedures, end to end across both halves of the path:
#
#   1. Codegen must emit the component list on the return's BSATN type
#      ("vector3[f32,f32,f32]", not a bare "vector3"). Fields and params already
#      did; returns did not, so the decoder had no component types to read and
#      every such return failed loud with "Unsupported BSATN type".
#   2. The deserializer must decode that type string back into the right struct.
#      Row fields dispatch on the property's own Variant type, but a return
#      arrives as a bare type string with no property attached.
#
# Builds a minimal synthetic v10 schema (a Vector3 product plus a reducer and a
# procedure returning it), runs the real parser and the real generator, then
# round-trips bytes through the real deserializer.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_arraylike_return.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_reducer_return_carries_components()
	fails += _test_procedure_return_carries_components()
	fails += _test_scalar_return_unchanged()
	fails += _test_deserializer_reads_arraylike_type_string()
	fails += _test_deserializer_reads_wrapped_arraylike()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# A Vector3 product (3 f32 named x/y/z) is what the parser recognises as a
# gd_arraylike type — detection is by name plus matching struct shape.
func _sections(reducers: Array, procedures: Array) -> Array:
	var vector3_type: Dictionary = {
		"Product": {
			"elements": [
				{ "name": { "some": "x" }, "algebraic_type": { "F32": [] } },
				{ "name": { "some": "y" }, "algebraic_type": { "F32": [] } },
				{ "name": { "some": "z" }, "algebraic_type": { "F32": [] } },
			],
		},
	}
	return [
		{ "Typespace": { "types": [vector3_type] } },
		{ "Types": [{ "source_name": { "scope": [], "source_name": "Vector3" }, "ty": 0 }] },
		{ "Reducers": reducers },
		{ "Procedures": procedures },
	]


func _generate_reducers(reducers: Array, procedures: Array) -> String:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _sections(reducers, procedures) },
		"test_mod",
	)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new("res://spacetime_bindings")
	return codegen._generate_reducers_gdscript("test_mod", schema)


func _generate_procedures(procedures: Array) -> String:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _sections([], procedures) },
		"test_mod",
	)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new("res://spacetime_bindings")
	return codegen._generate_procedures_gdscript("test_mod", schema)


func _test_reducer_return_carries_components() -> int:
	var out: String = _generate_reducers(
		[{ "source_name": "get_position", "params": { }, "ok_return_type": { "Ref": 0 } }],
		[],
	)
	return _check_b(
		"reducer return emits vector3[f32,f32,f32]",
		out.contains("&'vector3[f32,f32,f32]'"),
		true,
	)


func _test_procedure_return_carries_components() -> int:
	var out: String = _generate_procedures(
		[{ "source_name": "read_position", "params": { }, "return_type": { "Ref": 0 } }],
	)
	return _check_b(
		"procedure return emits vector3[f32,f32,f32]",
		out.contains("&'vector3[f32,f32,f32]'"),
		true,
	)


# A plain scalar return must not grow a component list.
func _test_scalar_return_unchanged() -> int:
	var out: String = _generate_reducers(
		[{ "source_name": "get_count", "params": { }, "ok_return_type": { "U32": [] } }],
		[],
	)
	var f: int = _check_b("scalar return emits bare u32", out.contains("&'u32'"), true)
	f += _check_b("scalar return has no component list", out.contains("u32["), false)
	return f


# The other half: the type string codegen now emits must decode.
func _test_deserializer_reads_arraylike_type_string() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_float(1.5)
	spb.put_float(-2.25)
	spb.put_float(3.75)

	var deserializer: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var read_buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	read_buffer.big_endian = false
	read_buffer.data_array = spb.data_array
	read_buffer.seek(0)

	var value: Variant = deserializer._read_value_from_bsatn_type(
		read_buffer,
		&"vector3[f32,f32,f32]",
		&"ret",
	)
	var f: int = _check_b("decoded value is a Vector3", value is Vector3, true)
	f += _check_b("decode reported no error", deserializer.has_error(), false)
	f += _check_b(
		"decoded components round-trip",
		value is Vector3 and value.is_equal_approx(Vector3(1.5, -2.25, 3.75)),
		true,
	)
	return f


# Option<Vector3> and Vec<Vector3> returns compose the component suffix with a
# wrapper prefix ("opt_vector3[f32,f32,f32]"). The prefix is stripped by recursion
# before the new branch sees the type, so lock that the two actually compose.
func _test_deserializer_reads_wrapped_arraylike() -> int:
	var some: StreamPeerBuffer = StreamPeerBuffer.new()
	some.big_endian = false
	some.put_u8(0) # Option tag: 0 = Some
	some.put_float(1.0)
	some.put_float(2.0)
	some.put_float(3.0)
	var opt_value: Variant = _decode(&"opt_vector3[f32,f32,f32]", some.data_array)
	var f: int = _check_b("Option<Vector3> decodes to an Option", opt_value is Option, true)
	f += _check_b(
		"Option<Vector3> unwraps to the right vector",
		opt_value is Option and (opt_value as Option).unwrap() == Vector3(1.0, 2.0, 3.0),
		true,
	)

	var vec: StreamPeerBuffer = StreamPeerBuffer.new()
	vec.big_endian = false
	vec.put_u32(2)
	vec.put_float(1.0)
	vec.put_float(2.0)
	vec.put_float(3.0)
	vec.put_float(4.0)
	vec.put_float(5.0)
	vec.put_float(6.0)
	var vec_value: Variant = _decode(&"vec_vector3[f32,f32,f32]", vec.data_array)
	f += _check_b("Vec<Vector3> decodes to an Array", vec_value is Array, true)
	f += _check_b(
		"Vec<Vector3> preserves element order",
		(
			vec_value is Array and (vec_value as Array).size() == 2
			and vec_value[0] == Vector3(1.0, 2.0, 3.0) and vec_value[1] == Vector3(4.0, 5.0, 6.0)
		),
		true,
	)
	return f


func _decode(type_str: StringName, bytes: PackedByteArray) -> Variant:
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.data_array = bytes
	buffer.seek(0)
	var value: Variant = deserializer._read_value_from_bsatn_type(buffer, type_str, &"ret")
	if deserializer.has_error():
		printerr("      decode of '%s' errored: %s" % [type_str, deserializer.get_last_error()])
	return value


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

# A procedure returning Result<T, E> must produce a type the decoder can resolve.
#
# Result<T, E> has no named Typespace entry, so the parser synthesizes one per
# distinct pair ("ResultVector3String") and flushes it into the type list. That
# flush ran BEFORE reducers and procedures were parsed, so a Result first seen in
# a RETURN type registered too late: codegen still emitted the synthesized name as
# the decode type, but no such type existed, and every value-returning procedure
# died at decode with "Unsupported BSATN type".
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_procedure_result_return.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_result_type_is_emitted()
	fails += _test_procedure_return_references_emitted_type()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# One Vector3 product plus a procedure returning Result<Vector3, String>, which is
# the idiomatic Rust signature and the only way a module returns a value at all.
func _sections() -> Array:
	var vector3_type: Dictionary = {
		"Product": {
			"elements": [
				{ "name": { "some": "x" }, "algebraic_type": { "F32": [] } },
				{ "name": { "some": "y" }, "algebraic_type": { "F32": [] } },
				{ "name": { "some": "z" }, "algebraic_type": { "F32": [] } },
			],
		},
	}
	var result_return: Dictionary = {
		"Sum": {
			"variants": [
				{ "name": { "some": "ok" }, "algebraic_type": { "Ref": 0 } },
				{ "name": { "some": "err" }, "algebraic_type": { "String": [] } },
			],
		},
	}
	return [
		{ "Typespace": { "types": [vector3_type] } },
		{ "Types": [{ "source_name": { "scope": [], "source_name": "Vector3" }, "ty": 0 }] },
		{
			"Procedures": [
				{ "source_name": "probe_vector3", "params": { }, "return_type": result_return },
			],
		},
	]


func _parse() -> SpacetimeParsedSchema:
	return SpacetimeSchemaParser.parse_schema({ "sections": _sections() }, "test_mod")


func _test_result_type_is_emitted() -> int:
	var schema: SpacetimeParsedSchema = _parse()
	var found: bool = false
	for t: Dictionary in schema.types:
		if t.get("name", "") == "ResultVector3String":
			found = true
	var f: int = _check_b("synthesized Result type is emitted", found, true)
	f += _check_b(
		"Result type is mapped for codegen",
		schema.meta_type_map.has("ResultVector3String"),
		true,
	)
	return f


# The generated call must name a type the deserializer can actually resolve.
func _test_procedure_return_references_emitted_type() -> int:
	var schema: SpacetimeParsedSchema = _parse()
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new("res://spacetime_bindings")
	var out: String = codegen._generate_procedures_gdscript("test_mod", schema)
	var emitted: String = schema.meta_type_map.get("ResultVector3String", "")
	var f: int = _check_b("procedure emitted", out.contains("func probe_vector3("), true)
	f += _check_b(
		"return type names the emitted class (%s)" % emitted,
		not emitted.is_empty() and out.contains("&'%s'" % emitted),
		true,
	)
	# The bare synthesized name is what the decoder could not resolve.
	f += _check_b(
		"does not emit the unresolvable bare name",
		out.contains("&'ResultVector3String'"),
		false,
	)
	return f


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

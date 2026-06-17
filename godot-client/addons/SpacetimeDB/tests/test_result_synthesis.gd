# Test for the schema parser's synthesis of anonymous inline Result<T, E> sum types.
# An inline `Sum{ok(T), err(E)}` column has no named Typespace entry, so the parser
# synthesizes a named RustEnum-style type per distinct Result<T, E> (so the regular
# enum-with-payload codegen + BSATN path handles it). Guards _is_sum_result detection
# and _synthesize_result_type output.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_result_synthesis.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _variant(name: String, ty: String) -> Dictionary:
	return { "name": { "some": name }, "algebraic_type": { ty: [] } }


func _initialize() -> void:
	var fails: int = 0

	var result_sum: Dictionary = { "variants": [_variant("ok", "I32"), _variant("err", "String")] }
	var option_sum: Dictionary = { "variants": [_variant("some", "I32"), { "name": { "some": "none" }, "algebraic_type": { "Product": { "elements": [] } } }] }
	var named_sum: Dictionary = { "variants": [_variant("circle", "U32"), _variant("square", "U32")] }

	fails += _check_b("is_sum_result(result)", SpacetimeSchemaParser._is_sum_result(result_sum), true)
	fails += _check_b("is_sum_result(option)", SpacetimeSchemaParser._is_sum_result(option_sum), false)
	fails += _check_b("is_sum_result(named enum)", SpacetimeSchemaParser._is_sum_result(named_sum), false)

	SpacetimeSchemaParser._synth_result_types.clear()
	var name: String = SpacetimeSchemaParser._synthesize_result_type(result_sum, [], 0)
	fails += _check_s("synth name", name, "ResultI32String")
	fails += _check_b("synth registered", SpacetimeSchemaParser._synth_result_types.has("ResultI32String"), true)

	var synth: Dictionary = SpacetimeSchemaParser._synth_result_types.get("ResultI32String", { })
	fails += _check_b("synth is_sum_type", synth.get("is_sum_type", false), true)
	var variants: Array = synth.get("enum", [])
	fails += _check_b("synth has 2 variants", variants.size() == 2, true)
	if variants.size() == 2:
		fails += _check_s("ok variant name", variants[0].get("name", ""), "ok")
		fails += _check_s("ok variant type", variants[0].get("type", ""), "I32")
		fails += _check_s("err variant name", variants[1].get("name", ""), "err")
		fails += _check_s("err variant type", variants[1].get("type", ""), "String")

	# Second identical Result dedupes to the same name (one synthesized type).
	var name2: String = SpacetimeSchemaParser._synthesize_result_type(result_sum, [], 0)
	fails += _check_b("dedupe: same name", name2 == name, true)
	fails += _check_b("dedupe: one entry", SpacetimeSchemaParser._synth_result_types.size() == 1, true)
	SpacetimeSchemaParser._synth_result_types.clear()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1

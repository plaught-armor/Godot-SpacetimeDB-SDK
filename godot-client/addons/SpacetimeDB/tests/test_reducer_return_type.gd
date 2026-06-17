# Parser test for reducer ok-return-type extraction (schema v10).
#
# Every v10 reducer carries an `ok_return_type` AlgebraicType. This guards that
# the parser extracts a concrete return type for value-returning reducers and
# leaves it empty for unit returns (so the generated decode() is a no-op there).
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_reducer_return_type.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _sections() -> Array:
	return [
		{ "Typespace": { "types": [] } },
		{ "Types": [] },
		{
			"Reducers": [
				# Value-returning reducer: ok_return_type = U32.
				{
					"source_name": "next_id",
					"params": { "elements": [] },
					"ok_return_type": { "U32": [] },
					"err_return_type": { "String": [] },
				},
				# Unit reducer: ok_return_type = empty Product.
				{
					"source_name": "do_thing",
					"params": { "elements": [] },
					"ok_return_type": { "Product": { "elements": [] } },
					"err_return_type": { "String": [] },
				},
			],
		},
	]


func _find_reducer(schema: SpacetimeParsedSchema, name: String) -> Dictionary:
	for r: Dictionary in schema.reducers:
		if r.get("name", "") == name:
			return r
	return { }


func _run() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _sections() },
		"test_mod",
	)
	var f: int = 0

	var next_id: Dictionary = _find_reducer(schema, "next_id")
	f += _check_b("value reducer parsed", not next_id.is_empty(), true)
	f += _check_s("value reducer return_type", next_id.get("return_type", "<missing>"), "U32")

	var do_thing: Dictionary = _find_reducer(schema, "do_thing")
	f += _check_b("unit reducer parsed", not do_thing.is_empty(), true)
	f += _check_s("unit reducer return_type empty", do_thing.get("return_type", "<missing>"), "")

	return f


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

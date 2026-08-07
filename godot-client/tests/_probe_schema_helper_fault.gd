# Probe: does a fault inside a PARSER HELPER reach the codegen completeness gate?
#
# `SpacetimeParsedSchema.incomplete` is `SpacetimePlugin.error_count > errors_before` —
# it counts push_error calls. A GDScript runtime fault pushes nothing: it unwinds the
# faulting function and hands the caller that function's DEFAULT. So a fault inside a
# helper `parse_schema` calls (not `parse_schema` itself, which the 32nd pass covered)
# leaves the parse looking clean, and the run goes on to write bindings and prune.
#
# Each case below is one node of tests/fixtures/vtypes.json replaced with one value, all
# found by tests/_probe_schema_fuzz.gd as "a helper faulted AND parse_schema still
# returned a SpacetimeParsedSchema".
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_schema_helper_fault.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
const MODULE: String = "vtypes"
const TMP_ROOT: String = "user://schema_helper_fault"


func _initialize() -> void:
	_rm_rf(TMP_ROOT)
	var base: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (base is Dictionary):
		printerr("fixture is not a JSON object")
		quit(1)
		return
	var fixture: Dictionary = base

	var baseline: Array[String] = _generate("baseline", fixture) # gdlint: ignore[S6]
	print("BASELINE files=%d" % baseline.size())

	_case(
		"table product_type_ref is null",
		fixture,
		["sections", 2, "Tables", 0, "product_type_ref"],
		null,
		baseline,
	)
	# The sibling class the reviewer asked about: ExplicitNames maps source_name ->
	# canonical_name, and losing an entry renames every file generated for that table, so
	# the previous run's correctly-named ones would be pruned. Both shapes are covered —
	# a missing canonical_name lands on the empty-name report above, and an entry of a
	# kind this SDK does not know (a newer server adding one) leaves the table on its
	# source_name, which for this fixture is the same string after to_snake_case.
	_case(
		"explicit name entry is an unknown kind",
		fixture,
		["sections", 5, "ExplicitNames", "entries", 1],
		{ "Procedure": { "source_name": "one_i128", "canonical_name": "one_i_128" } },
		baseline,
	)
	_case(
		"explicit canonical_name is missing",
		fixture,
		["sections", 5, "ExplicitNames", "entries", 1, "Table"],
		{ "source_name": "one_i128" },
		baseline,
	)
	_case("ty is a string", fixture, ["sections", 1, "Types", 0, "ty"], "", baseline)
	_case(
		"reducer param Ref is null",
		fixture,
		["sections", 3, "Reducers", 6, "params", "elements", 0, "algebraic_type", "Ref"],
		null,
		baseline,
	)
	_case(
		"nested product elements is null",
		fixture,
		[
			"sections",
			0,
			"Typespace",
			"types",
			5,
			"Product",
			"elements",
			0,
			"algebraic_type",
			"Product",
			"elements",
		],
		null,
		baseline,
	)
	_case(
		"reducer ok_return_type Product is null",
		fixture,
		["sections", 3, "Reducers", 0, "ok_return_type", "Product"],
		null,
		baseline,
	)
	quit(0)


func _case(
	label: String,
	fixture: Dictionary,
	path: Array,
	value: Variant,
	baseline: Array[String], # gdlint: ignore[S6]
) -> void:
	var mutant: Dictionary = fixture.duplicate(true)
	var parent: Variant = mutant
	for i: int in path.size() - 1:
		parent = parent[path[i]]
	parent[path[path.size() - 1]] = value

	var errors_before: int = SpacetimePlugin.error_count
	var parsed: Variant = SpacetimeSchemaParser.parse_schema(mutant, MODULE, { })
	var is_schema: bool = parsed is SpacetimeParsedSchema
	var incomplete: String = "n/a"
	if is_schema:
		incomplete = str((parsed as SpacetimeParsedSchema).incomplete)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(
		"%s/%s" % [TMP_ROOT, label.replace(" ", "_")]
	)
	_reset_dir(codegen._schema_path)
	codegen._plugin_config = _config(JSON.stringify(mutant))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	print(
		(
			"CASE %s | parse_ok=%s incomplete=%s push_errors=%d "
			+ "| gen_incomplete=%s reached_return=%s files=%d/%d | missing=%s"
		)
		% [
			label,
			str(is_schema),
			incomplete,
			SpacetimePlugin.error_count - errors_before,
			str(codegen.generation_incomplete),
			str(codegen.run_reached_return),
			files.size(),
			baseline.size(),
			str(_missing(baseline, files)),
		]
	)


func _missing(baseline: Array[String], files: Array[String]) -> PackedStringArray: # gdlint: ignore[S6]
	var have: Dictionary = { }
	for f: String in files:
		have[f.get_file()] = true
	var out: PackedStringArray = []
	for b: String in baseline:
		if not have.has(b.get_file()):
			out.append(b.get_file())
	return out


func _generate(label: String, schema: Dictionary) -> Array[String]: # gdlint: ignore[S6]
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new("%s/%s" % [TMP_ROOT, label])
	_reset_dir(codegen._schema_path)
	codegen._plugin_config = _config(JSON.stringify(schema))
	return codegen.generate_bindings()


func _config(schema_json: String) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = MODULE
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	module_config.unparsed_module_schema = schema_json
	config.module_configs[MODULE] = module_config
	return config


func _reset_dir(path: String) -> void:
	_rm_rf(path)
	DirAccess.make_dir_recursive_absolute(path)


func _rm_rf(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [path, file_name])
	for sub: String in dir.get_directories():
		_rm_rf("%s/%s" % [path, sub])
	DirAccess.remove_absolute(path)

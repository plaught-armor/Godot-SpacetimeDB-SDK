# Probe: module names the SERVER accepts, through codegen.
#
# parse_database_name (crates/client-api-messages/src/name.rs) accepts [a-z0-9] with
# single interior hyphens — so `quickstart-chat` and `2048` are both legal database
# names. Codegen derives GDScript class names from that string with to_pascal_case.
# This runs a real generation for each shape into user:// and reports the class_name
# lines it emitted plus whether the result parses.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_module_name_shapes.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
# C1: never const a Packed*Array.
static var SHAPES: PackedStringArray = ["blackholio", "quickstart-chat", "2048", "a1b2c3"]


func _initialize() -> void:
	var unparsed: String = FileAccess.get_file_as_string(FIXTURE)
	if unparsed.is_empty():
		printerr("fixture unreadable: %s" % FIXTURE)
		quit(1)
		return
	for shape: String in SHAPES:
		_run_shape(shape, unparsed)
	quit(0)


func _run_shape(module_key: String, unparsed: String) -> void:
	var dir_path: String = "user://probe_names_%s" % module_key.to_snake_case()
	_wipe(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)

	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = module_key
	module_config.alias = module_key
	module_config.unparsed_module_schema = unparsed
	config.module_configs[module_key] = module_config

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(dir_path)
	codegen._plugin_config = config
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	print(
		"\n=== module %s: %d files, incomplete=%s"
		% [module_key, files.size(), codegen.generation_incomplete]
	)
	var bad: int = 0
	for path: String in files:
		if not path.ends_with(".gd"):
			continue
		# Reload cannot judge these: a generated file names its siblings by
		# class_name, and nothing in user:// is in the project's global class list.
		# The decisive question is whether the identifiers codegen emitted are legal.
		var source: String = FileAccess.get_file_as_string(path)
		for ident: String in _emitted_identifiers(source):
			if not ident.is_valid_identifier():
				bad += 1
				print("  BAD identifier %-24s in %s" % [ident, path.get_file()])
	print("  %d illegal identifiers across %d files" % [bad, files.size()])


## Every identifier the generator spelled itself: class names, autoload properties,
## and the class_name of each nested type.
func _emitted_identifiers(source: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for raw: String in source.split("\n"):
		var line: String = raw.strip_edges()
		if line.begins_with("class_name "):
			out.append(line.substr("class_name ".length()).split(" ")[0].strip_edges())
		elif line.begins_with("var ") and line.contains(":"):
			out.append(line.substr(4, line.find(":") - 4).strip_edges())
	return out


func _wipe(dir_path: String) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [dir_path, file_name])
	for sub: String in dir.get_directories():
		_wipe("%s/%s" % [dir_path, sub])
		DirAccess.remove_absolute("%s/%s" % [dir_path, sub])

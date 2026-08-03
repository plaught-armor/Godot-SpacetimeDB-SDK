## Runtime schema registry that maps table and type names to their [GDScript] classes.
##
## Built at initialization from the codegen'd scripts in [code]spacetime_bindings/[/code]
## and SDK core types. [LocalDatabase] and [BSATNDeserializer] use this to
## instantiate the correct row type when deserializing server messages.
class_name SpacetimeDBSchema
extends Resource

## All known types keyed by normalized name (lowercased, underscores removed). The
## strip is what lets a nested column's GDScript class name (`VsumShape`) find the file
## that declares it (`vsum_shape.gd`); it is also lossy, which is why tables do not use
## it — see [member tables].
var types: Dictionary[StringName, GDScript] = { }
## Tables keyed by their exact wire name, lowercased but NOT underscore-stripped.
##
## A table is always looked up by the name the server put on the wire, and that name
## matches the script's `table_names` entry exactly, so the lossy normalization
## [member types] needs buys nothing here and costs correctness: `user_data` and
## `userdata` are both legal SpacetimeDB table names and both normalize to `userdata`,
## so one silently displaced the other and its rows decoded against the wrong row type
## with the wrong primary key.
var tables: Dictionary[StringName, GDScript] = { }
## Raw wire table names consumed once by [method LocalDatabase._init] then cleared.
var raw_table_names: Array[StringName] = []
## Enables verbose debug printing during schema loading.
var debug_mode: bool = false
## Normalized keys already reported as ambiguous. A colliding pair otherwise warns twice
## — once for the declared table name, once for the filename alias — saying the same
## thing about the same two scripts.
var _warned_collisions: Dictionary[StringName, bool] = { }


func _init(
	p_module_name: String,
	p_schema_path: String = "res://spacetime_bindings/schema",
	p_debug_mode: bool = false,
) -> void:
	debug_mode = p_debug_mode

	# Load table row schemas and spacetime types
	_load_types("%s/types" % p_schema_path, p_module_name.to_snake_case())
	# Load core types if they are defined as Resources with scripts
	_load_types(SpacetimePlugin.ADDON_PATH + "/core_types/**")


## Returns the [GDScript] for [param type_name] (normalized), or [code]null[/code] if unknown.
func get_type(type_name: StringName) -> GDScript:
	return types.get(type_name)


## Returns the row [GDScript] for [param table_name_lower] — the wire table name,
## lowercased and nothing else — or [code]null[/code] if no table is registered under it.
##
## Use this, not [method get_type], for anything that starts from a table name: it
## cannot confuse two tables whose names differ only in underscore placement.
##
## Deliberately does NOT fall back to the normalized [member types] lookup on a miss.
## That fallback would hand back whichever colliding script loaded last — the precise
## wrong answer this exact key exists to prevent — and nothing needs it: every generated
## row type declares `table_names` and so is registered here, and the only generated
## scripts that skip it are [RustEnum] payload types, which no wire table name names.
## A miss means the server sent a table this build does not know about; callers report
## that rather than guessing.
func get_table(table_name_lower: StringName) -> GDScript:
	return tables.get(table_name_lower)


func _load_types(raw_path: String, prefix: String = "") -> void:
	var path: String = raw_path
	if path.ends_with("/**"):
		path = path.left(-3)

	# DirAccess.open returns null when the directory is missing OR inaccessible
	# (e.g. briefly locked by a concurrent editor reimport). Guard the handle
	# itself — a static dir_exists_absolute check can pass while open() still
	# returns null, then list_dir_begin() would crash on the null instance.
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		printerr("SpacetimeDBSchema: Schema directory missing or inaccessible: ", path)
		return

	dir.list_dir_begin()
	while true:
		var file_name_raw: String = dir.get_next()
		if file_name_raw.is_empty():
			break

		if dir.current_is_dir():
			var dir_name: String = file_name_raw
			if dir_name != "." and dir_name != ".." and raw_path.ends_with("/**"):
				var dir_path: String = path.path_join(dir_name)
				_load_types(dir_path.path_join("/**"), prefix)
			continue

		var file_name: String = file_name_raw

		# Handle potential remapping on export
		if file_name.ends_with(".remap"):
			file_name = file_name.replace(".remap", "")
			if not file_name.ends_with(".gd"):
				file_name += ".gd"

		if not file_name.ends_with(".gd"):
			continue

		if not prefix.is_empty() and not file_name.begins_with(prefix):
			continue

		var script_path: String = path.path_join(file_name)
		if not ResourceLoader.exists(script_path):
			printerr(
				"SpacetimeDBSchema: Script file not found or inaccessible: ",
				script_path,
				" (Original name: ",
				file_name_raw,
				")",
			)
			continue

		var script: GDScript = ResourceLoader.load(script_path, "GDScript") as GDScript

		if script and script.can_instantiate():
			var instance: Variant = script.new()
			if instance is RefCounted: # Resource extends RefCounted — one check covers both
				var fallback_table_names: Array[String] = [file_name.get_basename().get_file()]

				var constants: Dictionary = script.get_script_constant_map()

				if constants.has('table_names'):
					_add_table_names(constants['table_names'], true, script, script_path)
				_add_table_names(fallback_table_names, false, script, script_path)

	dir.list_dir_end()


func _add_table_names(table_names: Array, is_table: bool, script: GDScript, script_path: String) -> void:
	for table_name in table_names:
		var sn: StringName = StringName(table_name)
		var exact_name: StringName = sn.to_lower()
		var lower_table_name: StringName = StringName(String(exact_name).replace("_", ""))
		# A script declaring table_names is registered twice — once under each declared
		# name, then again under its filename as a fallback alias. Those collide
		# whenever the two agree, so only a different script taking over the key is
		# worth reporting.
		var displaced: GDScript = types.get(lower_table_name)
		if (
			displaced != null and displaced != script
			and not _warned_collisions.has(lower_table_name)
		):
			_warned_collisions[lower_table_name] = true
			# Not gated on debug_mode: the normalized key is lossy, so this is the only
			# notice anyone gets that two type names collapsed onto one entry. Harmless
			# when both are tables — `tables` keeps them apart under their exact names —
			# but a nested column type resolved through `types` has no such fallback.
			push_warning(
				(
					"SpacetimeDBSchema: %s and %s both normalize to '%s'. Table lookups "
					+ "stay correct — those use the exact wire name — but a nested column "
					+ "typed as either one resolves to whichever loaded last."
				)
				% [script_path.get_file(), displaced.resource_path.get_file(), lower_table_name]
			)

		if is_table:
			tables[exact_name] = script
			raw_table_names.append(sn)
		types[lower_table_name] = script

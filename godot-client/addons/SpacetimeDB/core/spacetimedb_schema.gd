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
## `userdata` are both legal table names that normalize to `userdata`, so one would
## displace the other and decode its rows against the wrong row type.
var tables: Dictionary[StringName, GDScript] = { }
## Types keyed by the [code]class_name[/code] they declare, exactly as written.
##
## Every generated row and payload type declares one, every nested column names its type
## by that same spelling (a `BSATN_TYPES` entry reads `&"shape": &"VsumShape"`, and an
## `@export var`'s `class_name` property hint is the same string), and Godot already
## enforces that the spelling is unique project-wide. That makes it a better key than the
## normalized one for anything resolving a nested column: `FooBar` and `Foobar` are two
## different classes that both normalize to `foobar`.
var types_by_class: Dictionary[StringName, GDScript] = { }
## Same scripts keyed by the lowercased class name, for the callers that only have that
## form: the deserialization plan lowercases every `BSATN_TYPES` value so a hand-written
## `"U32"` still finds a primitive reader, which flattens `VsumShape` to `vsumshape` on
## the way through. Case is the only thing lost here — underscores are not stripped — so
## the sole way two classes can share a key is a pair like `FooBar` / `Foobar`, and those
## are recorded in [member _ambiguous_lower] rather than silently overwritten.
var _types_by_class_lower: Dictionary[StringName, GDScript] = { }
## Lowercased class names claimed by more than one class. Looked up through
## [method get_type_by_class] these resolve to [code]null[/code] and report, rather than
## returning whichever script loaded last.
var _ambiguous_lower: Dictionary[StringName, bool] = { }
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
	_load_types(SpacetimeDBPaths.ADDON_PATH + "/core_types/**")


## Returns the [GDScript] for [param type_name] (normalized), or [code]null[/code] if unknown.
func get_type(type_name: StringName) -> GDScript:
	return types.get(type_name)


## Returns the row [GDScript] for [param table_name_lower] — the wire table name,
## lowercased and nothing else — or [code]null[/code] if no table is registered under it.
##
## Use this, not [method get_type], for anything that starts from a table name: it
## cannot confuse two tables whose names differ only in underscore placement.
##
## Deliberately does NOT fall back to the normalized [member types] lookup on a miss:
## that would hand back whichever colliding script loaded last, the exact wrong answer
## this key exists to prevent. Nothing needs it — every generated row type declares
## `table_names` and is registered here, and the only scripts that skip it are [RustEnum]
## payload types, which no wire table name names. A miss means the server sent a table
## this build does not know about.
func get_table(table_name_lower: StringName) -> GDScript:
	return tables.get(table_name_lower)


## Indexes [param script] under the [code]class_name[/code] it declares, in both the
## exact and the lowercased map. The single writer for those two — [method _load_types]
## calls it, and so should anything that injects a script into the registry by hand
## (tests do), because a script present in [member types] but missing here resolves as a
## nested column type only by its exact spelling.
##
## A no-op for a script that declares no [code]class_name[/code].
func register_type_by_class(script: GDScript) -> void:
	var global_name: StringName = script.get_global_name()
	if global_name.is_empty():
		return
	types_by_class[global_name] = script
	var lowered: StringName = StringName(String(global_name).to_lower())
	var claimed: GDScript = _types_by_class_lower.get(lowered)
	if claimed != null and claimed != script:
		_ambiguous_lower[lowered] = true
		return
	_types_by_class_lower[lowered] = script


## Returns the [GDScript] declaring [param class_name_hint], or [code]null[/code].
##
## Accepts either the exact [code]class_name[/code] or its lowercased form, because the
## deserialization plan lowercases the `BSATN_TYPES` value it resolves through. It never
## falls back to the underscore-stripped [member types] key: that is what used to hand
## back whichever of two colliding scripts loaded last.
##
## Two classes differing only in case (`FooBar` / `Foobar`) cannot be told apart from the
## lowercased form alone, so that lookup returns [code]null[/code] and reports once —
## a loud failure rather than a wrong row type. Reaching it needs the exact spelling.
func get_type_by_class(class_name_hint: StringName) -> GDScript:
	var script: GDScript = types_by_class.get(class_name_hint)
	if script != null:
		return script
	var lowered: StringName = StringName(String(class_name_hint).to_lower())
	if _ambiguous_lower.has(lowered):
		push_error(
			(
				"SpacetimeDBSchema: '%s' names more than one class once lowercased. The "
				+ "value reached here without its original casing, so it cannot be "
				+ "resolved; rename one of the two types in your module."
			)
			% class_name_hint
		)
		return null
	return _types_by_class_lower.get(lowered)


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
			var constants: Dictionary = script.get_script_constant_map()
			# The filename prefix cannot separate two modules whose names prefix each other
			# (`game` and `game_extra` both emit files beginning `game_`), and the row type
			# declares which module it came from, so believe the constant. Without this a
			# foreign row type claims this schema's table name and a table both modules
			# define decodes against the wrong row type.
			#
			# Only row types declare `module_name`; a sum-type payload script does not and
			# names no table, so it stays loadable as a nested column type either way —
			# harmless, because codegen prefixes every class_name with the module.
			if _is_foreign_module(constants, prefix):
				if debug_mode:
					print(
						"SpacetimeDBSchema: skipping %s — declares module '%s', not '%s'"
						% [file_name, constants["module_name"], prefix]
					)
				continue

			register_type_by_class(script)
			var instance: Variant = script.new()
			if instance is RefCounted: # Resource extends RefCounted — one check covers both
				if constants.has('table_names'):
					_add_table_names(constants['table_names'], true, script, script_path)
				# Fallback alias: the file's own basename, so a script that declares no
				# table_names is still reachable by name.
				var fallback: Array = [file_name.get_basename().get_file()]
				_add_table_names(fallback, false, script, script_path)

	dir.list_dir_end()


## Whether a generated script belongs to a module other than [param prefix] (a snake_case
## module name; empty when loading the SDK's own core types, which belong to every
## module). A script that declares no [code]module_name[/code] is never foreign — that is
## the sum-type payload shape, which names no table.
## [param constants] is untyped on purpose: [method Script.get_script_constant_map]
## hands back a bare [Dictionary] at runtime, and a typed parameter rejects it outright
## ("does not have the same element type as the expected typed dictionary argument").
static func _is_foreign_module(constants: Dictionary, prefix: String) -> bool:
	if prefix.is_empty() or not constants.has("module_name"):
		return false
	var declared: String = str(constants["module_name"]).to_snake_case()
	return declared != prefix


func _add_table_names(table_names: Array, is_table: bool, script: GDScript, script_path: String) -> void:
	for table_name: Variant in table_names:
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
			# Not gated on debug_mode: this is the only notice anyone gets that two
			# names collapsed onto one entry. Both exact maps cover the generated case —
			# tables by wire name, types by class_name — so what is left is a script that
			# declares no class_name, which only [method get_type_by_class]'s fallback can
			# reach, and there the collision still decides by load order.
			push_warning(
				(
					"SpacetimeDBSchema: %s and %s both normalize to '%s'. Tables and "
					+ "class_name'd types are unaffected; a script declaring no class_name "
					+ "resolves to whichever of the two loaded last."
				)
				% [script_path.get_file(), displaced.resource_path.get_file(), lower_table_name]
			)

		if is_table:
			tables[exact_name] = script
			raw_table_names.append(sn)
		types[lower_table_name] = script

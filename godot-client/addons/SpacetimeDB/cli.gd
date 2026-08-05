## Headless codegen entry point.
##
## Run with:
##   godot --headless --path <project> --import   # once per checkout — see below
##   godot --headless --path <project> --script res://addons/SpacetimeDB/cli.gd
##
## Reads plugin config from disk, fetches schemas, regenerates bindings.
## Exits 0 on success, 1 on failure.
##
## Nothing in this file names a `class_name` — not `SpacetimePlugin`, not
## `SpacetimeDBPluginConfig`. Global class names resolve through
## `.godot/global_script_class_cache.cfg`, which only an import or an editor session
## writes, and which Godot's own project `.gitignore` excludes from the repository. On a
## fresh checkout — the CI case this entry point exists for — that file is absent, every
## `class_name` in the addon is an undeclared identifier, and a script naming one fails to
## PARSE, before any code of its own can run and say why. A `--script` run never writes
## the cache either, so running it again does not help. Loading the plugin script by path
## keeps this file loadable, so the missing cache is reported here with the fix.
extends SceneTree

const PLUGIN_SCRIPT_PATH: String = "res://addons/SpacetimeDB/spacetime.gd"
const CONFIG_SCRIPT_PATH: String = "res://addons/SpacetimeDB/core_types/plugin_config.gd"
## Matches the editor plugin's own HTTPRequest timeout.
const SCHEMA_REQUEST_TIMEOUT_SECONDS: float = 4.0


func _initialize() -> void:
	var plugin_script: GDScript = load(PLUGIN_SCRIPT_PATH) as GDScript
	if not _is_plugin_script_usable(plugin_script):
		printerr(
			(
				"Could not load %s. Godot resolves the addon's class names through "
				+ ".godot/global_script_class_cache.cfg, which a `--script` run never "
				+ "writes and which Godot's .gitignore keeps out of the repository. "
				+ "Import the project once, then run this again:\n"
				+ "  godot --headless --path <project> --import"
			)
			% [PLUGIN_SCRIPT_PATH]
		)
		quit(1)
		return

	var save_path: String = plugin_script.SAVE_PATH
	if not ResourceLoader.exists(save_path, "SpacetimeDBPluginConfig"):
		printerr("Plugin config not found at %s" % [save_path])
		quit(1)
		return

	var config_script: GDScript = load(CONFIG_SCRIPT_PATH) as GDScript
	if config_script == null:
		printerr("Addon install is incomplete — %s did not load." % [CONFIG_SCRIPT_PATH])
		quit(1)
		return

	var plugin_config: Resource = ResourceLoader.load(save_path)
	if not _is_plugin_config(plugin_config, config_script):
		printerr("%s is not a plugin config — re-save it from the SpacetimeDB dock." % [save_path])
		quit(1)
		return

	if not _has_modules_configured(plugin_config):
		printerr("Plugin config has no modules configured")
		quit(1)
		return

	var http_request: HTTPRequest = HTTPRequest.new()
	http_request.timeout = SCHEMA_REQUEST_TIMEOUT_SECONDS
	root.add_child(http_request)
	# Unbounded wait — one frame for the HTTPRequest node to enter the tree.
	# Headless context: process_frame always fires, no deadline needed.
	await process_frame

	var ok: bool = await plugin_script.generate_schema(http_request, plugin_config)
	if not ok:
		printerr("Codegen failed")
		quit(1)
		return

	print("OK!")
	quit(0)


## Whether [param script] parsed, i.e. whether the class names it depends on resolved.
##
## [method @GDScript.load] hands back a GDScript object even when the parse failed — the
## resource exists, it just carries no members — so a null check alone passes and the
## first constant read is what faults. Asks for exactly the two members this file goes on
## to reach, [code]SAVE_PATH[/code] and [code]generate_schema[/code]: a parse failure
## takes both away, and a fault on either would unwind [method _initialize] past every
## [method SceneTree.quit] and leave a headless process spinning with no exit code.
##
## Reflection here is not duck-typed dispatch — the type is known, it is simply not
## nameable in this file (see the class docs), so this stands in for the compile-time
## check a typed call would have had.
static func _is_plugin_script_usable(script: GDScript) -> bool:
	if script == null:
		return false
	var constants: Dictionary = script.get_script_constant_map()
	if not constants.has("SAVE_PATH"):
		return false
	# Presence is not enough: the read below assigns it to a `String`, and a typed
	# assignment that fails is a fault in _initialize's own frame — the shape that
	# skips every quit() after it.
	if typeof(constants["SAVE_PATH"]) != TYPE_STRING:
		return false
	return script.has_method(&"generate_schema")


## Whether [param config] is backed by [param config_script], the plugin-config script.
##
## [method ResourceLoader.exists]'s type hint reads the [code].tres[/code] HEADER, which a
## stale file can still spell correctly while its [code]script =[/code] line points at
## something else entirely — measured: a header claiming
## [code]SpacetimeDBPluginConfig[/code] over a module-config script loaded fine and only
## failed later. Comparing the resource's script against the one loaded by path settles
## the type without naming the class (see the class docs for why the name is unusable
## here), so the mismatch is reported with the file rather than as an argument-type error
## from inside codegen.
##
## Deliberately strict identity: a script that merely EXTENDS the plugin config is refused
## too. Nothing produces one — the dock writes this file — and the base-chain walk that
## would accept it can wait until something does.
static func _is_plugin_config(config: Resource, config_script: GDScript) -> bool:
	if config == null:
		return false
	return config.get_script() == config_script


## Whether [param config] carries at least one module.
##
## Reads the field off an untyped [Resource] rather than a typed
## [code]SpacetimeDBPluginConfig[/code] (see the class docs: naming that type would make
## this file unparseable on a fresh checkout), so the shape is checked rather than
## assumed. A stale [code].tres[/code] whose header still claims the class while its
## script no longer carries the field would otherwise fault on the read — and a fault
## unwinds [method _initialize] past every [method SceneTree.quit] below, leaving the
## headless process spinning with no exit code at all.
static func _has_modules_configured(config: Resource) -> bool:
	if config == null:
		return false
	var module_configs: Variant = config.get(&"module_configs")
	if typeof(module_configs) != TYPE_DICTIONARY:
		return false
	return not (module_configs as Dictionary).is_empty()

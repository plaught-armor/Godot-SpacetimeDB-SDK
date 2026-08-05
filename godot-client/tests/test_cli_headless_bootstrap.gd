# Regression test: the headless codegen entry point survives a fresh checkout.
#
# cli.gd is the documented CI entry point, and CI runs on a clone. Godot resolves
# `class_name` identifiers through .godot/global_script_class_cache.cfg, which only an
# import or an editor session writes and which Godot's project .gitignore excludes — so
# on a clone the addon's class names do not resolve, and a script that names one fails to
# PARSE before any of its own code runs. Measured before the fix: `--script cli.gd`
# printed `Parse Error: Identifier "SpacetimePlugin" not declared in the current scope`
# and exited 1, with nothing naming the remedy, and re-running never helped because a
# `--script` run does not write the cache either.
#
# Two invariants keep that entry point usable, and both are checked here:
#   1. cli.gd names no `class_name` of its own — it loads the plugin script by path, so
#      it stays loadable and can report the missing cache itself.
#   2. every failure it can hit ends in quit(). A fault in _initialize's OWN frame unwinds
#      it past every quit() below, and a headless SceneTree with nothing left to do spins
#      forever: measured on the old file, a stale plugin_config.tres backed by the wrong
#      script faulted on the typed assignment and the process had to be killed (timeout,
#      exit 124) instead of failing the job. (A fault inside an awaited callee is not the
#      same shape — that one returns the callee's default and _initialize carries on.)
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_cli_headless_bootstrap.gd
extends SceneTree

const CLI_PATH: String = "res://addons/SpacetimeDB/cli.gd"
const PLUGIN_SCRIPT_PATH: String = "res://addons/SpacetimeDB/spacetime.gd"
const CONFIG_SCRIPT_PATH: String = "res://addons/SpacetimeDB/core_types/plugin_config.gd"
const ADDON_PATH: String = "res://addons/SpacetimeDB"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_cli_names_no_global_class()
	f += _test_plugin_script_usable()
	f += _test_modules_configured()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## cli.gd must not name any class the addon declares — that is the whole reason it can
## report a missing class cache instead of dying to it.
func _test_cli_names_no_global_class() -> int:
	var f: int = 0
	var declared: PackedStringArray = []
	_collect_declared_class_names(ADDON_PATH, declared)
	# If this fires, the walker below is broken, not the invariant — the addon declares
	# dozens of classes, so any small number is a comfortable floor.
	f += _check("addon declares class names", declared.size() > 10, true)

	var source: String = FileAccess.get_file_as_string(CLI_PATH)
	f += _check("cli.gd source readable", not source.is_empty(), true)
	# Only code counts. A class name inside a comment explains the rule, and inside a
	# string it is data the engine never resolves — `ResourceLoader.exists(path,
	# "SpacetimeDBPluginConfig")` is a type HINT and is exactly how this file checks the
	# config's type without naming the class.
	var code: String = _strip_comments_and_strings(source)

	var word: RegEx = RegEx.new()
	for global_name: String in declared:
		word.compile("\\b%s\\b" % global_name)
		var hit: RegExMatch = word.search(code)
		f += _check("cli.gd does not name %s" % global_name, hit == null, true)
	return f


func _test_plugin_script_usable() -> int:
	var f: int = 0
	var cli: GDScript = load(CLI_PATH) as GDScript
	f += _check("cli.gd loads", cli != null, true)
	if cli == null:
		return f

	f += _check("null script rejected", cli._is_plugin_script_usable(null), false)

	# The real thing, in a project whose cache exists (the suite imports first).
	var plugin_script: GDScript = load(PLUGIN_SCRIPT_PATH) as GDScript
	f += _check("real plugin script accepted", cli._is_plugin_script_usable(plugin_script), true)

	# What a fresh checkout produces: load() hands back a GDScript object whose parse
	# failed, so a null check alone would pass it through to the first constant read.
	# Measured on the real spacetime.gd with the class cache deleted — load() returned
	# non-null, can_instantiate() false, get_script_constant_map().size() 0 (with the
	# cache: 11) — so an empty script is that object's shape, and it stands in here
	# because compiling a genuinely unparseable one prints SCRIPT ERROR, which the runner
	# treats as a failed test.
	var unparsed: GDScript = GDScript.new()
	f += _check("script with no members rejected", cli._is_plugin_script_usable(unparsed), false)

	# A script that parses but is not the plugin script is rejected too — the guard is
	# "did the members I am about to reach survive", not "did something load".
	var other: GDScript = GDScript.new()
	other.source_code = "extends Node\n\nconst UNRELATED: int = 1\n"
	other.reload()
	f += _check("script without SAVE_PATH rejected", cli._is_plugin_script_usable(other), false)

	# Both members are checked: the constant alone would let a call to a missing
	# generate_schema fault, and a fault is the hang.
	var constant_only: GDScript = GDScript.new()
	constant_only.source_code = "extends Node\n\nconst SAVE_PATH: String = \"res://x.tres\"\n"
	constant_only.reload()
	f += _check(
		"script without generate_schema rejected",
		cli._is_plugin_script_usable(constant_only),
		false,
	)

	# A SAVE_PATH of the wrong type is refused too: cli.gd assigns it to a String, and a
	# failed typed assignment faults in _initialize's own frame — the shape that skips
	# every quit() after it.
	var wrong_constant_type: GDScript = GDScript.new()
	wrong_constant_type.source_code = (
		"extends Node\n\nconst SAVE_PATH: int = 7\n\n\nstatic func generate_schema() -> bool:\n"
		+ "\treturn true\n"
	)
	wrong_constant_type.reload()
	f += _check(
		"non-String SAVE_PATH rejected",
		cli._is_plugin_script_usable(wrong_constant_type),
		false,
	)
	return f


## Blanks out comments and double-quoted strings so a name check sees only code.
func _strip_comments_and_strings(source: String) -> String:
	var stripped: RegEx = RegEx.new()
	# Triple-quoted first: the single-quote-pair alternative would otherwise eat its opener.
	# Both quote styles, and `\"` inside a string does not end it.
	stripped.compile(
		"(?m)\"\"\"(?s:.*?)\"\"\"|#[^\\n]*|\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'"
	)
	return stripped.sub(source, "", true)


func _test_modules_configured() -> int:
	var f: int = 0
	var cli: GDScript = load(CLI_PATH) as GDScript
	if cli == null:
		return f

	f += _check("null config rejected", cli._has_modules_configured(null), false)
	var config_script: GDScript = load(CONFIG_SCRIPT_PATH) as GDScript
	f += _check("config script loads", config_script != null, true)
	f += _check(
		"null config not a plugin config",
		cli._is_plugin_config(null, config_script),
		false,
	)

	# The stale-.tres shape: header claims SpacetimeDBPluginConfig, script is something
	# else entirely. Measured: ResourceLoader.exists()'s type hint reads the header and
	# lets it through, and the old typed assignment then faulted — the hang. Both guards
	# refuse it, the script-identity one first.
	var wrong_type: Resource = SpacetimeDBModuleConfig.new()
	f += _check("foreign script rejected", cli._is_plugin_config(wrong_type, config_script), false)
	f += _check(
		"config without module_configs rejected",
		cli._has_modules_configured(wrong_type),
		false,
	)

	# A plain Resource carrying the right-shaped field is still not a plugin config —
	# the shape check alone would hand it to codegen, whose parameter is typed.
	var impostor_script: GDScript = GDScript.new()
	impostor_script.source_code = (
		"extends Resource\n\nvar module_configs: Dictionary = { \"Game\": null }\n"
	)
	impostor_script.reload()
	var impostor: Resource = impostor_script.new()
	f += _check("shape-alike rejected", cli._is_plugin_config(impostor, config_script), false)
	f += _check("shape-alike passes the shape check", cli._has_modules_configured(impostor), true)

	var empty: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	f += _check(
		"real config accepted as plugin config",
		cli._is_plugin_config(empty, config_script),
		true,
	)
	f += _check("empty config rejected", cli._has_modules_configured(empty), false)

	var populated: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module.name = "game"
	module.alias = "Game"
	populated.module_configs["Game"] = module
	f += _check("configured module accepted", cli._has_modules_configured(populated), true)
	return f


## Appends every `class_name X` declared under [param dir_path] to [param out].
func _collect_declared_class_names(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	# Both spellings the addon uses — `class_name X extends Y` on one line, and a
	# `class_name` line of its own after `extends`.
	var decl: RegEx = RegEx.new()
	decl.compile("(?m)^class_name\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for file_name: String in dir.get_files():
		if not file_name.ends_with(".gd"):
			continue
		var source: String = FileAccess.get_file_as_string("%s/%s" % [dir_path, file_name])
		for m: RegExMatch in decl.search_all(source):
			var global_name: String = m.get_string(1)
			if not out.has(global_name):
				out.append(global_name)
	for sub: String in dir.get_directories():
		_collect_declared_class_names("%s/%s" % [dir_path, sub], out)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
	return 1

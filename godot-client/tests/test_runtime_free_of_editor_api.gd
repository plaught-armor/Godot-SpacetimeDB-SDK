# Regression test: nothing an exported game loads may name an editor-only class.
#
# Export templates are built without TOOLS_ENABLED, so `register_editor_types()` never
# runs and EditorPlugin, EditorInterface and the rest of the editor API are absent from
# ClassDB. A runtime script that names one — even only to read a constant off a `@tool`
# script that extends it — fails to PARSE in an exported game, and GDScript propagates
# that: every script that depends on it reports "Failed to compile depended scripts".
#
# Measured before the fix, on a real 4.7 release export template with the Blackholio
# example: `spacetimedb_server_message.gd` and `spacetimedb_schema.gd` both read
# `SpacetimePlugin.ADDON_PATH`, SpacetimePlugin extends EditorPlugin, and the cascade
# took out bsatn_deserializer.gd, spacetimedb_reducer_call.gd, spacetimedb_client.gd,
# the generated module client and finally the autoload — "Failed to load script
# res://spacetime_bindings/schema/spacetime_autoload.gd with error Compilation failed",
# then a segfault. The SDK did not run at all in ANY exported build. Forty-six bug-hunt
# passes missed it because every test, probe and CI job runs the EDITOR binary, where
# the editor API is present and the reference resolves.
#
# The addon path now lives on SpacetimeDBPaths (a plain RefCounted), and this test is
# the gate that keeps the dependency pointing that way: editor code may name runtime
# classes, runtime code may not name editor ones.
#
# It runs in the editor binary deliberately — that is the only place the editor classes
# can be ENUMERATED, which is what makes the check general rather than a denylist of the
# two names that happened to bite.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_runtime_free_of_editor_api.gd
extends SceneTree

## Everything an exported game can load. The addon's editor-only corners — spacetime.gd,
## cli.gd, codegen/ and ui/ — are deliberately absent: they are allowed to name the
## editor API, and one of them is the control below that proves the scanner works.
# Plain `var`, not `const`: a `const` Packed*Array reports its byte size (C1).
var _runtime_roots: PackedStringArray = [
	"res://addons/SpacetimeDB/core",
	"res://addons/SpacetimeDB/core_types",
	"res://addons/SpacetimeDB/nodes",
	"res://addons/SpacetimeDB/util",
	"res://spacetime_bindings",
]
## The plugin script: editor-only itself, and the control for the scanner.
const PLUGIN_SCRIPT_PATH: String = "res://addons/SpacetimeDB/spacetime.gd"
## A scan of this many files or fewer means the walker broke, not that the SDK shrank.
const MIN_RUNTIME_FILES: int = 30

var _total: int = 0
## Editor-only class names: the editor half of ClassDB, plus every `class_name` in the
## project that reaches it through its `extends` chain.
var _forbidden: Dictionary[String, bool] = { }


func _initialize() -> void:
	var f: int = 0
	_build_forbidden()
	f += _test_forbidden_set_is_sane()
	f += _test_scanner_flags_the_plugin_script()
	f += _test_runtime_names_no_editor_class()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## Fills [member _forbidden] with the classes an export template does not have.
##
## Two sources. ClassDB knows which of its own classes belong to the editor API, which
## covers a runtime script reaching for EditorInterface or EditorFileSystem directly.
## The project's global class list carries the second-order case — the one that actually
## bit — where the name is the SDK's own `@tool` script and only its BASE is editor-only.
## Taint propagates through the class list to a fixed point, so a chain of two SDK
## scripts is caught as readily as one.
func _build_forbidden() -> void:
	for class_name_str: String in ClassDB.get_class_list():
		var api: int = ClassDB.class_get_api_type(class_name_str)
		if api == ClassDB.API_EDITOR or api == ClassDB.API_EDITOR_EXTENSION:
			_forbidden[class_name_str] = true

	var globals: Array[Dictionary] = ProjectSettings.get_global_class_list()
	var grew: bool = true
	while grew:
		grew = false
		for entry: Dictionary in globals:
			var declared: String = entry.get("class", "")
			if declared.is_empty() or _forbidden.has(declared):
				continue
			if _forbidden.has(String(entry.get("base", ""))):
				_forbidden[declared] = true
				grew = true


## The set has to contain the engine class the bug turned on and the SDK class that
## inherited the taint, or every check below passes for the wrong reason.
func _test_forbidden_set_is_sane() -> int:
	var f: int = 0
	f += _check("editor API enumerated", _forbidden.size() > 50, true)
	f += _check("EditorPlugin is editor-only", _forbidden.has("EditorPlugin"), true)
	f += _check("EditorInterface is editor-only", _forbidden.has("EditorInterface"), true)
	# The second-order case: a project class whose only editor-ness is its base.
	f += _check("SpacetimePlugin inherits the taint", _forbidden.has("SpacetimePlugin"), true)
	# Runtime classes must NOT be in it, or the scan would flag the whole SDK.
	f += _check("Node is not editor-only", _forbidden.has("Node"), false)
	f += _check("SpacetimeDBPaths is not editor-only", _forbidden.has("SpacetimeDBPaths"), false)
	return f


## Control: the plugin script names its own editor base, so a working scanner flags it.
## Without this, an empty root list or a broken walker would read as a clean SDK.
func _test_scanner_flags_the_plugin_script() -> int:
	var hits: PackedStringArray = _scan_file(PLUGIN_SCRIPT_PATH)
	return _check("scanner flags the editor plugin script", hits.size() > 0, true)


func _test_runtime_names_no_editor_class() -> int:
	var f: int = 0
	var files: PackedStringArray = []
	for root_path: String in _runtime_roots:
		_collect_scripts(root_path, files)
	f += _check("runtime scripts found", files.size() >= MIN_RUNTIME_FILES, true)

	for path: String in files:
		var hits: PackedStringArray = _scan_file(path)
		f += _check("%s names no editor class" % path, hits, PackedStringArray())
	return f


## Returns [code]"line: Name"[/code] for every editor-only class named in real code in
## [param path], empty when there are none.
func _scan_file(path: String) -> PackedStringArray:
	var hits: PackedStringArray = []
	var source: String = FileAccess.get_file_as_string(path)
	if source.is_empty():
		# An unreadable file is a broken walker, not a passing file — say so loudly.
		hits.append("0: <unreadable>")
		return hits

	var lines: PackedStringArray = _strip_comments_and_strings(source).split("\n")
	var identifier: RegEx = RegEx.new()
	identifier.compile("[A-Za-z_][A-Za-z0-9_]*")
	for i: int in lines.size():
		for m: RegExMatch in identifier.search_all(lines[i]):
			var word: String = m.get_string()
			if _forbidden.has(word):
				hits.append("%d: %s" % [i + 1, word])
	return hits


## Blanks out comments and quoted strings so only code is scanned — a class name in a
## doc comment explains the rule and a name in a string is data the parser never
## resolves. Neither form is what breaks an export.
##
## Line numbers survive because nothing this removes spans a newline: `#` runs to the end
## of its line and GDScript's single- and double-quoted strings cannot contain a raw one.
## Triple-quoted strings could, so they are refused outright rather than silently shifting
## every line number after them (the SDK's runtime uses none).
func _strip_comments_and_strings(source: String) -> String:
	if source.contains("\"\"\""):
		# Reported as a hit by the caller's line, not silently tolerated.
		return "\"\"\"triple-quoted string: EditorPlugin"
	var stripped: RegEx = RegEx.new()
	# Both quote styles; a backslash-escaped quote does not end the string.
	stripped.compile("#[^\\n]*|\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'")
	return stripped.sub(source, "", true)


## Appends every [code].gd[/code] under [param dir_path], recursively, to [param out].
func _collect_scripts(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		if file_name.ends_with(".gd"):
			out.append("%s/%s" % [dir_path, file_name])
	for sub: String in dir.get_directories():
		_collect_scripts("%s/%s" % [dir_path, sub], out)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
	return 1

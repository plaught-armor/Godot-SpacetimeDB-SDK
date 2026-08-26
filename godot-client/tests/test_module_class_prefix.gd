# Regression test: a run's generated bindings must not reference anything the run did not
# produce.
#
# Every generated name is built from the module key put through `to_pascal_case`, and that
# transform is NOT idempotent: it splits on case boundaries, so a prefix carrying
# consecutive capitals comes back re-split. `a-b` — a legal SpacetimeDB database name
# (parse_database_name accepts [a-z0-9] with single interior hyphens) — gives `AB`, and
# `AB` gives `Ab`. Codegen applied it once in the schema parser and AGAIN at every
# class-name site, so one run emitted two prefixes: the nested-column type map and the
# `<Prefix>Types` class said `AB…` while every `class_name` said `Ab…`, and the autoload
# declared `var AB: ABModuleClient` while preloading `module_a_b_client.gd` — a class no
# file declared, at a path no file was written to. The run reported success, so the
# pruning pass then deleted the previous, working bindings.
#
# The check is deliberately wider than that one bug: whatever a run spells, it must
# resolve. Every preloaded path is a file the run generated, and every type it names is
# either declared by the run, a class the project registers, or an engine/builtin type.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_module_class_prefix.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
const TMP_ROOT: String = "user://codegen_class_prefix"

## GDScript's own type names — not engine classes, so ClassDB does not know them.
static var BUILTIN_TYPES: PackedStringArray = [
	"Variant",
	"bool",
	"int",
	"float",
	"String",
	"StringName",
	"NodePath",
	"Callable",
	"Signal",
	"Array",
	"Dictionary",
	"void",
	"null",
]

var _total: int = 0
var _known: Dictionary[String, bool] = { }


func _initialize() -> void:
	_collect_known_types()
	var f: int = 0
	_rm_rf(TMP_ROOT)
	# `a-b` and `a-b-c` are the shapes that used to split differently on a second pass;
	# the rest are the ordinary names, which must keep generating exactly as before.
	for key: String in ["a-b", "a-b-c", "vtypes", "quickstart-chat", "x-y-z-9"]:
		f += _test_module(key)

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_module(module_key: String) -> int:
	var tmp: String = "%s/%s" % [TMP_ROOT, module_key.replace("-", "_")]
	_rm_rf(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(module_key)
	var files: PackedStringArray = codegen.generate_bindings()

	var f: int = 0
	f += _check_b("%s: run completed" % module_key, not codegen.generation_incomplete, true)
	f += _check_b("%s: files generated" % module_key, files.size() > 1, true)

	var declared: Dictionary[String, bool] = { }
	for path: String in files:
		for raw: String in FileAccess.get_file_as_string(path).split("\n"):
			var line: String = raw.strip_edges()
			if line.begins_with("class_name "):
				declared[line.substr("class_name ".length()).split(" ")[0].strip_edges()] = true

	f += _check_b(
		"%s: every type it names resolves" % module_key,
		_all_references_resolve(files, declared),
		true,
	)
	f += _check_b(
		"%s: every path it preloads was written" % module_key,
		_all_preloads_exist(files),
		true,
	)
	# The autoload is the file the project boots through, and the one place both spellings
	# have to agree with the per-module output.
	var autoload_path: String = "%s/%s" % [tmp, SpacetimePlugin.AUTOLOAD_FILE_NAME]
	# Spelled out rather than called through SpacetimeSchemaParser.module_class_prefix, so
	# this test still runs against a build that does not have that helper.
	var prefix: String = module_key.to_pascal_case()
	var autoload_source: String = FileAccess.get_file_as_string(autoload_path)
	f += _check_b(
		"%s: the autoload declares the client class the run emitted" % module_key,
		autoload_source.contains("var %s: %sModuleClient" % [prefix, prefix]),
		true,
	)
	f += _check_b(
		"%s: the emitted client class carries that name" % module_key,
		declared.has("%sModuleClient" % prefix),
		true,
	)
	# [RowReceiver] resolves its client as `SpacetimeDB[<the row type's module_name>]`, so
	# that constant has to BE the autoload's property name. It only is if the pascal-case
	# pass is applied exactly once on both sides: the transform is not idempotent (`a-b` →
	# `AB` → `Ab`), so a second pass anywhere — RowReceiver used to do one — misses a client
	# that is sitting right there.
	f += _check_s(
		"%s: the row constant is the autoload's property name" % module_key,
		_row_module_constant(files),
		prefix,
	)
	return f


## The `module_name` constant codegen wrote on the run's row types — the string
## [RowReceiver] looks the client up with.
func _row_module_constant(files: PackedStringArray) -> String:
	for path: String in files:
		if not path.contains("/types/"):
			continue
		for raw: String in FileAccess.get_file_as_string(path).split("\n"):
			var line: String = raw.strip_edges()
			if line.begins_with("const module_name"):
				return line.split("=")[1].strip_edges().trim_prefix('"').trim_suffix('"')
	return ""


## Every type the generated code names resolves to something: a class this run declared, a
## class the project registers (the SDK's own), or an engine/builtin type.
func _all_references_resolve(files: PackedStringArray, declared: Dictionary[String, bool]) -> bool:
	var ok: bool = true
	for path: String in files:
		if not path.ends_with(".gd"):
			continue
		for raw: String in FileAccess.get_file_as_string(path).split("\n"):
			for referenced: String in _referenced_types(raw.strip_edges()):
				# Only the head matters for a qualified name: `ABTypes.Shape` resolves iff
				# `ABTypes` does.
				var head: String = referenced.split(".")[0]
				if head.is_empty() or declared.has(head) or _known.has(head):
					continue
				printerr("      unresolved type '%s' in %s" % [referenced, path.get_file()])
				ok = false
	return ok


## Type names a single line references — `extends X`, a typed `var`, a parameter type, a
## return type, and a direct `X.new()`. Element types inside `Array[...]` /
## `Dictionary[...]` come out too.
##
## Parameters are covered because that is where the generated reducer and procedure
## signatures name a module's types, and nothing else in a run would catch a prefix
## misspelled only there.
func _referenced_types(line: String) -> PackedStringArray:
	var found: PackedStringArray = []
	if line.begins_with("func ") or line.begins_with("static func "):
		found.append_array(_parameter_types(line))
	if line.begins_with("class_name ") and line.contains(" extends "):
		found.append(line.split(" extends ")[1].strip_edges())
	elif line.begins_with("extends "):
		found.append(line.substr("extends ".length()).strip_edges())

	var declaration: String = line
	if declaration.begins_with("@export "):
		declaration = declaration.substr("@export ".length()).strip_edges()
	if declaration.begins_with("var ") or declaration.begins_with("const "):
		var colon: int = declaration.find(":")
		if colon != -1:
			var after: String = declaration.substr(colon + 1)
			var equals: int = after.find("=")
			if equals != -1:
				after = after.left(equals)
			found.append_array(_split_container_type(after.strip_edges()))

	var arrow: int = line.find("->")
	if arrow != -1:
		found.append_array(
			_split_container_type(line.substr(arrow + 2).replace(":", "").strip_edges())
		)

	var new_call: int = line.find(".new(")
	if new_call != -1:
		var head: String = line.left(new_call)
		var start: int = maxi(head.rfind(" "), head.rfind("\t"))
		found.append(head.substr(start + 1).strip_edges())

	var out: PackedStringArray = []
	for name: String in found:
		# `preload('...')` and literals are not type names; neither is an empty match.
		if name.is_empty() or name.contains("(") or name.contains('"') or name.contains("'"):
			continue
		out.append(name)
	return out


## The declared types in a `func` signature's parameter list. Splitting on "," would cut
## `Dictionary[StringName, Foo]` in half, so each parameter is taken from its ":" up to the
## comma that follows at bracket depth zero.
func _parameter_types(line: String) -> PackedStringArray:
	var open: int = line.find("(")
	var close: int = line.rfind(")")
	if open == -1 or close < open:
		return []
	var params: String = line.substr(open + 1, close - open - 1)
	var out: PackedStringArray = []
	var depth: int = 0
	var current: String = ""
	var collecting: bool = false
	for i: int in params.length():
		var ch: String = params[i]
		if ch == "[":
			depth += 1
		elif ch == "]":
			depth -= 1
		if ch == "," and depth == 0:
			if collecting:
				out.append_array(_split_container_type(current.strip_edges()))
			current = ""
			collecting = false
			continue
		if ch == ":" and depth == 0 and not collecting:
			collecting = true
			continue
		if collecting:
			# A default value ends the type; `= Foo.new()` is a call, not an annotation.
			if ch == "=":
				out.append_array(_split_container_type(current.strip_edges()))
				current = ""
				collecting = false
				continue
			current += ch
	if collecting:
		out.append_array(_split_container_type(current.strip_edges()))
	return out


## `Array[Foo]` yields Array and Foo; `Dictionary[StringName, Foo]` yields all three.
func _split_container_type(type_text: String) -> PackedStringArray:
	var open: int = type_text.find("[")
	if open == -1:
		return [type_text] as PackedStringArray
	var out: PackedStringArray = [type_text.left(open).strip_edges()]
	for part: String in type_text.substr(open + 1).replace("]", "").split(","):
		out.append(part.strip_edges())
	return out


## Every path a generated file preloads is a file this run wrote. Catches the half of the
## bug that lived in the file NAME rather than the class name.
func _all_preloads_exist(files: PackedStringArray) -> bool:
	var written: Dictionary[String, bool] = { }
	for path: String in files:
		written[path] = true
	var ok: bool = true
	for path: String in files:
		if not path.ends_with(".gd"):
			continue
		for raw: String in FileAccess.get_file_as_string(path).split("\n"):
			var line: String = raw.strip_edges()
			var start: int = line.find("preload('")
			if start == -1:
				continue
			var rest: String = line.substr(start + "preload('".length())
			var referenced: String = rest.left(rest.find("'"))
			if written.has(referenced):
				continue
			printerr(
				"      preloads '%s', which the run did not write (%s)"
				% [referenced, path.get_file()]
			)
			ok = false
	return ok


## Class names that resolve without this run having declared them: everything the project
## registers globally (the SDK's own classes) plus the engine's and GDScript's own.
func _collect_known_types() -> void:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		_known[str(entry.get("class", ""))] = true
	for engine_class: StringName in ClassDB.get_class_list():
		_known[String(engine_class)] = true
	for builtin: String in BUILTIN_TYPES:
		_known[builtin] = true
	# Engine value types are not in ClassDB (they are Variant types, not Objects).
	for variant_type: int in TYPE_MAX:
		_known[type_string(variant_type)] = true


func _config(module_key: String) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = module_key
	module_config.alias = module_key
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	module_config.unparsed_module_schema = FileAccess.get_file_as_string(FIXTURE)
	config.module_configs[module_key] = module_config
	return config


func _rm_rf(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [path, file_name])
	for sub: String in dir.get_directories():
		_rm_rf("%s/%s" % [path, sub])
	DirAccess.remove_absolute(path)


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
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1

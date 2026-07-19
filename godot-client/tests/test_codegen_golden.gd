# Golden-file test for the codegen text output. Codegen *behavior* is covered by
# roundtrip tests (nested types, reducer returns, btree, result-synthesis), but the
# generated GDScript text itself was unguarded — a refactor of codegen.gd that
# changed output silently passed. This locks the exact emitted source.
#
# For each captured schema fixture it parses the raw v10 JSON, runs the codegen
# generator into a user:// temp dir, and diffs every generated file against the
# committed golden under tests/golden/<module>/.
#
# Determinism: parse_schema is fed an EMPTY project-enum map (the live pipeline
# passes _scan_project_enums(), which depends on whatever globals the project
# defines); both hide_* flags are false so private tables and scheduled reducers
# are emitted (max surface). Goldens are generated the same way.
#
# Update goldens after an intentional codegen change:
#   cd godot-client && STDB_REGEN_GOLDEN=1 <godot> --headless --path . \
#       --script tests/test_codegen_golden.gd
# Then review the git diff before committing.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_codegen_golden.gd
extends SceneTree

# PackedStringArray (S6), not Array[String]. A plain var, not `const`: a const
# Packed*Array reports a byte-count size and reads back wrong (C1 — never const one).
var _fixtures: PackedStringArray = [
	"vtypes", "vsum", "vtypes2", "vbtree", "vreserved", "vprocenum"
]
# Committed test inputs. NOT spacetime_bindings/codegen_debug/ — that dir is
# gitignored (transient codegen dumps), so fixtures there are absent on a clean
# clone. These live with the test and codegen never writes here.
const FIXTURE_DIR: String = "res://tests/fixtures"
const GOLDEN_DIR: String = "res://tests/golden"
const TMP_ROOT: String = "user://golden_gen"

var _total: int = 0
var _fails: int = 0

## The native class each generated script ultimately extends. The goldens are gdignored,
## so they cannot be parsed here — a `class_name` in one does not resolve from another,
## and every file would report phantom "Identifier not found". This table stands in for
## that. An unrecognised base FAILS rather than skipping the check, so a new kind of
## generated file cannot quietly opt out of the gate.
const NATIVE_BASE_OF: Dictionary[String, StringName] = {
	"RustEnum": &"Resource",
	"_ModuleTableType": &"Resource",
	"_ModuleTableUniqueIndex": &"Resource",
	"_ModuleTableBTreeIndex": &"Resource",
	"_ModuleTable": &"RefCounted",
	"SpacetimeDBClient": &"Node",
	"RefCounted": &"RefCounted",
	"Resource": &"Resource",
	"Node": &"Node",
}

## The SDK base's OWN members matter as much as its native ancestor's: `count` and `iter`
## are ordinary column names and ordinary `_ModuleTable` methods, and Godot rejects
## `The member "count" already exists in parent class _ModuleTable`. Checking only the
## native ancestor misses every one of those.
var _sdk_base_scripts: Dictionary[String, Script] = {
	"RustEnum": RustEnum,
	"_ModuleTableType": _ModuleTableType,
	"_ModuleTableUniqueIndex": _ModuleTableUniqueIndex,
	"_ModuleTableBTreeIndex": _ModuleTableBTreeIndex,
	"_ModuleTable": _ModuleTable,
	"SpacetimeDBClient": SpacetimeDBClient,
}

## Members a generated script may declare even though the engine also defines them:
## `_init` is the constructor every generated class writes, and overriding it is correct.
## A plain `var`, never `const` — a const Packed*Array reads back wrong (C1, #88753).
var _collision_exempt: PackedStringArray = ["_init"]
## Native member-name sets, keyed by class. ClassDB rebuilds its lists on every call.
var _native_names_cache: Dictionary[StringName, Dictionary] = { }


func _initialize() -> void:
	var regen: bool = OS.get_environment("STDB_REGEN_GOLDEN") == "1"
	if regen:
		print("REGEN mode — writing goldens, not asserting")

	for module: String in _fixtures:
		_run_module(module, regen)

	if regen:
		print("REGEN done — review `git diff %s` before committing" % GOLDEN_DIR)
		# Not quit(0): the collision gate runs during regen too, and a regen that wrote
		# an unloadable golden must not report success — every later run would compare
		# against that golden and pass.
		quit(_fails)
		return

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _run_module(module: String, regen: bool) -> void:
	var fixture_path: String = "%s/%s.json" % [FIXTURE_DIR, module]
	if not FileAccess.file_exists(fixture_path):
		_fail("%s: fixture missing (%s)" % [module, fixture_path])
		return

	var txt: String = FileAccess.get_file_as_string(fixture_path)
	var json: Variant = JSON.parse_string(txt)
	if not (json is Dictionary):
		_fail("%s: fixture is not a JSON object" % module)
		return

	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(json, module, { })
	if schema.is_empty():
		_fail("%s: parse_schema returned empty" % module)
		return

	var tmp: String = "%s/%s" % [TMP_ROOT, module]
	_reset_dir(tmp)
	DirAccess.make_dir_recursive_absolute("%s/types" % tmp)
	DirAccess.make_dir_recursive_absolute("%s/tables" % tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _build_config(module)
	var paths: Array[String] = codegen._generate_gdscript_from_schema(module, schema)

	if paths.is_empty():
		_fail("%s: generator produced no files" % module)
		return

	var generated_rels: Dictionary[String, bool] = { }
	for p: String in paths:
		if not p.begins_with("%s/" % tmp):
			_fail("%s: generated path outside temp dir: %s" % [module, p])
			continue
		var rel: String = p.substr(tmp.length() + 1) # strip "user://golden_gen/<module>/"
		generated_rels[rel] = true
		var got: String = FileAccess.get_file_as_string(p)
		# Runs in regen mode too — see the quit(_fails) note above.
		_check_native_collisions(module, rel, got)
		var golden_path: String = "%s/%s/%s" % [GOLDEN_DIR, module, rel]
		if regen:
			DirAccess.make_dir_recursive_absolute(golden_path.get_base_dir())
			_write(golden_path, got)
			continue
		_compare(module, rel, golden_path, got)

	# A golden with no matching generated file means codegen dropped it (the loop
	# above only sees generated files, so a dropped file would otherwise PASS).
	if not regen:
		_check_orphans(module, generated_rels)


func _compare(module: String, rel: String, golden_path: String, got: String) -> void:
	_total += 1
	var label: String = "%s/%s" % [module, rel]
	if not FileAccess.file_exists(golden_path):
		_fails += 1
		printerr("FAIL  %s — no golden (run STDB_REGEN_GOLDEN=1 to create)" % label)
		return
	var want: String = FileAccess.get_file_as_string(golden_path)
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — output differs from golden" % label)
	_print_first_diff(got, want)


func _check_orphans(module: String, generated_rels: Dictionary[String, bool]) -> void:
	var module_golden_dir: String = "%s/%s" % [GOLDEN_DIR, module]
	var golden_rels: PackedStringArray = _list_gd_rel(module_golden_dir, "", 0)
	for rel: String in golden_rels:
		if not generated_rels.has(rel):
			_total += 1
			_fails += 1
			printerr(
				"FAIL  %s/%s — golden has no generated counterpart (codegen dropped it, or stale golden)"
				% [module, rel]
			)


## Fails if a generated file declares a member its base already defines. Godot refuses to
## load such a script — "overrides a method from native class" against an engine class,
## `The member "x" already exists in parent class` against a GDScript one — and a single
## bad name takes the whole module's bindings down, not just that file. Real modules reach
## this: `set`, `notification`, `script`, `resource_name`, `count` and `iter` are all legal
## Rust identifiers and none are GDScript keywords, so keyword escaping does not catch them.
##
## Stands in for parsing the output, which the gdignored goldens do not allow. It asks the
## engine and the SDK bases what names are taken rather than trusting codegen's own escape
## helper, so a regression in that helper still fails here.
func _check_native_collisions(module: String, rel: String, text: String) -> void:
	_total += 1
	var label: String = "%s/%s native-member collisions" % [module, rel]
	var base: String = _declared_base(text)
	if not NATIVE_BASE_OF.has(base):
		_fails += 1
		printerr(
			"FAIL  %s — unknown base %s; add it to NATIVE_BASE_OF so it gets checked"
			% [label, base]
		)
		return
	var native_base: StringName = NATIVE_BASE_OF[base]
	var native_taken: Dictionary[String, bool] = _native_names(native_base)
	# An SDK base is a GDScript parent, where overriding a METHOD with an instance method
	# is legal and intentional — the table wrappers narrow `iter()`/`find_by()` to their
	# row type. Everything else fails: a `var` over a parent method or var, a method over
	# a parent var, or a `static func` over a parent instance method (signature mismatch).
	var sdk_instance_methods: Dictionary[String, bool] = { }
	var sdk_members: Dictionary[String, bool] = { }
	if _sdk_base_scripts.has(base):
		var sdk: Script = _sdk_base_scripts[base]
		for m: Dictionary in sdk.get_script_method_list():
			# METHOD_FLAG_STATIC marks a static method; only instance methods may be
			# overridden by a generated instance method.
			if int(m.get("flags", 0)) & METHOD_FLAG_STATIC:
				continue
			sdk_instance_methods[String(m.get("name", ""))] = true
		sdk_members = _script_names(sdk)
	var hits: PackedStringArray = []
	var seen: Dictionary[String, bool] = { }
	for entry: Array in _declared_members(text):
		var member_name: String = entry[0]
		var kind: String = entry[1]
		if native_taken.has(member_name) and not (member_name in _collision_exempt):
			hits.append("%s (native %s member)" % [member_name, native_base])
		elif (
			sdk_members.has(member_name)
			and not (kind == "func" and sdk_instance_methods.has(member_name))
		):
			hits.append("%s (already on parent %s)" % [member_name, base])
		# A generated file can also collide with ITSELF — an index accessor named after
		# one of the wrapper's own signals, say. Nothing inherited is involved, so the
		# base sets above cannot see it.
		if seen.has(member_name):
			hits.append("%s (declared twice)" % member_name)
		seen[member_name] = true
	if hits.is_empty():
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — %s; the generated script will not load" % [label, ", ".join(hits)])


## The class this script extends, from either `class_name X extends Y` or a bare
## `extends Y`. A script with no `extends` implicitly extends RefCounted — the generated
## `module_<x>_types.gd` aggregator is exactly that, a `class_name` over a list of preload
## constants — so that is what it reports.
func _declared_base(text: String) -> String:
	for line: String in text.split("\n"):
		var stripped: String = line.strip_edges()
		var marker: int = stripped.find("extends ")
		if marker == -1:
			continue
		if not (stripped.begins_with("extends ") or stripped.begins_with("class_name ")):
			continue
		return stripped.substr(marker + 8).strip_edges()
	return "RefCounted"


## Every member the script declares at class scope, as `[name, kind]` pairs where kind is
## "func", "static_func", "var", "const" or "signal". The kind matters: overriding a
## GDScript parent's instance method with an instance method is legal, while a `var` — or
## a `static func` — over that same name is not. Enum members are deliberately not
## collected: a named enum scopes them under the enum, so `enum Options { script }` does
## not collide (verified against 4.8.dev).
func _declared_members(text: String) -> Array:
	var out: Array = []
	for line: String in text.split("\n"):
		# Class-scope declarations only — an indented line is a body, not a member.
		if line.begins_with("\t") or line.begins_with(" "):
			continue
		# Strip any leading annotation, not just `@export ` — `@export_range(0, 100) var
		# script: int` declares `script` just as surely, and matching the literal prefix
		# would skip the line and pass a golden that cannot load.
		var stripped: String = _strip_annotations(line.strip_edges())
		var name_part: String = ""
		var kind: String = ""
		if stripped.begins_with("signal "):
			name_part = stripped.substr(7)
			kind = "signal"
		elif stripped.begins_with("static func "):
			name_part = stripped.substr(12)
			kind = "static_func"
		elif stripped.begins_with("func "):
			name_part = stripped.substr(5)
			kind = "func"
		elif stripped.begins_with("static var "):
			name_part = stripped.substr(11)
			kind = "var"
		elif stripped.begins_with("var "):
			name_part = stripped.substr(4)
			kind = "var"
		elif stripped.begins_with("const "):
			name_part = stripped.substr(6)
			kind = "const"
		else:
			continue
		var cut: int = name_part.length()
		for i: int in name_part.length():
			var c: String = name_part[i]
			if not (c.is_valid_identifier() or c == "_" or (c >= "0" and c <= "9")):
				cut = i
				break
		var member_name: String = name_part.substr(0, cut).strip_edges()
		if not member_name.is_empty():
			out.append([member_name, kind])
	return out


## Removes leading `@annotation` / `@annotation(...)` tokens from a declaration line.
## Bounded (NASA rule 2): a declaration carries a handful of annotations at most.
func _strip_annotations(line: String) -> String:
	var out: String = line
	for _i: int in 4:
		if not out.begins_with("@"):
			return out
		var paren: int = out.find("(")
		var space: int = out.find(" ")
		if paren != -1 and (space == -1 or paren < space):
			var close: int = out.find(")", paren)
			if close == -1:
				return out
			out = out.substr(close + 1).strip_edges()
		elif space != -1:
			out = out.substr(space + 1).strip_edges()
		else:
			return out
	return out


## Method, property and signal names a GDScript class declares, walking up any GDScript
## bases. Depth-bounded (NASA rule 2).
func _script_names(script: Script) -> Dictionary[String, bool]:
	var taken: Dictionary[String, bool] = { }
	var current: Script = script
	for _level: int in 8:
		if current == null:
			break
		for m: Dictionary in current.get_script_method_list():
			taken[String(m.get("name", ""))] = true
		for p: Dictionary in current.get_script_property_list():
			taken[String(p.get("name", ""))] = true
		for s: Dictionary in current.get_script_signal_list():
			taken[String(s.get("name", ""))] = true
		current = current.get_base_script()
	return taken


## Names already taken on [param native_base], methods and properties together — they
## share one namespace, so a `var free` collides with the method just as a `func script()`
## collides with the property.
##
## Properties are read off an INSTANCE on purpose: ClassDB.class_get_property_list reports
## neither inherited nor engine-special properties (`Object`'s comes back empty), so
## `script` — a name that really does break the load — is invisible there. That gap is what
## let the first version of this gate pass a golden Godot refuses to load.
func _native_names(native_base: StringName) -> Dictionary[String, bool]:
	if _native_names_cache.has(native_base):
		return _native_names_cache[native_base]
	var taken: Dictionary[String, bool] = { }
	for m: Dictionary in ClassDB.class_get_method_list(native_base):
		taken[String(m.get("name", ""))] = true
	var probe: Object = ClassDB.instantiate(native_base)
	if probe == null:
		printerr("could not instantiate %s to read property names" % native_base)
	else:
		const LABEL_USAGE: int = (
			PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
		)
		for p: Dictionary in probe.get_property_list():
			if int(p.get("usage", 0)) & LABEL_USAGE:
				continue
			taken[String(p.get("name", ""))] = true
		if not (probe is RefCounted):
			probe.free()
	_native_names_cache[native_base] = taken
	return taken


## Collects `.gd` file paths under [param base], relative to it. Depth-bounded (NASA rule 2).
func _list_gd_rel(base: String, prefix: String, depth: int) -> PackedStringArray:
	var out: PackedStringArray = []
	if depth > 8:
		return out
	var d: DirAccess = DirAccess.open(base)
	if d == null:
		return out
	d.list_dir_begin()
	var entry: String = d.get_next()
	while entry != "":
		var rel: String = entry if prefix.is_empty() else "%s/%s" % [prefix, entry]
		if d.current_is_dir():
			out.append_array(_list_gd_rel("%s/%s" % [base, entry], rel, depth + 1))
		elif entry.ends_with(".gd"):
			out.append(rel)
		entry = d.get_next()
	d.list_dir_end()
	return out


func _print_first_diff(got: String, want: String) -> void:
	var g: PackedStringArray = got.split("\n")
	var w: PackedStringArray = want.split("\n")
	var n: int = maxi(g.size(), w.size())
	for i: int in range(n):
		var gl: String = g[i] if i < g.size() else "<EOF>"
		var wl: String = w[i] if i < w.size() else "<EOF>"
		if gl != wl:
			printerr("      first diff at line %d:" % [i + 1])
			printerr("      golden: %s" % wl)
			printerr("      got:    %s" % gl)
			return


func _build_config(module: String) -> SpacetimeDBPluginConfig:
	var cfg: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var mc: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	mc.name = module
	mc.hide_private_tables = false
	mc.hide_scheduled_reducers = false
	cfg.module_configs[module] = mc
	return cfg


func _reset_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		_rm_rf(path)
	DirAccess.make_dir_recursive_absolute(path)


func _rm_rf(path: String, depth: int = 0) -> void:
	if depth > 8:
		return
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var entry: String = d.get_next()
	while entry != "":
		var child: String = "%s/%s" % [path, entry]
		if d.current_is_dir():
			_rm_rf(child, depth + 1)
		else:
			d.remove(child)
		entry = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


func _write(path: String, content: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("cannot write %s: %d" % [path, FileAccess.get_open_error()])
		return
	f.store_string(content)
	f.close()


func _fail(msg: String) -> void:
	_total += 1
	_fails += 1
	printerr("FAIL  %s" % msg)

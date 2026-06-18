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

const FIXTURES: Array[String] = ["vtypes", "vsum", "vtypes2"]
# Committed test inputs. NOT spacetime_bindings/codegen_debug/ — that dir is
# gitignored (transient codegen dumps), so fixtures there are absent on a clean
# clone. These live with the test and codegen never writes here.
const FIXTURE_DIR: String = "res://tests/fixtures"
const GOLDEN_DIR: String = "res://tests/golden"
const TMP_ROOT: String = "user://golden_gen"

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	var regen: bool = OS.get_environment("STDB_REGEN_GOLDEN") == "1"
	if regen:
		print("REGEN mode — writing goldens, not asserting")

	for module: String in FIXTURES:
		_run_module(module, regen)

	if regen:
		print("REGEN done — review `git diff %s` before committing" % GOLDEN_DIR)
		quit(0)
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
			printerr("FAIL  %s/%s — golden has no generated counterpart (codegen dropped it, or stale golden)" % [module, rel])


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

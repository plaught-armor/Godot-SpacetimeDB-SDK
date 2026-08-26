# Regression test: a module name that cannot name a GDScript class is refused before
# anything is written.
#
# A SpacetimeDB database name may start with a digit — parse_database_name
# (crates/client-api-messages/src/name.rs) accepts [a-z0-9] with single interior
# hyphens, so `2048` and `quickstart-chat` are both legal. Codegen names every class
# it emits after the module key put through to_pascal_case, and `2048` survives that
# unchanged: measured on the vtypes fixture, the run produced 19 scripts, all named
# `class_name 2048Something`, none of which parse, plus an autoload declaring
# `var 2048` — and it reported success, so the cleanup then pruned the previous,
# working bindings.
#
# The whole run is refused instead. Hyphens are NOT a problem (to_pascal_case drops
# them), so the legal-name case has to keep working.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_module_name_identifier.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
const TMP_ROOT: String = "user://codegen_module_name"
## Stands in for the previous run's output: it must survive a refused run.
const SENTINEL: String = "module_previous_run.gd"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	_rm_rf(TMP_ROOT)
	f += _test_legal_name_generates("vtypes")
	f += _test_legal_name_generates("quickstart-chat")
	f += _test_digit_leading_refused()
	f += _test_empty_name_refused()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## A name the server accepts and GDScript can spell still generates, hyphens included.
func _test_legal_name_generates(module_key: String) -> int:
	var tmp: String = "%s/ok_%s" % [TMP_ROOT, module_key.to_snake_case()]
	_reset_dir(tmp)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(module_key)
	var files: PackedStringArray = codegen.generate_bindings()

	var f: int = 0
	f += _check_b("%s: run completed" % module_key, not codegen.generation_incomplete, true)
	f += _check_b("%s: files generated" % module_key, files.size() > 1, true)
	f += _check_b(
		"%s: every emitted identifier is legal" % module_key,
		_all_identifiers(files),
		true,
	)
	return f


## The digit-leading name: nothing written, run marked incomplete, and the pruning
## half refuses — so the previous run's bindings are still there afterwards.
func _test_digit_leading_refused() -> int:
	var tmp: String = "%s/digit" % TMP_ROOT
	_reset_dir(tmp)
	var sentinel_path: String = "%s/%s" % [tmp, SENTINEL]
	var sentinel: FileAccess = FileAccess.open(sentinel_path, FileAccess.WRITE)
	sentinel.store_string("# previous run\n")
	sentinel.close()

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config("2048")
	var files: PackedStringArray = codegen.generate_bindings()

	var f: int = 0
	f += _check_i("2048: nothing generated", files.size(), 0)
	f += _check_b("2048: run marked incomplete", codegen.generation_incomplete, true)
	f += _check_b(
		"2048: finalize refuses to prune",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		false,
	)
	f += _check_b(
		"2048: the previous run's bindings survive",
		FileAccess.file_exists(sentinel_path),
		true,
	)
	f += _check_b(
		"2048: no autoload written over the working one",
		FileAccess.file_exists("%s/%s" % [tmp, SpacetimePlugin.AUTOLOAD_FILE_NAME]),
		false,
	)
	return f


## An empty module key reaches the same gate (to_pascal_case("") is "").
func _test_empty_name_refused() -> int:
	var tmp: String = "%s/empty" % TMP_ROOT
	_reset_dir(tmp)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config("")
	var files: PackedStringArray = codegen.generate_bindings()

	var f: int = 0
	f += _check_i("empty: nothing generated", files.size(), 0)
	f += _check_b("empty: run marked incomplete", codegen.generation_incomplete, true)
	return f


## Every identifier the run spelled itself — `class_name X`, `var X:`, `const X =`,
## `enum X` — is a legal GDScript identifier.
func _all_identifiers(files: PackedStringArray) -> bool:
	for path: String in files:
		if not path.ends_with(".gd"):
			continue
		for raw: String in FileAccess.get_file_as_string(path).split("\n"):
			var line: String = raw.strip_edges()
			var name: String = ""
			if line.begins_with("class_name "):
				name = line.substr("class_name ".length()).split(" ")[0].strip_edges()
			elif line.begins_with("var ") and line.contains(":"):
				name = line.substr(4, line.find(":") - 4).strip_edges()
			elif line.begins_with("const ") and line.contains("="):
				name = line.substr(6, line.find("=") - 6).split(":")[0].strip_edges()
			elif line.begins_with("enum "):
				name = line.substr(5).split(" ")[0].split("{")[0].strip_edges()
			if not name.is_empty() and not name.is_valid_identifier():
				printerr("      illegal identifier '%s' in %s" % [name, path.get_file()])
				return false
	return true


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


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

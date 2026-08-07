# Probe (not in the suite — a `_` prefix keeps run_tests.sh away, because this one
# provokes a GDScript runtime fault on purpose and the runner fails any test whose output
# carries SCRIPT ERROR).
#
# What it holds: codegen's pruning pass deletes every generated file the run's list does
# not name, and a GDScript fault unwinds only the function it happens in and hands the
# caller that function's DEFAULT — so a faulting parse looks exactly like a module with
# nothing to generate. Measured before the guards: 1 file instead of 19, and all 18 of the
# module's bindings deleted.
#
# The trigger here is a `sections` entry that is not a Dictionary, which a typed
# `for section: Dictionary in ...` faults on. Individual triggers get fixed as they are
# found (an unnamed column was the first, now refused in the parser and covered by
# tests/test_codegen_partial_schema.gd); what this probe pins is that the NEXT one, from
# whatever the server's schema grows into, still cannot delete a binding:
#
#   * parse_schema's result is read as a Variant and type-checked, so its null return does
#     not fault a second time in the caller.
#   * each generation stage sets SpacetimeCodegen._stage_completed at its own tail, so a
#     stage that unwound early is distinguishable from one that finished with nothing.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_codegen_fault.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
const MODULE: String = "vtypes"
const TMP: String = "user://codegen_fault_probe"

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_rm_rf(TMP)
	DirAccess.make_dir_recursive_absolute(TMP)

	# The previous run's bindings.
	var first: SpacetimeCodegen = SpacetimeCodegen.new(TMP)
	first._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var complete: Array[String] = first.generate_bindings() # gdlint: ignore[S6]
	_check("baseline generated the whole fixture", complete.size() >= 18)

	# A schema whose sections list holds something that is not an object. Everything
	# before the fault is ordinary parsing, so this is the "the parse died half way"
	# shape, not "the response was garbage" (which _generate_module_bindings already
	# refuses by type-checking the JSON body).
	var second: SpacetimeCodegen = SpacetimeCodegen.new(TMP)
	second._plugin_config = _config('{"sections": ["not an object"]}')
	var partial: Array[String] = second.generate_bindings() # gdlint: ignore[S6]
	_check("the faulting run produced less than the baseline", partial.size() < complete.size())
	_check("flagged incomplete", second.generation_incomplete)
	_check("finalize refuses", not SpacetimePlugin.finalize_bindings(second, partial, TMP))
	_check("every baseline binding survives", _all_exist(complete))

	# The whole-run sentinel guards generate_bindings' OWN frame, which no schema reaches
	# today (every stage that reads one is a callee), so it is exercised directly: an
	# unwound run arrives at finalize with the flags exactly as its last stage left them.
	var third: SpacetimeCodegen = SpacetimeCodegen.new(TMP)
	third._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var clean: Array[String] = third.generate_bindings() # gdlint: ignore[S6]
	_check("a clean run reached its own return", third.run_reached_return)
	third.run_reached_return = false
	_check("not flagged incomplete (the flag cannot see a fault)", not third.generation_incomplete)
	_check(
		"run sentinel: finalize refuses",
		not SpacetimePlugin.finalize_bindings(third, clean, TMP),
	)
	_check("bindings survive the unwound run", _all_exist(complete))

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _config(unparsed: String) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = MODULE
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	module_config.unparsed_module_schema = unparsed
	config.module_configs[MODULE] = module_config
	return config


func _all_exist(paths: Array[String]) -> bool: # gdlint: ignore[S6]
	for path: String in paths:
		if not FileAccess.file_exists(path):
			printerr("      missing: %s" % path)
			return false
	return true


func _check(label: String, ok: bool) -> void:
	_total += 1
	if ok:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s" % label)


func _rm_rf(path: String, depth: int = 0) -> void:
	if depth > 8:
		return
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [path, file_name])
	for sub: String in dir.get_directories():
		_rm_rf("%s/%s" % [path, sub], depth + 1)
	DirAccess.remove_absolute(path)

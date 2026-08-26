# Regression test: a codegen run that could not write every binding must not be
# allowed to prune.
#
# generate_bindings() is best-effort — a file it cannot open (a read-only VCS
# checkout, an OS lock, no space) or a module whose schema does not parse is
# reported and the run carries on — so the list it returns can name only part of
# the bindings. _cleanup_unused_classes deletes every generated file the list does
# NOT name, so feeding it a partial list deleted the previous run's still-valid
# output for the files that were never rewritten, along with their `.uid` sidecars
# (which is what every scene `ext_resource` resolves through). Measured before the
# fix on the vtypes fixture: one unwritable output file, and the module's
# procedures and types bindings were deleted.
#
# The gate is SpacetimeCodegen.generation_incomplete, checked by
# SpacetimePlugin.finalize_bindings before anything is deleted.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_codegen_partial_write.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
const MODULE: String = "vtypes"
const TMP_ROOT: String = "user://codegen_partial_gate"
## Written late in a module's run, so a failure before it leaves it untouched on disk
## and absent from the returned list — the exact shape cleanup used to delete.
const VICTIM: String = "module_vtypes_reducers.gd"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	_rm_rf(TMP_ROOT)
	f += _test_complete_run_prunes()
	f += _test_failed_write_keeps_bindings()
	f += _test_failed_uid_keeps_bindings()
	f += _test_unparsable_module_keeps_bindings()
	f += _test_empty_config_refused()
	f += await _test_no_modules_refused()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## The gate must not cost the cleanup: a run that wrote everything still prunes the
## files it replaced.
func _test_complete_run_prunes() -> int:
	var f: int = 0
	var tmp: String = "%s/complete" % TMP_ROOT
	_reset_dir(tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var files: PackedStringArray = codegen.generate_bindings()

	# A binding from an older schema that this run no longer emits.
	var stale: String = "%s/module_vtypes_gone.gd" % tmp
	_write(stale, "# stale\n")

	f += _check("complete run: not flagged incomplete", codegen.generation_incomplete, false)
	f += _check(
		"complete run: finalize accepts",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		true,
	)
	f += _check("complete run: stale binding pruned", FileAccess.file_exists(stale), false)
	f += _check("complete run: generated files kept", _all_exist(files), true)
	return f


## The bug: one unwritable output, and the files written after it — present on disk
## from the previous run, absent from this run's list — were deleted.
func _test_failed_write_keeps_bindings() -> int:
	var f: int = 0
	var tmp: String = "%s/failed_write" % TMP_ROOT
	_reset_dir(tmp)

	var config: SpacetimeDBPluginConfig = _config(FileAccess.get_file_as_string(FIXTURE))
	var first: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	first._plugin_config = config
	var complete: PackedStringArray = first.generate_bindings()
	f += _check("failed write: baseline run generated files", complete.size() > 1, true)

	# A directory where a file belongs is the portable way to make
	# FileAccess.open(..., WRITE) fail; the real-world shapes are a read-only
	# checkout, an OS-level lock, or a full disk.
	var victim: String = "%s/%s" % [tmp, VICTIM]
	DirAccess.remove_absolute(victim)
	DirAccess.make_dir_recursive_absolute(victim)
	f += _check("failed write: victim path unwritable", _can_write(victim), false)

	var second: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	second._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var partial: PackedStringArray = second.generate_bindings()

	var dropped: PackedStringArray = _dropped(complete, partial, victim)
	f += _check("failed write: run returned a partial list", dropped.size() > 0, true)
	f += _check("failed write: flagged incomplete", second.generation_incomplete, true)
	f += _check(
		"failed write: finalize refuses",
		SpacetimePlugin.finalize_bindings(second, partial, tmp),
		false,
	)
	f += _check("failed write: dropped bindings survive", _all_exist(dropped), true)
	return f


## The `.gd` can be written and its `.uid` sidecar not — and the sidecar is what every
## scene `ext_resource uid="..."` resolves through, so a run that lost one is exactly as
## incomplete as a run that lost a script.
func _test_failed_uid_keeps_bindings() -> int:
	var f: int = 0
	var tmp: String = "%s/failed_uid" % TMP_ROOT
	_reset_dir(tmp)

	var first: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	first._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var complete: PackedStringArray = first.generate_bindings()

	var victim_uid: String = "%s/%s.uid" % [tmp, VICTIM]
	DirAccess.remove_absolute(victim_uid)
	DirAccess.make_dir_recursive_absolute(victim_uid)
	f += _check("failed uid: sidecar path unwritable", _can_write(victim_uid), false)

	var second: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	second._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var files: PackedStringArray = second.generate_bindings()
	f += _check("failed uid: flagged incomplete", second.generation_incomplete, true)
	f += _check(
		"failed uid: finalize refuses",
		SpacetimePlugin.finalize_bindings(second, files, tmp),
		false,
	)
	f += _check("failed uid: bindings survive", _all_exist(complete), true)
	return f


## A generator run over an empty module list writes nothing but the autoload and reports
## no failure, so the incomplete flag cannot catch it — finalize_bindings has to refuse it
## on its own, at the function that does the deleting.
func _test_empty_config_refused() -> int:
	var f: int = 0
	var tmp: String = "%s/empty_config" % TMP_ROOT
	_reset_dir(tmp)

	var planted: String = "%s/module_vtypes_client.gd" % tmp
	_write(planted, "# a binding from an earlier run\n")

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = SpacetimeDBPluginConfig.new()
	var files: PackedStringArray = codegen.generate_bindings()
	f += _check("empty config: nothing flagged incomplete", codegen.generation_incomplete, false)
	f += _check(
		"empty config: finalize refuses",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		false,
	)
	f += _check("empty config: existing binding survives", FileAccess.file_exists(planted), true)
	return f


## Same gate from the other direction: a module whose schema does not parse
## contributes no files at all, so cleanup would have deleted every binding it had.
func _test_unparsable_module_keeps_bindings() -> int:
	var f: int = 0
	var tmp: String = "%s/unparsable" % TMP_ROOT
	_reset_dir(tmp)

	var first: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	first._plugin_config = _config(FileAccess.get_file_as_string(FIXTURE))
	var complete: PackedStringArray = first.generate_bindings()

	var second: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	second._plugin_config = _config("{ not json")
	var partial: PackedStringArray = second.generate_bindings()
	f += _check("unparsable: flagged incomplete", second.generation_incomplete, true)
	f += _check(
		"unparsable: finalize refuses",
		SpacetimePlugin.finalize_bindings(second, partial, tmp),
		false,
	)
	f += _check("unparsable: bindings survive", _all_exist(complete), true)
	return f


## An empty module list would generate nothing but the autoload, and cleanup against
## that list deletes every binding in the project. One click away on a fresh install
## or after removing the last module, so generate_schema refuses it outright.
func _test_no_modules_refused() -> int:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	# Never suspends on this path — generate_schema returns before its first request.
	var ok: bool = await SpacetimePlugin.generate_schema(null, config)
	return _check("no modules: generate_schema refuses", ok, false)


func _config(unparsed: String) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = MODULE
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	module_config.unparsed_module_schema = unparsed
	config.module_configs[MODULE] = module_config
	return config


## Paths the complete run produced that the partial run did not name, minus the victim
## itself (which really was not written).
func _dropped(
	complete: PackedStringArray,
	partial: PackedStringArray,
	victim: String,
) -> PackedStringArray:
	var out: PackedStringArray = []
	for path: String in complete:
		if path == victim or partial.has(path):
			continue
		out.append(path)
	return out


func _all_exist(paths: PackedStringArray) -> bool:
	for path: String in paths:
		if not FileAccess.file_exists(path):
			printerr("      missing: %s" % path)
			return false
	return true


func _can_write(path: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.close()
	return true


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("could not write %s" % path)
		return
	file.store_string(text)
	file.close()


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1


func _reset_dir(path: String) -> void:
	_rm_rf(path)
	DirAccess.make_dir_recursive_absolute(path)


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

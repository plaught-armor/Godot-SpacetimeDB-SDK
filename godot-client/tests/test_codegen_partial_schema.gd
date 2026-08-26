# Regression test: a schema the parser could only read PART of must not be allowed to
# prune, and a parser that faults must not read as "this module has no bindings".
#
# Sibling of test_codegen_partial_write.gd, which covers the same destructive step
# (SpacetimePlugin.finalize_bindings deletes every generated file the run's list does not
# name) reached from the other side — there a WRITE failed, here the SCHEMA did.
#
# Two shapes, both measured against the vtypes fixture before the fix:
#
#   1. Report-and-carry-on. The parser skips a table whose row type does not resolve, an
#      index column out of range, a view with an unsupported return type — printing an
#      error each time and continuing. Nothing told the caller, so the run looked
#      complete: one out-of-range product_type_ref emitted 17 files instead of 19 and
#      cleanup deleted the table wrapper and its unique-index accessor.
#   2. A parser FAULT. A GDScript runtime error unwinds only the function it happens in
#      and hands the caller that function's default — `null` for parse_schema — so the
#      typed assignment faulted in turn, _generate_module_bindings unwound before setting
#      any flag, and the module contributed nothing: 1 file (the autoload) instead of 19,
#      and all 18 of the module's bindings were deleted.
#
# The inputs are malformed schemas rather than ones a healthy server sends — which is the
# point: the schema arrives over HTTP from something that may be a proxy, an older or
# newer server, or a truncated response, and the cost of misreading one is deleting the
# user's bindings. Every case here asserts the same two things: the run is flagged
# incomplete (or finalize refuses on its own), and every file the baseline run produced
# is still on disk afterwards.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_codegen_partial_schema.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vtypes.json"
const MODULE: String = "vtypes"
const TMP_ROOT: String = "user://codegen_partial_schema"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	_rm_rf(TMP_ROOT)

	var base: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (base is Dictionary):
		printerr("FAIL  fixture is not a JSON object")
		quit(1)
		return
	var fixture: Dictionary = base

	f += _test_intact_schema_prunes(fixture)
	# The parse reports each of these and carries on, so the schema describes only part
	# of the module. The first two drop a whole table; the third drops nothing today but
	# is the same class of report and must gate the same way.
	f += _degraded(
		"row type out of range",
		_mutate_table(fixture, "product_type_ref", 999.0),
		fixture,
	)
	f += _degraded("row type is a Sum", _table_points_at_sum(fixture), fixture)
	f += _degraded(
		"primary key column out of range",
		_mutate_table(fixture, "primary_key", [99.0]),
		fixture,
	)
	# The shape that used to FAULT rather than report: an unnamed product element reached
	# `var pk_field_name: String = ...struct[i].name` as a null.
	f += _degraded("column with no name", _unnamed_column(fixture), fixture)
	# The shape that used to be SILENT: the table loop's own first guard skipped an entry
	# it could not key on without a word, so the parse looked clean and the run reported
	# success. Measured before the fix: `product_type_ref: null` generated 17 files
	# instead of 19 with zero errors, and the pruning pass deleted the table wrapper and
	# its unique-index accessor. An ABSENT key already reported (it defaults to -1, which
	# lands on the invalid-type report), so only a present-but-unusable value got through.
	f += _degraded(
		"row type ref is null",
		_mutate_table(fixture, "product_type_ref", null),
		fixture,
	)
	f += _degraded(
		"row type ref is a string",
		_mutate_table(fixture, "product_type_ref", "3"),
		fixture,
	)
	f += _degraded(
		"row type ref is an object",
		_mutate_table(fixture, "product_type_ref", { }),
		fixture,
	)
	# The other half of that guard. A table with no name can be generated for even less
	# than one with no row type — every file name, class name and member name comes from
	# it — and it was the same silent skip.
	f += _degraded("table with no name", _mutate_table(fixture, "source_name", ""), fixture)

	f += _test_second_module_not_half_written(fixture)

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## The gate must not cost the cleanup: an intact schema still prunes what it replaced.
func _test_intact_schema_prunes(fixture: Dictionary) -> int:
	var f: int = 0
	var tmp: String = "%s/intact" % TMP_ROOT
	_reset_dir(tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(JSON.stringify(fixture))
	var files: PackedStringArray = codegen.generate_bindings()

	var stale: String = "%s/module_vtypes_gone.gd" % tmp
	_write(stale, "# stale\n")

	f += _check("intact: not flagged incomplete", codegen.generation_incomplete, false)
	f += _check(
		"intact: finalize accepts",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		true,
	)
	f += _check("intact: stale binding pruned", FileAccess.file_exists(stale), false)
	f += _check("intact: generated files kept", _all_exist(files), true)
	return f


## Runs [param schema] against a directory already holding everything the intact fixture
## generates — those files stand in for the previous run's still-valid bindings, and any
## one of them missing afterwards is a binding the user lost.
func _degraded(label: String, schema: Dictionary, fixture: Dictionary) -> int:
	var f: int = 0
	var tmp: String = "%s/%s" % [TMP_ROOT, label.replace(" ", "_")]
	_reset_dir(tmp)

	var first: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	first._plugin_config = _config(JSON.stringify(fixture))
	var complete: PackedStringArray = first.generate_bindings()
	f += _check("%s: baseline generated files" % label, complete.size() > 1, true)
	# Content, not just paths: a run that rewrote half a module against the other half's
	# stale files leaves a db facade whose table members no longer match the wrappers
	# beside it — every path still present, and the project broken.
	var before: Dictionary[String, String] = _snapshot(complete)

	var second: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	second._plugin_config = _config(JSON.stringify(schema))
	var partial: PackedStringArray = second.generate_bindings()
	f += _check("%s: flagged incomplete" % label, second.generation_incomplete, true)
	f += _check(
		"%s: finalize refuses" % label,
		SpacetimePlugin.finalize_bindings(second, partial, tmp),
		false,
	)
	f += _check("%s: bindings survive unchanged" % label, _unchanged(before), true)
	return f


## Two modules, one of them degraded. The healthy one must not be left half-applied
## either: its files are rewritten from a schema that parsed, but the autoload — which
## PRELOADS a client per module — would then name the module that generated nothing. On a
## module the project has never generated that autoload is a preload of a missing file,
## i.e. a project that stops booting because the OTHER module's schema was bad.
func _test_second_module_not_half_written(fixture: Dictionary) -> int:
	var f: int = 0
	var tmp: String = "%s/two_modules" % TMP_ROOT
	_reset_dir(tmp)

	var config: SpacetimeDBPluginConfig = _config(JSON.stringify(fixture))
	var other: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	other.name = "other"
	other.hide_private_tables = false
	other.hide_scheduled_reducers = false
	other.unparsed_module_schema = JSON.stringify(fixture)
	config.module_configs["other"] = other

	var first: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	first._plugin_config = config
	var complete: PackedStringArray = first.generate_bindings()
	f += _check("two modules: baseline generated both", complete.size() > 20, true)
	var before: Dictionary[String, String] = _snapshot(complete)

	# Same pair, but the FIRST module's schema is the degraded one.
	var degraded: SpacetimeDBPluginConfig = _config(
		JSON.stringify(_mutate_table(fixture, "product_type_ref", 999.0))
	)
	var other_again: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	other_again.name = "other"
	other_again.hide_private_tables = false
	other_again.hide_scheduled_reducers = false
	other_again.unparsed_module_schema = JSON.stringify(fixture)
	degraded.module_configs["other"] = other_again

	var second: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	second._plugin_config = degraded
	var partial: PackedStringArray = second.generate_bindings()
	f += _check("two modules: flagged incomplete", second.generation_incomplete, true)
	f += _check(
		"two modules: finalize refuses",
		SpacetimePlugin.finalize_bindings(second, partial, tmp),
		false,
	)
	f += _check(
		"two modules: the autoload was not rewritten",
		FileAccess.get_file_as_string("%s/%s" % [tmp, SpacetimePlugin.AUTOLOAD_FILE_NAME]),
		before["%s/%s" % [tmp, SpacetimePlugin.AUTOLOAD_FILE_NAME]],
	)
	f += _check(
		"two modules: the degraded module's bindings are untouched",
		_unchanged(_only(before, "module_vtypes")),
		true,
	)
	return f


## The subset of [param snapshot] whose file name contains [param needle].
func _only(snapshot: Dictionary[String, String], needle: String) -> Dictionary[String, String]:
	var out: Dictionary[String, String] = { }
	for path: String in snapshot:
		if path.get_file().contains(needle):
			out[path] = snapshot[path]
	return out

# --- schema mutations ---


func _mutate_table(fixture: Dictionary, key: String, value: Variant) -> Dictionary:
	var d: Dictionary = fixture.duplicate(true)
	_tables(d)[0][key] = value
	return d


## A table whose row type resolves to a Sum rather than a Product: the parser reports
## "refers to an invalid or non-struct type" and skips the table.
func _table_points_at_sum(fixture: Dictionary) -> Dictionary:
	var d: Dictionary = fixture.duplicate(true)
	var types: Array = _typespace(d)
	types.append(
		{
			"Sum": {
				"variants": [
					{ "name": { "some": "A" }, "algebraic_type": { "Product": { "elements": [] } } },
					{ "name": { "some": "B" }, "algebraic_type": { "Product": { "elements": [] } } },
				]
			}
		}
	)
	_tables(d)[0]["product_type_ref"] = float(types.size() - 1)
	return d


## An unnamed product element. Named columns are what every generated spelling needs (the
## @export var, the BSATN_TYPES key, the primary-key lookup), and the server forbids an
## unnamed one on a table outright — so the parser refuses the schema rather than reading
## the null and faulting, which is what it did before.
func _unnamed_column(fixture: Dictionary) -> Dictionary:
	var d: Dictionary = fixture.duplicate(true)
	_typespace(d)[0]["Product"]["elements"][0]["name"] = { "none": [] }
	return d


func _typespace(d: Dictionary) -> Array:
	for section: Dictionary in d["sections"]:
		if section.has("Typespace"):
			return section["Typespace"]["types"]
	return []


func _tables(d: Dictionary) -> Array:
	for section: Dictionary in d["sections"]:
		if section.has("Tables"):
			return section["Tables"]
	return []

# --- helpers (mirroring test_codegen_partial_write.gd) ---


func _config(unparsed: String) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = MODULE
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	module_config.unparsed_module_schema = unparsed
	config.module_configs[MODULE] = module_config
	return config


func _all_exist(paths: PackedStringArray) -> bool:
	for path: String in paths:
		if not FileAccess.file_exists(path):
			printerr("      missing: %s" % path)
			return false
	return true


## path -> content, for every path in [param paths].
func _snapshot(paths: PackedStringArray) -> Dictionary[String, String]:
	var out: Dictionary[String, String] = { }
	for path: String in paths:
		out[path] = FileAccess.get_file_as_string(path)
	return out


func _unchanged(before: Dictionary[String, String]) -> bool:
	for path: String in before:
		if not FileAccess.file_exists(path):
			printerr("      missing: %s" % path)
			return false
		if FileAccess.get_file_as_string(path) != before[path]:
			printerr("      rewritten: %s" % path)
			return false
	return true


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("could not write %s" % path)
		return
	file.store_string(text)
	file.close()


func _check(label: String, got: Variant, want: Variant) -> int: # gdlint: ignore[H10b]
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

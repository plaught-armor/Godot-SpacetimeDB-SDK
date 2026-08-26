# Regression test: a name that only collides BECAUSE of submodule flattening must fail the
# run, not the generated bindings.
#
# A submodule's table carries its namespace into the identifier its class and file are
# named from — `lib.lib_data` becomes `lib_lib_data` — so two names the server keeps apart
# can arrive at one GDScript name:
#
#   * a ROOT table literally named `lib_lib_data` beside submodule `lib`'s `lib_data`:
#     one `class_name`, one output path, and the second write silently replaces the first;
#   * a root table (or reducer) named `auth` beside a submodule namespace `auth`: the db
#     facade declares `var auth:` twice at one scope and Godot refuses the file.
#
# `SpacetimePlugin.finalize_bindings` catches both after the fact through its class-name
# and path gates, which is what keeps the pruning pass from deleting the module's previous
# bindings. This test pins the earlier half: codegen itself reports the pair by name and
# marks the run incomplete, so the message says which two names collided rather than
# leaving a later gate to report that something declares one name twice.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_submodule_collisions.gd
extends SceneTree

const TMP_ROOT: String = "user://codegen_submodule_collisions"
const MODULE: String = "vcollide_sub"

## Written into a file before a run that is expected to be refused: a refused run must not
## replace it, so finding it afterwards is what proves nothing was overwritten.
const PRIOR_BINDING_MARKER: String = "# previous, working bindings\n"

var _total: int = 0
var _fails: int = 0
var _last_output_dir: String = ""


func _initialize() -> void:
	_reset_dir(TMP_ROOT)

	_check_clean_module_is_not_flagged()
	_check_identifier_collision_refused()
	_check_namespace_shadows_table_refused()
	_check_namespace_shadows_reducer_refused()
	_check_private_table_does_not_collide()
	_check_type_name_collision_refused()
	_check_gate_survives_an_earlier_module_failure()

	_rm_rf(TMP_ROOT)
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_total += 1
	if ok:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s%s" % [label, "" if detail.is_empty() else ": " + detail])


# A row type with one u64 column, and the table over it. `ty` and `product_type_ref` are
# per module — the parser offsets a submodule's into the shared typespace.
func _module_sections(table_name: String, type_name: String, reducer_name: String) -> Array:
	var sections: Array = [
		{
			"Typespace": {
				"types": [
					{
						"Product": {
							"elements": [
								{ "name": { "some": "id" }, "algebraic_type": { "U64": [] } }
							]
						}
					}
				]
			}
		},
		{ "Types": [{ "source_name": { "scope": [], "source_name": type_name }, "ty": 0 }] },
		{
			"Tables": [
				{
					"source_name": table_name,
					"product_type_ref": 0,
					"primary_key": [0],
					"indexes": [],
					"constraints": [],
					"sequences": [],
					"table_type": { "User": [] },
					"table_access": { "Public": [] },
					"is_event": false,
				}
			]
		},
	]
	if not reducer_name.is_empty():
		sections.append(
			{
				"Reducers": [
					{
						"source_name": reducer_name,
						"params": { "elements": [] },
						"visibility": { "ClientCallable": [] },
						"ok_return_type": { "Product": { "elements": [] } },
						"err_return_type": { "String": [] },
					}
				]
			}
		)
	return sections


func _schema_with_submodule(
	root_table: String,
	root_reducer: String,
	namespace_name: String,
	sub_table: String,
) -> Dictionary:
	var sections: Array = _module_sections(root_table, "RootRow", root_reducer)
	sections.append(
		{
			"Submodules": [
				{
					"namespace": namespace_name,
					"module": { "sections": _module_sections(sub_table, "SubRow", "sub_insert") },
				}
			]
		}
	)
	return { "sections": sections }


# Runs a generation into its own temp dir and returns whether it flagged the run.
#
# [param seeded] names files (relative to the output dir) to write a marker into first, so
# a caller can assert a refused run left the module's PREVIOUS bindings alone: the flag
# only stops the pruning pass and the autoload rewrite that come after, and it cannot undo
# a write that already happened.
func _generation_flagged(
	label: String,
	raw_schema: Dictionary,
	hide_private: bool = false,
	seeded: PackedStringArray = [],
	already_failed: bool = false,
) -> bool:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(raw_schema, MODULE, { })
	if schema.is_empty():
		_check(label, false, "parse_schema returned empty")
		return false

	var tmp: String = "%s/%s" % [TMP_ROOT, label.to_snake_case()]
	_reset_dir(tmp)
	DirAccess.make_dir_recursive_absolute("%s/types" % tmp)
	DirAccess.make_dir_recursive_absolute("%s/tables" % tmp)
	for relative_path: String in seeded:
		var seed_file: FileAccess = FileAccess.open(
			"%s/%s" % [tmp, relative_path],
			FileAccess.WRITE,
		)
		seed_file.store_string(PRIOR_BINDING_MARKER)
		seed_file.close()

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _build_config(hide_private)
	# Stands in for an earlier module in the same run having failed: the flag is reset once
	# per run, not per module, so a second module is reached with it already true.
	codegen.generation_incomplete = already_failed
	# Neither half can be seeded by this harness, which is the point: `generation_incomplete`
	# is true before the call in the cascade cases, so reading it back proves nothing. An
	# error counted during the call is what THIS module reported, and the empty file list is
	# what the pre-write bail returns — a run that reached its writes names them.
	#
	# So an empty list means THE PRE-WRITE GATE fired, not "the run was refused" in general:
	# a run that fails partway through its writes returns the files it managed. Every case
	# here takes the pre-write path; one modelling a mid-write failure would need a
	# different signal.
	var errors_before: int = SpacetimePlugin.error_count
	var generated: PackedStringArray = codegen._generate_gdscript_from_schema(MODULE, schema)
	_last_output_dir = tmp
	return generated.is_empty() and SpacetimePlugin.error_count > errors_before


# True when every file seeded for the last run still carries its marker.
func _seeded_files_survived(relative_paths: PackedStringArray) -> bool:
	for relative_path: String in relative_paths:
		var path: String = "%s/%s" % [_last_output_dir, relative_path]
		if FileAccess.get_file_as_string(path) != PRIOR_BINDING_MARKER:
			return false
	return true


# The control: the same shapes with names that do not collide must generate clean, or the
# three cases below would pass with the gates always firing.
func _check_clean_module_is_not_flagged() -> void:
	var flagged: bool = _generation_flagged(
		"clean",
		_schema_with_submodule("root_thing", "root_insert", "lib", "lib_data"),
	)
	_check("a submodule whose names do not collide generates clean", not flagged)


func _check_identifier_collision_refused() -> void:
	var seeded: PackedStringArray = ["tables/%s_lib_lib_data_table.gd" % MODULE.to_snake_case()]
	var flagged: bool = _generation_flagged(
		"identifier",
		_schema_with_submodule("lib_lib_data", "root_insert", "lib", "lib_data"),
		false,
		seeded,
	)
	_check("a root table spelled like a submodule table's identifier fails the run", flagged)
	_check(
		"the refused run did not write over the previous table wrapper",
		_seeded_files_survived(seeded),
	)


func _check_namespace_shadows_table_refused() -> void:
	var seeded: PackedStringArray = ["module_%s_db.gd" % MODULE.to_snake_case()]
	var flagged: bool = _generation_flagged(
		"table_shadow",
		_schema_with_submodule("lib", "root_insert", "lib", "lib_data"),
		false,
		seeded,
	)
	_check("a root table named like a namespace fails the run", flagged)
	_check(
		"the refused run did not write over the previous db facade",
		_seeded_files_survived(seeded),
	)


func _check_namespace_shadows_reducer_refused() -> void:
	var seeded: PackedStringArray = ["module_%s_reducers.gd" % MODULE.to_snake_case()]
	var flagged: bool = _generation_flagged(
		"reducer_shadow",
		_schema_with_submodule("root_thing", "lib", "lib", "lib_data"),
		false,
		seeded,
	)
	_check("a root reducer named like a namespace fails the run", flagged)
	_check(
		"the refused run did not write over the previous reducers facade",
		_seeded_files_survived(seeded),
	)


# The gate reads the tables that are actually GENERATED: a colliding table the module's
# private-table filter drops is not one of them, and refusing that module would refuse a
# name nothing emits.
func _check_private_table_does_not_collide() -> void:
	var raw: Dictionary = _schema_with_submodule("lib_lib_data", "root_insert", "lib", "lib_data")
	_make_root_table_private(raw)
	_check(
		"a colliding table the private filter drops does not fail the run",
		not _generation_flagged("private_filtered", raw, true),
	)
	_check(
		"the same module with the filter off still fails",
		_generation_flagged("private_unfiltered", raw, false),
	)


func _make_root_table_private(raw_schema: Dictionary) -> void:
	for section: Dictionary in raw_schema["sections"]:
		if not section.has("Tables"):
			continue
		for table: Dictionary in section["Tables"]:
			table["table_access"] = { "Private": [] }
		return


func _build_config(hide_private: bool) -> SpacetimeDBPluginConfig:
	var cfg: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var mc: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	mc.name = MODULE
	mc.hide_private_tables = hide_private
	mc.hide_scheduled_reducers = false
	cfg.module_configs[MODULE] = mc
	return cfg


func _reset_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		_rm_rf(path)
	DirAccess.make_dir_recursive_absolute(path)


func _rm_rf(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		var full: String = "%s/%s" % [path, entry]
		if dir.current_is_dir():
			_rm_rf(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


# A submodule's TYPES take the namespace in PascalCase, so `lib`'s `Point` generates
# `LibPoint` — the same class, and the same file, as a root type spelled that way. The
# second write replaces the first with no error of its own: the root type's fields simply
# become the submodule's.
func _check_type_name_collision_refused() -> void:
	var sections: Array = _module_sections("root_thing", "LibPoint", "root_insert")
	sections.append(
		{
			"Submodules": [
				{
					"namespace": "lib",
					"module": { "sections": _module_sections("lib_data", "Point", "sub_insert") },
				}
			]
		}
	)
	var seeded: PackedStringArray = ["types/%s_lib_point.gd" % MODULE.to_snake_case()]
	var flagged: bool = _generation_flagged("type_name", { "sections": sections }, false, seeded)
	_check("a root type spelled like a submodule type's class fails the run", flagged)
	_check(
		"the refused run did not write over the previous row type",
		_seeded_files_survived(seeded),
	)


# `generation_incomplete` lives for a whole RUN, not for one module, so a codegen instance
# reaches a second module with the flag already set by the first. This module's own
# collision has to stop its write anyway — and a module with no collision of its own has to
# keep generating, or a healthy module would go stale because something unrelated failed.
func _check_gate_survives_an_earlier_module_failure() -> void:
	var seeded: PackedStringArray = ["module_%s_db.gd" % MODULE.to_snake_case()]
	var colliding: Dictionary = _schema_with_submodule("lib", "root_insert", "lib", "lib_data")
	_check(
		"a collision still stops the write when an earlier module already failed",
		_generation_flagged("cascade_collision", colliding, false, seeded, true),
	)
	_check(
		"and that refused run still did not write over the previous db facade",
		_seeded_files_survived(seeded),
	)

	var clean: Dictionary = _schema_with_submodule("root_thing", "root_insert", "lib", "lib_data")
	_generation_flagged("cascade_clean", clean, false, [], true)
	_check(
		"a healthy module still generates after an earlier module failed",
		FileAccess.file_exists("%s/module_%s_db.gd" % [_last_output_dir, MODULE.to_snake_case()]),
	)

# Regression test: two generated scripts must never claim one global class name, and two
# must never be written to one path.
#
# Third sibling of test_codegen_partial_write.gd / test_codegen_partial_schema.gd, which
# cover the same destructive step (SpacetimePlugin.finalize_bindings deletes every
# generated file the run's list does not name) reached from the write side and the schema
# side. Here the schema parses perfectly and every file is written — the names themselves
# collide.
#
# Every generated class name is the module prefix plus a name the module author chose,
# plus whatever suffix its kind adds, and the reserved suffixes are ordinary spellings a
# module type may already end in. Measured on this fixture before the gate:
#
#   * a module type `PlayerTable` beside a table `player` — both files declare
#     `class_name VclashPlayerTable`, and Godot refuses the second: `Parse Error: Class
#     "VclashPlayerTable" hides a global script class`, so the row type behind a column
#     does not load at all;
#   * the same for `PlayerNameUniqueIndex` beside the unique index on `player.name`, and
#     for `Types` / `ModuleDb` beside the module's own facades — the generated client
#     assigns `db = preload(...).new(...)` into a `var db: VclashModuleDb` that now names
#     a row type, so the assignment fails and `db` stays null;
#   * types `AABB` and `Aabb` both land on `types/vclash_aabb.gd` — the second overwrote
#     the first with no error at all, so one declared type had no bindings anywhere.
#
# None of it flagged the run: generation_incomplete stayed false, so finalize pruned, and
# the previous — working — bindings were deleted to make room for a broken set.
#
# The two shapes are driven separately on purpose. The committed fixture carries only
# collisions no other gate can see, so the end-to-end assertions here fail the moment the
# class gate is removed; the same-path shape is added to the schema in memory, because a
# pair that collides on the file name also collides as a member of the module's types
# facade, and _check_member_collisions catches that one on its own — an end-to-end
# assertion driven from it would pass with this whole gate deleted.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_codegen_class_collision.gd
extends SceneTree

const CLASH_FIXTURE: String = "res://tests/fixtures/vclash.json"
const CLASH_MODULE: String = "vclash"
const CLEAN_FIXTURE: String = "res://tests/fixtures/vtypes.json"
const CLEAN_MODULE: String = "vtypes"
const TMP_ROOT: String = "user://codegen_class_collision"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	_rm_rf(TMP_ROOT)

	f += _test_declared_class_name_scan()
	f += _test_colliding_module_refused()
	f += _test_same_path_written_twice()
	f += _test_duplicate_enum_variants()
	f += _test_module_prefix_problems()
	f += _test_class_name_taken_elsewhere()
	f += _test_clean_module_still_prunes()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## The pure half: what the scan reads out of one script's text.
func _test_declared_class_name_scan() -> int:
	var f: int = 0
	f += _check(
		"scan: class_name with extends",
		SpacetimeCodegen.declared_class_name("@tool\nclass_name FooBar extends Resource\n"),
		"FooBar",
	)
	f += _check(
		"scan: class_name alone",
		SpacetimeCodegen.declared_class_name("class_name FooBar\n\nvar x: int = 1\n"),
		"FooBar",
	)
	f += _check(
		"scan: no class_name",
		SpacetimeCodegen.declared_class_name("extends Resource\n\nvar x: int = 1\n"),
		"",
	)
	# An inner class declares its own name inside the outer one's namespace, and a
	# commented-out line declares nothing — neither is a global class.
	f += _check(
		"scan: indented class_name is not the file's",
		SpacetimeCodegen.declared_class_name("extends Node\n\nclass Inner:\n\tclass_name Nope\n"),
		"",
	)
	f += _check(
		"scan: commented class_name is not read",
		SpacetimeCodegen.declared_class_name("# class_name Ghost extends Node\nextends Node\n"),
		"",
	)
	return f


## The whole path, against a directory already holding a previous run's bindings.
func _test_colliding_module_refused() -> int:
	var f: int = 0
	var tmp: String = "%s/clash" % TMP_ROOT
	_reset_dir(tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(CLASH_MODULE, _fixture_text(CLASH_FIXTURE))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]

	# What makes the gate necessary rather than redundant: nothing upstream sees this.
	f += _check("clash: schema parsed, run not flagged", codegen.generation_incomplete, false)
	f += _check("clash: files were generated", files.size() > 1, true)

	# Asserted on the emitted set itself, so a fix that changed only the message would
	# still have to keep the collision detectable.
	f += _check("clash: every path written once", _has_duplicate_path(files), false)
	f += _check(
		"clash: VclashPlayerTable declared twice",
		_files_declaring(files, "VclashPlayerTable").size(),
		2,
	)
	f += _check(
		"clash: VclashModuleDb declared twice",
		_files_declaring(files, "VclashModuleDb").size(),
		2,
	)
	f += _check(
		"clash: VclashTypes declared twice",
		_files_declaring(files, "VclashTypes").size(),
		2,
	)
	f += _check(
		"clash: VclashPlayerNameUniqueIndex declared twice",
		_files_declaring(files, "VclashPlayerNameUniqueIndex").size(),
		2,
	)
	f += _check(
		"clash: the scan itself refuses",
		SpacetimePlugin._check_class_collisions(PackedStringArray(files), tmp),
		false,
	)

	# A file the previous run left behind stands in for bindings this run did not rewrite.
	# That is exactly what the gate saves — the paths this run DID write already carry the
	# colliding output by the time finalize speaks, same as for the member gate, and the
	# author gets them back by renaming and regenerating. What the prune would take is
	# everything else: other modules, tables this schema no longer names, their .uid
	# sidecars.
	var stale: String = "%s/module_vclash_gone.gd" % tmp
	_write(stale, "# stale\n")
	f += _check(
		"clash: finalize refuses",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		false,
	)
	f += _check("clash: nothing was pruned", FileAccess.file_exists(stale), true)
	return f


## The other half: two schema names that produce one FILE. `AABB` and `Aabb` are distinct
## types server-side and both land on `<module>_aabb.gd`, so the second write silently
## replaces the first and one of them has no bindings at all — the run's file list is the
## only place that fact survives, which is why the check reads the list and not the disk.
func _test_same_path_written_twice() -> int:
	var f: int = 0
	var tmp: String = "%s/same_path" % TMP_ROOT
	_reset_dir(tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(CLASH_MODULE, JSON.stringify(_with_acronym_pair()))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	f += _check("same path: run not flagged", codegen.generation_incomplete, false)
	f += _check("same path: a path was written twice", _has_duplicate_path(files), true)
	f += _check(
		"same path: the scan refuses",
		SpacetimePlugin._check_class_collisions(PackedStringArray(files), tmp),
		false,
	)
	# Why this shape is not driven through finalize, and why the assertion above is on the
	# file list rather than on which branch reported: the pair also lands on one member of
	# the module's types facade, so the older gate refuses it whatever this one does.
	f += _check(
		"same path: the member gate sees it too",
		SpacetimePlugin._check_member_collisions(PackedStringArray(files)),
		false,
	)
	return f


## The committed fixture plus two types whose names differ only inside an acronym run.
func _with_acronym_pair() -> Dictionary:
	var parsed: Variant = JSON.parse_string(_fixture_text(CLASH_FIXTURE))
	if not (parsed is Dictionary):
		printerr("FAIL  fixture is not a JSON object")
		return { }
	var schema: Dictionary = (parsed as Dictionary).duplicate(true)
	for section: Dictionary in schema["sections"]:
		if section.has("Typespace"):
			var types: Array = section["Typespace"]["types"]
			types.append(_empty_product())
			types.append(_empty_product())
		elif section.has("Types"):
			var entries: Array = section["Types"]
			entries.append(_type_entry("AABB", entries.size()))
			entries.append(_type_entry("Aabb", entries.size()))
	return schema


## A schema whose only type is a plain (all-unit-variant) enum with two variants that
## pascal-case to one name.
func _schema_with_enum() -> Dictionary:
	var unit: Dictionary = { "Product": { "elements": [] } }
	return {
		"sections": [
			{
				"Typespace": {
					"types": [
						{
							"Sum": {
								"variants": [
									{ "name": { "some": "foo_bar" }, "algebraic_type": unit },
									{ "name": { "some": "fooBar" }, "algebraic_type": unit },
								],
							},
						},
					],
				},
			},
			{ "Types": [_type_entry("Kind", 0)] },
			{ "Tables": [] },
			{ "Reducers": [] },
			{ "ExplicitNames": { "entries": [] } },
		],
	}


## A schema with one single-field struct per name in [param type_names] and no tables.
func _schema_with_types(type_names: Array[String]) -> Dictionary: # gdlint: ignore[S6]
	var typespace: Array = []
	var types: Array = []
	for source_name: String in type_names:
		types.append(_type_entry(source_name, typespace.size()))
		typespace.append(_empty_product())
	return {
		"sections": [
			{ "Typespace": { "types": typespace } },
			{ "Types": types },
			{ "Tables": [] },
			{ "Reducers": [] },
			{ "ExplicitNames": { "entries": [] } },
		],
	}


func _empty_product() -> Dictionary:
	return {
		"Product": { "elements": [{ "name": { "some": "n" }, "algebraic_type": { "U32": [] } }] },
	}


func _type_entry(source_name: String, index: int) -> Dictionary:
	return {
		"source_name": { "scope": [], "source_name": source_name },
		"ty": index,
		"custom_ordering": true,
	}


## A plain enum's variants are pascal-cased too, and they live inside the enum rather than
## at the top level — so the member scan cannot see them and Godot refuses the whole
## `<Module>Types` file, i.e. every type the module declares.
func _test_duplicate_enum_variants() -> int:
	var f: int = 0
	f += _check(
		"variants: a repeat is reported as Enum.Variant",
		SpacetimeCodegen.find_duplicate_enum_variants("enum Kind {\n\tFooBar,\n\tFooBar\n}\n"),
		PackedStringArray(["Kind.FooBar"]),
	)
	f += _check(
		"variants: distinct variants are clean",
		SpacetimeCodegen.find_duplicate_enum_variants("enum Kind {\n\tA,\n\tB\n}\n"),
		PackedStringArray(),
	)
	# One name per enum: two enums may each declare `A`, and a top-level member of the
	# same name is a different namespace again.
	f += _check(
		"variants: two enums may share a name",
		SpacetimeCodegen.find_duplicate_enum_variants(
			"enum One {\n\tA\n}\n\nenum Two {\n\tA\n}\n\nvar A: int = 0\n"
		),
		PackedStringArray(),
	)
	# The block ends at the closing brace: an indented line further down the file belongs
	# to whatever declared it, not to the enum.
	f += _check(
		"variants: an indented line after the block is not a variant",
		SpacetimeCodegen.find_duplicate_enum_variants(
			"enum One {\n\tA\n}\n\nfunc f() -> void:\n\tA\n\tA\n"
		),
		PackedStringArray(),
	)
	# Variants carry no explicit value today; the reader strips one anyway, so the name is
	# what is compared rather than the assignment.
	f += _check(
		"variants: an explicit value is not part of the name",
		SpacetimeCodegen.find_duplicate_enum_variants("enum Kind {\n\tA = 1,\n\tA = 2\n}\n"),
		PackedStringArray(["Kind.A"]),
	)

	var tmp: String = "%s/enum_variants" % TMP_ROOT
	_reset_dir(tmp)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(CLASH_MODULE, JSON.stringify(_schema_with_enum()))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	f += _check("variants: run not flagged", codegen.generation_incomplete, false)
	f += _check(
		"variants: the scan refuses",
		SpacetimePlugin._check_member_collisions(PackedStringArray(files)),
		false,
	)
	var stale: String = "%s/module_vclash_gone.gd" % tmp
	_write(stale, "# stale\n")
	f += _check(
		"variants: finalize refuses",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		false,
	)
	f += _check("variants: nothing was pruned", FileAccess.file_exists(stale), true)
	return f


## The module key's own prefix, checked before a single file is written: it heads every
## class the module emits AND is the property the autoload declares for its client.
func _test_module_prefix_problems() -> int:
	var f: int = 0
	f += _check(
		"prefix: distinct modules are clean",
		SpacetimeCodegen.module_prefix_problems(["alpha", "beta"]).is_empty(),
		true,
	)
	# to_pascal_case cannot tell these two apart, so one module's every file, class and
	# autoload property would overwrite the other's.
	f += _check(
		"prefix: two keys yielding one prefix",
		SpacetimeCodegen.module_prefix_problems(["foo-bar", "foo_bar"]).size(),
		1,
	)
	# `time` is a legal SpacetimeDB database name; `var Time: TimeModuleClient` is not a
	# property Godot will accept, and it lands in the autoload the project boots through.
	f += _check(
		"prefix: a native class name",
		SpacetimeCodegen.module_prefix_problems(["time"]).size(),
		1,
	)
	# ClassDB knows engine CLASSES only and answers false for every Variant builtin, so
	# the builtin half needs its own answer — `color`, `signal`, `array` and `node-path`
	# are all legal database names.
	f += _check(
		"prefix: Color is a builtin type",
		SpacetimeCodegen.is_builtin_type_name("Color"),
		true,
	)
	f += _check(
		"prefix: a native class is not a builtin type",
		SpacetimeCodegen.is_builtin_type_name("Node"),
		false,
	)
	f += _check(
		"prefix: an ordinary name is neither",
		SpacetimeCodegen.is_builtin_type_name("Blackholio"),
		false,
	)
	# The parser builds its own table the same way and skips two entries. `Nil` really is
	# free — measured accepted as both a class name and a member — and `nil` is as legal a
	# database name as `time`, so refusing it would be a refusal Godot does not make.
	f += _check("prefix: Nil is not refused", SpacetimeCodegen.is_builtin_type_name("Nil"), false)
	f += _check(
		"prefix: a module named nil is accepted",
		SpacetimeCodegen.module_prefix_problems(["nil"]).is_empty(),
		true,
	)
	f += _check(
		"prefix: a builtin type name",
		SpacetimeCodegen.module_prefix_problems(["color"]).size(),
		1,
	)
	f += _check(
		"prefix: a hyphenated builtin type name",
		SpacetimeCodegen.module_prefix_problems(["node-path"]).size(),
		1,
	)

	var tmp: String = "%s/prefix" % TMP_ROOT
	_reset_dir(tmp)
	var stale: String = "%s/module_time_gone.gd" % tmp
	_write(stale, "# stale\n")
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config("time", _fixture_text(CLEAN_FIXTURE))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	f += _check("prefix: run flagged incomplete", codegen.generation_incomplete, true)
	f += _check("prefix: nothing was written", files.is_empty(), true)
	f += _check(
		"prefix: finalize refuses",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		false,
	)
	f += _check("prefix: nothing was pruned", FileAccess.file_exists(stale), true)
	return f


## The collision the run cannot see by looking only at itself: a name already claimed by
## a class the project (or the SDK, or the engine) already has.
func _test_class_name_taken_elsewhere() -> int:
	var f: int = 0
	# Module `audio` + type `Stream` spells the native class AudioStream.
	f += _check(
		"taken: a native class name refuses",
		_generated_classes_accepted("audio", ["Stream"]),
		false,
	)
	# Module `local` + type `Database` spells LocalDatabase, one of the SDK's own.
	f += _check(
		"taken: an existing global class refuses",
		_generated_classes_accepted("local", ["Database"]),
		false,
	)
	# A builtin type name is spellable the same way — every segment of a generated class
	# name is upper-initial, so any builtin that splits on a case boundary is reachable.
	# `packed` passes the prefix gate, which makes this branch the only thing between that
	# module and a script Godot will not load.
	f += _check(
		"taken: a builtin type name refuses",
		_generated_classes_accepted("packed", ["ByteArray"]),
		false,
	)
	# The control: the same shape with names nothing else claims.
	f += _check(
		"taken: an unclaimed name is accepted",
		_generated_classes_accepted("vclash", ["Widget"]),
		true,
	)

	# The exclusion that keeps this from refusing every regeneration after the first: the
	# previous run's own output is registered under exactly the names this run re-declares.
	# Pinned against the SDK's own directory rather than a generated one, because the temp
	# directories above are under user://, where nothing is ever in the class list.
	const SDK_CORE: String = "res://addons/SpacetimeDB/core"
	f += _check(
		"outside: a class under dir_path is excluded",
		SpacetimePlugin._global_classes_outside(SDK_CORE).has("LocalDatabase"),
		false,
	)
	f += _check(
		"outside: a trailing slash is the same directory",
		SpacetimePlugin._global_classes_outside("%s/" % SDK_CORE).has("LocalDatabase"),
		false,
	)
	# Also the vacuity guard: an empty class list would pass both checks above.
	f += _check(
		"outside: a class elsewhere is kept",
		SpacetimePlugin._global_classes_outside(SpacetimePlugin.BINDINGS_SCHEMA_PATH).has(
			"LocalDatabase"
		),
		true,
	)
	# An autoload's registered name is global too, and an autoload need not declare a
	# class_name — so the global-class list cannot see it, and the gate reads the autoload
	# settings separately. Only the collection is asserted here: this project's single
	# autoload is `SpacetimeDB`, and no (prefix, schema name) pair spells that — pascal
	# case gives `SpacetimeDb` — so the refusal itself is not reachable from this project.
	# It is reachable in a consumer's: alias `save` plus a type `System` is `SaveSystem`.
	f += _check(
		"outside: an autoload outside dir_path is seen",
		SpacetimePlugin._autoload_names_outside("res://addons").has("SpacetimeDB"),
		true,
	)
	f += _check(
		"outside: an autoload inside dir_path is excluded",
		SpacetimePlugin._autoload_names_outside(SpacetimePlugin.BINDINGS_SCHEMA_PATH).has(
			"SpacetimeDB"
		),
		false,
	)
	f += _check(
		"outside: an autoload dir_path with a trailing slash is the same directory",
		(SpacetimePlugin._autoload_names_outside("%s/" % SpacetimePlugin.BINDINGS_SCHEMA_PATH).has(
				"SpacetimeDB"
			)),
		false,
	)
	f += _test_singleton_flag_decides()
	return f


## The `*` on an autoload's value is the SINGLETON flag, not "enabled" — only a singleton
## claims its name as a global identifier, so only a singleton can collide. Registered
## here at runtime (in memory; nothing is saved and no autoload is instantiated) because
## this project ships exactly one autoload and it is a singleton.
func _test_singleton_flag_decides() -> int:
	var f: int = 0
	# Nothing loads or compiles a script between the registration and the erase below,
	# which is what keeps these temporary autoloads invisible to everything else.
	var script: String = "res://addons/SpacetimeDB/spacetime.gd"
	var own_autoload: String = "%s/spacetime_autoload.gd" % SpacetimePlugin.BINDINGS_SCHEMA_PATH
	ProjectSettings.set_setting("autoload/StdbProbeSingleton", "*%s" % script)
	ProjectSettings.set_setting("autoload/StdbProbePlain", script)
	# The second registration prefix the engine accepts, and the two uid forms: one that
	# resolves to a script inside the bindings directory, one that resolves to nothing.
	ProjectSettings.set_setting("autoload_prepend/StdbProbePrepend", "*%s" % script)
	ProjectSettings.set_setting(
		"autoload/StdbProbeOwnUid",
		"*%s" % ResourceUID.id_to_text(ResourceLoader.get_resource_uid(own_autoload)),
	)
	ProjectSettings.set_setting("autoload/StdbProbeDeadUid", "*uid://zzzzzzzzzzzzz")

	var names: Dictionary[String, String] = SpacetimePlugin._autoload_names_outside(
		SpacetimePlugin.BINDINGS_SCHEMA_PATH
	)
	f += _check("singleton: a singleton autoload is a name", names.has("StdbProbeSingleton"), true)
	f += _check("singleton: a plain autoload is not", names.has("StdbProbePlain"), false)
	f += _check("singleton: autoload_prepend counts too", names.has("StdbProbePrepend"), true)
	# A uid pointing inside dir_path must resolve, or the run's own output reads as taken.
	f += _check("singleton: a uid inside dir_path is excluded", names.has("StdbProbeOwnUid"), false)
	# An unresolvable uid is kept, with the empty path that reads as "outside". The
	# has_id guard around it changes only whether Godot prints its own "Unrecognized UID"
	# line — the returned path is empty either way — so this pins the verdict, not the
	# guard: nothing in-process can observe an engine error line.
	f += _check("singleton: an unknown uid is kept", names.get("StdbProbeDeadUid", "?"), "")

	ProjectSettings.set_setting("autoload/StdbProbeSingleton", null)
	ProjectSettings.set_setting("autoload/StdbProbePlain", null)
	# The engine's erase branch calls remove_autoload for `autoload/` only, so the
	# prepend entry stays in its internal map — the settings property, which is what this
	# reader walks, does erase.
	ProjectSettings.set_setting("autoload_prepend/StdbProbePrepend", null)
	ProjectSettings.set_setting("autoload/StdbProbeOwnUid", null)
	ProjectSettings.set_setting("autoload/StdbProbeDeadUid", null)
	return f


## Generates a module whose only types are [param type_names] and reports whether the
## class-collision gate accepts the result.
func _generated_classes_accepted(module: String, type_names: Array[String]) -> bool: # gdlint: ignore[S6]
	var tmp: String = "%s/taken_%s" % [TMP_ROOT, module]
	_reset_dir(tmp)
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(module, JSON.stringify(_schema_with_types(type_names)))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	return SpacetimePlugin._check_class_collisions(PackedStringArray(files), tmp)


## The gate must not cost the cleanup: a module with no colliding name still finalizes
## and still prunes what it replaced.
func _test_clean_module_still_prunes() -> int:
	var f: int = 0
	var tmp: String = "%s/clean" % TMP_ROOT
	_reset_dir(tmp)

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = _config(CLEAN_MODULE, _fixture_text(CLEAN_FIXTURE))
	var files: Array[String] = codegen.generate_bindings() # gdlint: ignore[S6]
	f += _check("clean: files were generated", files.size() > 1, true)
	f += _check("clean: no duplicate path", _has_duplicate_path(files), false)
	f += _check(
		"clean: the scan accepts",
		SpacetimePlugin._check_class_collisions(PackedStringArray(files), tmp),
		true,
	)

	var stale: String = "%s/module_vtypes_gone.gd" % tmp
	_write(stale, "# stale\n")
	f += _check(
		"clean: finalize accepts",
		SpacetimePlugin.finalize_bindings(codegen, files, tmp),
		true,
	)
	f += _check("clean: stale binding pruned", FileAccess.file_exists(stale), false)
	f += _check("clean: generated files kept", _all_exist(files), true)
	return f

# --- helpers ---


func _fixture_text(path: String) -> String:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		printerr("FAIL  fixture missing: %s" % path)
	return text


func _config(module: String, unparsed: String) -> SpacetimeDBPluginConfig:
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = module
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	module_config.unparsed_module_schema = unparsed
	config.module_configs[module] = module_config
	return config


func _has_duplicate_path(paths: Array[String]) -> bool: # gdlint: ignore[S6]
	var seen: Dictionary[String, bool] = { }
	for path: String in paths:
		if seen.has(path):
			return true
		seen[path] = true
	return false


## The paths whose script declares [param class_name_wanted], read back off disk.
func _files_declaring(paths: Array[String], class_name_wanted: String) -> PackedStringArray: # gdlint: ignore[S6]
	var out: PackedStringArray = []
	var seen: Dictionary[String, bool] = { }
	for path: String in paths:
		if seen.has(path) or not path.ends_with(".gd"):
			continue
		seen[path] = true
		var source: String = FileAccess.get_file_as_string(path)
		if SpacetimeCodegen.declared_class_name(source) == class_name_wanted:
			out.append(path)
	return out


func _all_exist(paths: Array[String]) -> bool: # gdlint: ignore[S6]
	for path: String in paths:
		if not FileAccess.file_exists(path):
			printerr("      missing: %s" % path)
			return false
	return true


func _write(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("could not write %s" % path)
		return
	file.store_string(text)
	file.close()


func _reset_dir(path: String) -> void:
	_rm_rf(path)
	DirAccess.make_dir_recursive_absolute("%s/types" % path)
	DirAccess.make_dir_recursive_absolute("%s/tables" % path)


func _rm_rf(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file: String in dir.get_files():
		DirAccess.remove_absolute("%s/%s" % [path, file])
	for sub: String in dir.get_directories():
		_rm_rf("%s/%s" % [path, sub])
	DirAccess.remove_absolute(path)


func _check(label: String, got: Variant, want: Variant) -> int: # gdlint: ignore[H10b]
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1

# Regression test for how a VIEW's backing table is described to the client.
#
# A view is delivered like any other table (one TableUpdate under the view's name), so the
# SDK synthesizes a table entry for it from the schema's Views section. That entry used to
# be a copy of the first table sharing the view's row type — which handed the view that
# TABLE's primary key, unique/btree indexes and `is_event` flag. None of them are the
# view's:
#
#   * A procedural view (`Vec<T>` / `Option<T>`) has a primary key only when the module
#     declared one (`#[view(primary_key = ...)]`, which reaches us as a ViewPrimaryKeys
#     entry). The server does the same — `assign_query_view_primary_keys` infers a key for
#     `Query<T>` views ONLY, and `TableSchema::from_view_def_for_codegen` builds a view's
#     schema with the view's own key, empty index/constraint/sequence lists and
#     `is_event: false`. Measured against a live 2.8.0 server: a view returning two rows
#     that share the source table's key column (a legal return — a view's rows are whatever
#     the function built, not a table's set) arrived as two rows and the mirror held ONE,
#     reporting the second as an update of the first. Silent data loss.
#   * A view whose row type belongs to an EVENT table inherited `is_event`, so codegen
#     dropped its index accessors even though a view's rows are resident.
#
# The fixture is a real `spacetime publish` schema (SpacetimeDB 2.8.0) with four procedural
# views, one of them declaring a primary key, one returning an event table's row type.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_view_table_shape.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vview.json"
const TMP: String = "user://view_shape_gen"

var _total: int = 0


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	var schema: SpacetimeParsedSchema = _parse()
	if schema == null:
		return 1
	f += _test_parsed_tables(schema)
	f += _test_generated_source(schema)
	f += _test_mirror_keys_view_by_value()
	f += _test_mirror_still_keys_a_table()
	return f


func _parse() -> SpacetimeParsedSchema:
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (json is Dictionary):
		printerr("FAIL  fixture %s is not a JSON object" % FIXTURE)
		return null
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(json, "vview", { })
	if schema.is_empty():
		printerr("FAIL  parse_schema returned empty")
		return null
	return schema

# --- the parsed table entries ------------------------------------------------------


func _table(schema: SpacetimeParsedSchema, table_name: String) -> Dictionary:
	for table_def: Dictionary in schema.tables:
		if table_def.get("name", "") == table_name:
			return table_def
	return { }


func _test_parsed_tables(schema: SpacetimeParsedSchema) -> int:
	var f: int = 0

	# The base table keeps everything the schema gave it — the fix must not reach it.
	var thing: Dictionary = _table(schema, "thing")
	f += _check_s("thing keeps its primary key", thing.get("primary_key_name", ""), "id")
	f += _check_i("thing keeps its unique index", thing.get("unique_indexes", []).size(), 1)
	f += _check_i("thing keeps its btree index", thing.get("btree_indexes", []).size(), 1)
	f += _check_b(
		"damage is still an event table",
		_table(schema, "damage").get("is_event", false),
		true,
	)

	# A procedural view over `thing`'s row type: no key, no indexes of the table's.
	for view_name: String in ["my_thing", "things_over", "dupes"]:
		var view_def: Dictionary = _table(schema, view_name)
		f += _check_b("%s exists as a table entry" % view_name, not view_def.is_empty(), true)
		f += _check_s("%s has no primary key" % view_name, view_def.get("primary_key_name", ""), "")
		f += _check_i(
			"%s has no unique index" % view_name,
			view_def.get("unique_indexes", []).size(),
			0,
		)
		f += _check_i(
			"%s has no btree index" % view_name,
			view_def.get("btree_indexes", []).size(),
			0,
		)

	# A view that DOES declare one keeps it.
	f += _check_s(
		"thing_briefs keeps its declared primary key",
		_table(schema, "thing_briefs").get("primary_key_name", ""),
		"thing_id",
	)

	# A view returning an event table's row type is not itself an event table.
	f += _check_b(
		"damage_mirror is not an event table",
		_table(schema, "damage_mirror").get("is_event", false),
		false,
	)
	return f

# --- the generated source ----------------------------------------------------------


func _test_generated_source(schema: SpacetimeParsedSchema) -> int:
	var f: int = 0
	_reset_dir(TMP)
	DirAccess.make_dir_recursive_absolute("%s/types" % TMP)
	DirAccess.make_dir_recursive_absolute("%s/tables" % TMP)

	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = "vview"
	module_config.hide_private_tables = false
	module_config.hide_scheduled_reducers = false
	config.module_configs["vview"] = module_config

	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(TMP)
	codegen._plugin_config = config
	var paths: Array = codegen._generate_gdscript_from_schema("vview", schema)
	f += _check_b("codegen produced files", not paths.is_empty(), true)

	var generated: PackedStringArray = []
	for path: String in paths: # gdlint: ignore[S6]
		generated.append(path.get_file())

	# The row type is shared by the table and three views that disagree about the key, so
	# the per-table map is what carries it — PRIMARY_KEY alone would key every view by `id`.
	var thing_row: String = FileAccess.get_file_as_string("%s/types/vview_thing.gd" % TMP)
	f += _check_b(
		"the shared row type carries a per-table primary key",
		thing_row.contains("const PRIMARY_KEY_BY_TABLE"),
		true,
	)
	f += _check_b(
		"the shared row type spells no single PRIMARY_KEY",
		thing_row.contains("const PRIMARY_KEY:"),
		false,
	)
	f += _check_b("the table's key is in the map", thing_row.contains("&\"thing\": &\"id\""), true)
	f += _check_b("a view's entry is empty", thing_row.contains("&\"dupes\": &\"\""), true)

	# A row type backing one keyed view keeps the plain const (nothing disagrees).
	var brief_row: String = FileAccess.get_file_as_string("%s/types/vview_thing_brief.gd" % TMP)
	f += _check_b(
		"a view-only row type keeps PRIMARY_KEY",
		brief_row.contains("const PRIMARY_KEY: StringName = &\"thing_id\""),
		true,
	)

	# Index accessors belong to the table that declared the index, not to views over it.
	f += _check_b(
		"the table gets its unique index accessor",
		generated.has("vview_thing_id_unique_index.gd"),
		true,
	)
	for view_name: String in ["my_thing", "things_over", "dupes", "damage_mirror"]:
		f += _check_b(
			"%s gets no index accessor" % view_name,
			_has_prefix(generated, "vview_%s_" % view_name, "_index.gd"),
			false,
		)
	return f


func _has_prefix(files: PackedStringArray, prefix: String, suffix: String) -> bool:
	for file_name: String in files:
		if file_name.begins_with(prefix) and file_name.ends_with(suffix):
			return true
	return false

# --- what the mirror does with it --------------------------------------------------


# The measured bug: a view delivering two rows that share the source table's key column.
# With no primary key the mirror holds them by value, so both survive.
func _test_mirror_keys_view_by_value() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_SharedRow, &"view_rows")
	f += _check_s("the view resolves no primary key", db._get_primary_key_field(&"view_rows"), &"")

	# A lambda captures a local by VALUE (#69014), so the counters live in a container.
	var inserts: PackedInt32Array = [0]
	var updates: PackedInt32Array = [0]
	db.subscribe_to_inserts(
		&"view_rows",
		func(_row: _ModuleTableType) -> void:
			inserts[0] += 1,
	)
	db.subscribe_to_updates(
		&"view_rows",
		func(_old_row: _ModuleTableType, _new_row: _ModuleTableType) -> void:
			updates[0] += 1,
	)

	_apply(db, &"view_rows", [_SharedRow.new(7, 1), _SharedRow.new(7, 2)], [])
	f += _check_i("both view rows are cached", db.get_all_rows(&"view_rows").size(), 2)
	f += _check_i("both fired on_insert", inserts[0], 2)
	f += _check_i("neither was reported as an update", updates[0], 0)

	_apply(db, &"view_rows", [], [_SharedRow.new(7, 1)])
	f += _check_i("deleting one leaves the other", db.get_all_rows(&"view_rows").size(), 1)
	db.free()
	return f


# The same row script, read through the TABLE's name, still takes the primary-key path.
func _test_mirror_still_keys_a_table() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db(_SharedRow, &"thing")
	f += _check_s("the table resolves its primary key", db._get_primary_key_field(&"thing"), &"id")

	var updates: PackedInt32Array = [0]
	db.subscribe_to_updates(
		&"thing",
		func(_old_row: _ModuleTableType, _new_row: _ModuleTableType) -> void:
			updates[0] += 1,
	)
	_apply(db, &"thing", [_SharedRow.new(7, 1)], [])
	_apply(db, &"thing", [_SharedRow.new(7, 2)], [_SharedRow.new(7, 1)])
	f += _check_i("the keyed table holds one row", db.get_all_rows(&"thing").size(), 1)
	f += _check_i("the change came through as an update", updates[0], 1)
	db.free()
	return f


func _mk_db(row_script: GDScript, table_name: StringName) -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [table_name]
	schema.types[table_name] = row_script
	schema.tables[table_name] = row_script
	return LocalDatabase.new(schema)


func _apply(db: LocalDatabase, table_name: StringName, inserts: Array, deletes: Array) -> void:
	var update: TableUpdateData = TableUpdateData.new()
	update.table_name = table_name
	var typed_inserts: Array[Resource] = []
	typed_inserts.assign(inserts)
	var typed_deletes: Array[Resource] = []
	typed_deletes.assign(deletes)
	update.inserts = typed_inserts
	update.deletes = typed_deletes
	db.apply_table_update(update)


func _reset_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for sub_dir: String in DirAccess.get_directories_at(path):
		_reset_dir("%s/%s" % [path, sub_dir])
	for file_name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute("%s/%s" % [path, file_name])
	DirAccess.remove_absolute(path)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


# What codegen now emits for a row type shared by a keyed table and an unkeyed view.
class _SharedRow:
	extends _ModuleTableType
	const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32", &"score": &"u32" }
	const PRIMARY_KEY_BY_TABLE: Dictionary[StringName, StringName] = {
		&"thing": &"id",
		&"view_rows": &"",
	}
	@export var id: int = 0
	@export var score: int = 0


	func _init(p_id: int = 0, p_score: int = 0) -> void:
		id = p_id
		score = p_score

# Parser test for view primary-key handling (SpacetimeDB v10 ViewPrimaryKeys).
#
# The primary key of a view is NOT the primary key of a table that happens to share its
# row type. The server decides it in `assign_query_view_primary_keys`:
#
#   * `Query<T>` view (return type `{ __query__: Ref(T) }`) — inherits the key of a table
#     built on T when it declares none of its own. Nothing is serialized for that, so the
#     client has to redo the inference.
#   * procedural view (`Vec<T>` / `Option<T>`) — has a key only when the module declared
#     one, which arrives as a ViewPrimaryKeys entry.
#
# Either way the key belongs to the VIEW, not to the row type: the row type is shared, so
# writing a view's key onto it re-keys the underlying table too, and taking a table's key
# for a procedural view collapses two view rows that share that column into one (a view's
# rows are whatever the view function returned, not a table's set — measured against a
# live 2.8.0 server, see tests/test_view_table_shape.gd).
#
# Guards, on minimal synthetic v10 schemas:
#   1. A procedural view with no ViewPrimaryKeys entry leaves the table's key alone and
#      takes none itself.
#   2. An explicit ViewPrimaryKeys entry keys the VIEW and only the view.
#   3. A Query<T> view with no entry of its own inherits the table's key,
#   4. bails when two tables on the row type name different keys (the server's "Ambiguous
#      source table" arm), and
#   5. skips a table that has no key rather than reading it as "no key inherited".
#   6. A private table hidden from the generated code does not key a public view that
#      shares its row type — the key must come from the tables that survived the filter,
#      not from the row type, which names whichever table wrote it last.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_view_primary_key.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_procedural_view_leaves_table_pk()
	fails += _test_explicit_view_pk()
	fails += _test_query_view_inherits_table_pk()
	fails += _test_query_view_ambiguous_source()
	fails += _test_query_view_unkeyed_source_first()
	fails += _test_hidden_private_table_does_not_key_a_view()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# A U32 product type with two named fields (id, score), shared by a table and a view that
# returns [param view_return] over the same row type.
func _base_sections(view_return: Dictionary) -> Array:
	var row_type: Dictionary = {
		"Product": {
			"elements": [
				{ "name": { "some": "id" }, "algebraic_type": { "U32": [] } },
				{ "name": { "some": "score" }, "algebraic_type": { "U32": [] } },
			],
		},
	}
	return [
		{ "Typespace": { "types": [row_type] } },
		{ "Types": [{ "source_name": { "scope": [], "source_name": "Player" }, "ty": 0 }] },
		{
			"Tables": [
				{
					"source_name": "player",
					"product_type_ref": 0,
					"primary_key": [0], # field 0 = "id"
					"indexes": [],
					"constraints": [],
				},
			],
		},
		{ "Views": [{ "source_name": "player_view", "return_type": view_return }] },
	]


# Vec<Player>: a procedural view.
func _procedural_return() -> Dictionary:
	return { "Array": { "Ref": 0 } }


# { __query__: Player }: the query-builder encoding (QUERY_VIEW_RETURN_TAG).
func _query_return() -> Dictionary:
	return {
		"Product": {
			"elements": [{ "name": { "some": "__query__" }, "algebraic_type": { "Ref": 0 } }]
		},
	}


func _find_type(schema: SpacetimeParsedSchema, type_name: String) -> Dictionary:
	for type_def: Dictionary in schema.types:
		if type_def.get("name", "") == type_name:
			return type_def
	return { }


func _find_table(schema: SpacetimeParsedSchema, table_name: String) -> Dictionary:
	for table_def: Dictionary in schema.tables:
		if table_def.get("name", "") == table_name:
			return table_def
	return { }


# Case 1: no ViewPrimaryKeys on a procedural view — the table keeps "id", the view gets
# nothing, and the view is registered on the shared row type.
func _test_procedural_view_leaves_table_pk() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _base_sections(_procedural_return()) },
		"test_mod",
	)
	var f: int = 0
	var player: Dictionary = _find_type(schema, "Player")
	f += _check_b("type resolved", not player.is_empty(), true)
	f += _check_s("table PK preserved", player.get("primary_key_name", "<missing>"), "id")
	f += _check_b("view registered on row type", player.get("table_names", []).has("player_view"), true)
	f += _check_s(
		"table entry keeps its PK",
		_find_table(schema, "player").get("primary_key_name", ""),
		"id",
	)
	f += _check_s(
		"procedural view has no PK",
		_find_table(schema, "player_view").get("primary_key_name", "<missing>"),
		"",
	)
	return f


# Case 2: an explicit ViewPrimaryKeys entry naming "score" keys the view — and nothing
# else. The shared row type still reports the table's key, so the table is untouched.
func _test_explicit_view_pk() -> int:
	var sections: Array = _base_sections(_procedural_return())
	sections.append(
		{ "ViewPrimaryKeys": [{ "view_source_name": "player_view", "columns": ["score"] }] },
	)
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": sections },
		"test_mod",
	)
	var f: int = 0
	f += _check_s(
		"explicit view PK applied to the view",
		_find_table(schema, "player_view").get("primary_key_name", "<missing>"),
		"score",
	)
	f += _check_s(
		"the table it shares a row type with is untouched",
		_find_table(schema, "player").get("primary_key_name", "<missing>"),
		"id",
	)
	f += _check_s(
		"the shared row type still reports the table's key",
		_find_type(schema, "Player").get("primary_key_name", "<missing>"),
		"id",
	)
	return f


# Case 3: a Query<T> view with no entry of its own inherits the table's key, matching the
# server's assign_query_view_primary_keys.
func _test_query_view_inherits_table_pk() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _base_sections(_query_return()) },
		"test_mod",
	)
	var f: int = 0
	f += _check_s(
		"query view inherits the table PK",
		_find_table(schema, "player_view").get("primary_key_name", "<missing>"),
		"id",
	)
	return f


# The same sections, plus a second table on the row type. [param second_pk] is the raw
# `primary_key` list (`[]` = that table has none) and [param access] its table_access.
func _sections_with_second_table(
	view_return: Dictionary,
	second_pk: Array,
	second_first: bool,
	access: Dictionary,
) -> Array:
	var sections: Array = _base_sections(view_return)
	var second: Dictionary = {
		"source_name": "player_alt",
		"product_type_ref": 0,
		"primary_key": second_pk,
		"indexes": [],
		"constraints": [],
		"table_access": access,
	}
	for section: Dictionary in sections:
		if section.has("Tables"):
			if second_first:
				section["Tables"].push_front(second)
			else:
				section["Tables"].append(second)
	return sections


# Two keyed tables on one row type naming DIFFERENT columns: the server's inference bails
# ("Ambiguous source table: keep the view without a primary key"), so this one must too.
func _test_query_view_ambiguous_source() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _sections_with_second_table(_query_return(), [1], false, { "Public": [] }) },
		"test_mod",
	)
	return _check_s(
		"an ambiguous source leaves the query view unkeyed",
		_find_table(schema, "player_view").get("primary_key_name", "<missing>"),
		"",
	)


# A table with NO key of its own does not count as the source — even when it is the first
# one the parser meets. The keyed table behind it is still what the view inherits.
func _test_query_view_unkeyed_source_first() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _sections_with_second_table(_query_return(), [], true, { "Public": [] }) },
		"test_mod",
	)
	return _check_s(
		"an unkeyed table is skipped, not taken as the source",
		_find_table(schema, "player_view").get("primary_key_name", "<missing>"),
		"id",
	)


# A view is public; the table it shares a row type with may be private and hidden from the
# generated code. The row type's own primary_key_name still names the hidden table's key,
# so reading it (rather than the surviving tables') keyed the view by a column that
# promises nothing about the view's rows.
func _test_hidden_private_table_does_not_key_a_view() -> int:
	var sections: Array = _base_sections(_procedural_return())
	for section: Dictionary in sections:
		if section.has("Tables"):
			section["Tables"][0]["table_access"] = { "Private": [] }
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": sections },
		"test_mod",
	)

	var tmp: String = "user://view_pk_private_gen"
	DirAccess.make_dir_recursive_absolute("%s/types" % tmp)
	DirAccess.make_dir_recursive_absolute("%s/tables" % tmp)
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = "test_mod"
	module_config.hide_private_tables = true
	module_config.hide_scheduled_reducers = false
	config.module_configs["test_mod"] = module_config
	var codegen: SpacetimeCodegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = config
	codegen._generate_gdscript_from_schema("test_mod", schema)

	var row_source: String = FileAccess.get_file_as_string("%s/types/test_mod_player.gd" % tmp)
	var f: int = 0
	f += _check_b("the row type was generated", not row_source.is_empty(), true)
	f += _check_b(
		"the hidden table's key is not spelled as the row type's",
		row_source.contains("const PRIMARY_KEY: StringName = &\"id\""),
		false,
	)

	# The same shape with a Query<T> view, where inheriting that key IS the rule: the view
	# reads the table, so it keeps the table's uniqueness even though the table is hidden.
	var query_sections: Array = _base_sections(_query_return())
	for section: Dictionary in query_sections:
		if section.has("Tables"):
			section["Tables"][0]["table_access"] = {"Private": []}
	var query_schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{"sections": query_sections}, "test_mod"
	)
	codegen = SpacetimeCodegen.new(tmp)
	codegen._plugin_config = config
	codegen._generate_gdscript_from_schema("test_mod", query_schema)
	var query_row_source: String = FileAccess.get_file_as_string("%s/types/test_mod_player.gd" % tmp)
	f += _check_b(
		"a query view over a hidden table keeps the inherited key",
		query_row_source.contains("const PRIMARY_KEY: StringName = &\"id\""),
		true,
	)
	return f


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

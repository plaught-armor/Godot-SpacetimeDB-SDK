# Namespaced submodules (SpacetimeDB 2.8.1+): what the PARSER produces for them.
#
# tests/golden/vsubmod/ already locks the emitted text, but a golden diff says "these bytes
# changed", not "this name is the one the server answers to". The distinction is the whole
# feature: a submodule's def carries a name that a GDScript identifier cannot spell
# (`lib.lib_data`), so every def now has two — the identifier its class, file and member are
# built from, and the dotted wire name every runtime lookup and every reducer call has to
# use. Swapping them produces bindings that parse, generate cleanly, and address nothing.
#
# The type-ref case is the other half. Each nested module numbers its own typespace from
# zero, and the fixture is shaped so that ignoring that does not fail loudly: the root's
# `RootPoint { x: u64 }` and `lib`'s `LibPoint { a: string, b: string }` both sit at index 1
# of their own module, so a parser that resolved the submodule's `Ref(1)` against the root
# typespace would bind `lib.lib_data.point` to `RootPoint` and decode two strings as a u64.
# (Measured: with the offset removed, that column comes back as `RootPoint`.)
#
# The fixture is a live capture from a 2.8.2 server (integration-tests/verify_submodule_module),
# and integration-tests/verify_live_submodule.gd runs the same shapes against a real one.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_submodule_schema.gd
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/vsubmod.json"
const MODULE: String = "vsubmod"

var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not (json is Dictionary):
		printerr("FAIL  fixture is not a JSON object")
		quit(1)
		return

	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(json, MODULE, { })
	if schema == null or schema.is_empty():
		printerr("FAIL  parse_schema returned empty")
		quit(1)
		return

	_check_sections_handled(schema)
	_check_table_names(schema)
	_check_reducer_names(schema)
	_check_type_refs(schema)
	_check_private_table_parsed(schema)
	_check_malformed_submodules()
	_check_namespace_paths_are_distinct()
	_check_multiple_typespace_sections()

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


func _table(schema: SpacetimeParsedSchema, identifier: String) -> Dictionary:
	for table: Dictionary in schema.tables:
		if table.get("name", "") == identifier:
			return table
	return { }


func _reducer(schema: SpacetimeParsedSchema, identifier: String) -> Dictionary:
	for reducer: Dictionary in schema.reducers:
		if reducer.get("name", "") == identifier:
			return reducer
	return { }


func _type(schema: SpacetimeParsedSchema, type_name: String) -> Dictionary:
	for type_def: Dictionary in schema.types:
		if type_def.get("name", "") == type_name:
			return type_def
	return { }


# `Submodules` is parsed now, so it must not also be reported as a section this SDK skipped
# — that report is what a caller reads to tell "unimplemented feature" from "codegen fault".
func _check_sections_handled(schema: SpacetimeParsedSchema) -> void:
	_check(
		"Submodules is no longer reported as a skipped section",
		schema.skipped_sections.is_empty(),
		str(schema.skipped_sections),
	)


func _check_table_names(schema: SpacetimeParsedSchema) -> void:
	var root: Dictionary = _table(schema, "root_thing")
	_check(
		"a root table is unchanged by the feature",
		(
			not root.is_empty() and root.get("wire_name", "") == "root_thing"
			and PackedStringArray(root.get("namespace", [])).is_empty()
		),
		str(root.get("wire_name", "<missing>")),
	)

	var lib: Dictionary = _table(schema, "lib_lib_data")
	_check(
		"a submodule table keeps identifier and wire name apart",
		(
			not lib.is_empty() and lib.get("wire_name", "") == "lib.lib_data"
			and lib.get("local_name", "") == "lib_data"
			and Array(lib.get("namespace", [])) == ["lib"]
		),
		str(lib.get("wire_name", "<missing>")),
	)

	var nested: Dictionary = _table(schema, "auth_baz_baz_items")
	_check(
		"a nested submodule table carries every namespace segment",
		(
			not nested.is_empty() and nested.get("wire_name", "") == "auth.baz.baz_items"
			and nested.get("local_name", "") == "baz_items"
			and Array(nested.get("namespace", [])) == ["auth", "baz"]
		),
		str(nested.get("wire_name", "<missing>")),
	)


func _check_reducer_names(schema: SpacetimeParsedSchema) -> void:
	var root: Dictionary = _reducer(schema, "root_insert")
	_check(
		"a root reducer is unchanged by the feature",
		not root.is_empty() and root.get("wire_name", "") == "root_insert",
		str(root.get("wire_name", "<missing>")),
	)

	var nested: Dictionary = _reducer(schema, "auth_baz_baz_insert")
	_check(
		"a nested submodule reducer is dispatched by its dotted name",
		(
			not nested.is_empty() and nested.get("wire_name", "") == "auth.baz.baz_insert"
			and nested.get("local_name", "") == "baz_insert"
		),
		str(nested.get("wire_name", "<missing>")),
	)


# The hazard: each module numbers its typespace from zero, so every index in one module
# names a different type in another. Each table must reach its OWN module's entry.
func _check_type_refs(schema: SpacetimeParsedSchema) -> void:
	var root_point: String = _column_type(schema, "root_thing", "point")
	_check(
		"the root table's column resolves against the root typespace",
		root_point == "RootPoint",
		root_point,
	)

	var lib_point: String = _column_type(schema, "lib_lib_data", "point")
	_check(
		"a submodule column resolves against its OWN typespace, not the root's",
		lib_point == "LibLibPoint",
		lib_point,
	)

	var lib_point_def: Dictionary = _type(schema, "LibLibPoint")
	var fields: PackedStringArray = []
	for field: Dictionary in lib_point_def.get("struct", []):
		fields.append("%s: %s" % [field.get("name", ""), field.get("type", "")])
	_check(
		"the submodule type it resolved to is the submodule's own shape",
		Array(fields) == ["a: String", "b: String"],
		str(fields),
	)


# Visibility is codegen's filter to apply (hide_private_tables), so the parser reports the
# private table like any other — with is_public false.
func _check_private_table_parsed(schema: SpacetimeParsedSchema) -> void:
	var secret: Dictionary = _table(schema, "lib_lib_secret")
	_check(
		"a private submodule table is parsed and marked private",
		not secret.is_empty() and not secret.get("is_public", true),
		"missing" if secret.is_empty() else "is_public=%s" % str(secret.get("is_public", true)),
	)


func _column_type(schema: SpacetimeParsedSchema, table_identifier: String, column: String) -> String:
	var table: Dictionary = _table(schema, table_identifier)
	if table.is_empty():
		return "<no table %s>" % table_identifier
	var type_idx: int = int(table.get("type_idx", -1))
	if type_idx < 0 or type_idx >= schema.types.size():
		return "<type_idx %d out of range>" % type_idx
	for field: Dictionary in schema.types[type_idx].get("struct", []):
		if field.get("name", "") == column:
			return String(field.get("type", ""))
	return "<no column %s>" % column


# One product type and one table over it — enough that a parse which drops everything is
# distinguishable from one that carried on. Mirrors tests/test_schema_unknown_section.gd.
func _minimal_root_sections() -> Array:
	return [
		{
			"Typespace": {
				"types": [
					{
						"Product": {
							"elements": [
								{ "name": { "some": "id" }, "algebraic_type": { "U64": [] } },
							],
						},
					},
				],
			},
		},
		{ "Types": [{ "source_name": { "scope": [], "source_name": "Widget" }, "ty": 0 }] },
		{
			"Tables": [
				{
					"source_name": "widget",
					"product_type_ref": 0,
					"primary_key": [0],
					"indexes": [],
					"constraints": [],
					"sequences": [],
					"table_type": { "User": [] },
					"table_access": { "Public": [] },
					"is_event": false,
				},
			],
		},
	]


func _submodule_entry(namespace_name: String, table_name: String) -> Dictionary:
	return {
		"namespace": namespace_name,
		"module": {
			"sections": [
				{
					"Typespace": {
						"types": [
							{
								"Product": {
									"elements": [
										{
											"name": { "some": "id" },
											"algebraic_type": { "U64": [] },
										},
									],
								},
							},
						],
					},
				},
				{ "Types": [{ "source_name": { "scope": [], "source_name": "SubRow" }, "ty": 0 }] },
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
						},
					],
				},
			],
		},
	}


# A schema the parser cannot fully read must SAY so: `incomplete` is what stops codegen
# writing a module short of a table, and its pruning pass then deleting that table's
# previous bindings. Each shape below is one a healthy server never sends — which is the
# point, since the schema arrives over HTTP from something that may be a proxy, a newer
# server, or a truncated response.
func _check_malformed_submodules() -> void:
	var duplicate: Array = _minimal_root_sections()
	duplicate.append(
		{ "Submodules": [_submodule_entry("lib", "one"), _submodule_entry("lib", "two")] },
	)
	var dup_schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": duplicate },
		MODULE,
		{ },
	)
	_check(
		"two submodules under one namespace: reported, first kept, parse incomplete",
		(
			dup_schema.incomplete and not _table(dup_schema, "lib_one").is_empty()
			and _table(dup_schema, "lib_two").is_empty()
		),
		"incomplete=%s tables=%d" % [str(dup_schema.incomplete), dup_schema.tables.size()],
	)

	var no_module: Array = _minimal_root_sections()
	no_module.append({ "Submodules": [{ "namespace": "lib" }] })
	var no_module_schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": no_module },
		MODULE,
		{ },
	)
	_check(
		"a submodule with no module definition is reported, not dropped in silence",
		no_module_schema.incomplete and not _table(no_module_schema, "widget").is_empty(),
		"incomplete=%s" % str(no_module_schema.incomplete),
	)

	var deep: Array = _minimal_root_sections()
	deep.append({ "Submodules": [_nested_chain(SpacetimeSchemaParser.MAX_SUBMODULE_DEPTH + 2)] })
	var deep_schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": deep },
		MODULE,
		{ },
	)
	_check(
		"submodules nested past the ceiling are reported, and the root still parses",
		deep_schema.incomplete and not _table(deep_schema, "widget").is_empty(),
		"incomplete=%s tables=%d" % [str(deep_schema.incomplete), deep_schema.tables.size()],
	)


# A chain of [param levels] submodules, each holding the next — the shape that walks the
# call stack down if nothing bounds it.
func _nested_chain(levels: int) -> Dictionary:
	var entry: Dictionary = { "namespace": "n%d" % levels, "module": { "sections": [] } }
	if levels > 1:
		entry["module"]["sections"] = [{ "Submodules": [_nested_chain(levels - 1)] }]
	return entry


# Namespaces are keyed by PATH, not by leaf segment: `a.lib` and `b.lib` are two different
# submodules and both must generate. The duplicate check above rejects a repeated path, and
# rejecting a repeated leaf instead would refuse a module the server is happy to serve.
func _check_namespace_paths_are_distinct() -> void:
	var sections: Array = _minimal_root_sections()
	sections.append(
		{
			"Submodules": [
				_wrapping_submodule("a", _submodule_entry("lib", "a_row")),
				_wrapping_submodule("b", _submodule_entry("lib", "b_row")),
			]
		}
	)
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": sections },
		MODULE,
		{ },
	)
	var a_row: Dictionary = _table(schema, "a_lib_a_row")
	var b_row: Dictionary = _table(schema, "b_lib_b_row")
	_check(
		"the same namespace name under two parents is two namespaces, not a duplicate",
		(
			not schema.incomplete and a_row.get("wire_name", "") == "a.lib.a_row"
			and b_row.get("wire_name", "") == "b.lib.b_row"
		),
		(
			"incomplete=%s a=%s b=%s"
			% [
				str(schema.incomplete),
				a_row.get("wire_name", "<missing>"),
				b_row.get("wire_name", "<missing>"),
			]
		),
	)


# A module holding nothing but [param child], so a namespace path can be built one level
# deeper without another table.
func _wrapping_submodule(namespace_name: String, child: Dictionary) -> Dictionary:
	return { "namespace": namespace_name, "module": { "sections": [{ "Submodules": [child] }] } }


# A module's types can arrive in more than one Typespace section. The content pass appends
# every one of them, so the offset the NEXT module's refs are shifted by has to count them
# all — taking only the last leaves a submodule's Ref pointing into the root's types, and
# the shapes here are close enough that it would decode rather than fail.
func _check_multiple_typespace_sections() -> void:
	var sections: Array = [
		{
			"Typespace": {
				"types": [
					{
						"Product": {
							"elements": [
								{ "name": { "some": "x" }, "algebraic_type": { "U64": [] } }
							],
						},
					},
				],
			},
		},
		{
			"Typespace": {
				"types": [
					{
						"Product": {
							"elements": [
								{ "name": { "some": "y" }, "algebraic_type": { "String": [] } }
							],
						},
					},
				],
			},
		},
		{
			"Types": [
				{ "source_name": { "scope": [], "source_name": "RootA" }, "ty": 0 },
				{ "source_name": { "scope": [], "source_name": "RootB" }, "ty": 1 },
			],
		},
		{
			"Tables": [
				{
					"source_name": "root_a",
					"product_type_ref": 0,
					"primary_key": [],
					"indexes": [],
					"constraints": [],
					"sequences": [],
					"table_type": { "User": [] },
					"table_access": { "Public": [] },
					"is_event": false,
				},
			],
		},
	]
	sections.append({ "Submodules": [_submodule_entry("lib", "lib_row")] })
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": sections },
		MODULE,
		{ },
	)
	var column: String = _column_type(schema, "lib_lib_row", "id")
	_check(
		"a module with two Typespace sections offsets the next module past both",
		not schema.incomplete and column == "U64",
		"incomplete=%s column=%s" % [str(schema.incomplete), column],
	)

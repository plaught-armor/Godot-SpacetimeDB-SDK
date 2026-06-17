# Parser test for view primary-key handling (SpacetimeDB v10 ViewPrimaryKeys).
#
# Guards two behaviours:
#   1. A query-builder view (return type = an existing table's row type) with NO
#      explicit ViewPrimaryKeys entry must NOT wipe the underlying table's primary
#      key. The view's row type is shared with the table, so dropping the PK there
#      kills row_updated detection for the table AND the view. The PK is inherited.
#   2. An explicit ViewPrimaryKeys entry sets the view row type's primary key.
#
# Builds minimal synthetic v10 schemas and runs them through
# SpacetimeSchemaParser.parse_schema, asserting the resolved type's primary key.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_view_primary_key.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_query_view_inherits_table_pk()
	fails += _test_explicit_view_pk()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# A U32 product type with two named fields (id, score), shared by a table and a
# query-builder view that returns Vec<that type>.
func _base_sections() -> Array:
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
		# Query<Player> view: return type is a Vec<Ref(0)> over the same row type.
		{ "Views": [{ "source_name": "player_view", "return_type": { "Array": { "Ref": 0 } } }] },
	]


func _find_type(schema: SpacetimeParsedSchema, type_name: String) -> Dictionary:
	for t: Dictionary in schema.types:
		if t.get("name", "") == type_name:
			return t
	return { }


# Case 1: no ViewPrimaryKeys — the table's PK ("id") must survive on the shared
# row type, and the view name must be registered alongside the table.
func _test_query_view_inherits_table_pk() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _base_sections() },
		"test_mod",
	)
	var f: int = 0
	var player: Dictionary = _find_type(schema, "Player")
	f += _check_b("type resolved", not player.is_empty(), true)
	f += _check_s("table PK preserved", player.get("primary_key_name", "<missing>"), "id")
	f += _check_b("view registered on row type", player.get("table_names", []).has("player_view"), true)
	return f


# Case 2: an explicit ViewPrimaryKeys entry naming "score" sets the view PK.
func _test_explicit_view_pk() -> int:
	var sections: Array = _base_sections()
	sections.append(
		{
			"ViewPrimaryKeys": [{ "view_source_name": "player_view", "columns": ["score"] }],
		},
	)
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": sections },
		"test_mod",
	)
	var f: int = 0
	var player: Dictionary = _find_type(schema, "Player")
	f += _check_s("explicit view PK applied", player.get("primary_key_name", "<missing>"), "score")
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

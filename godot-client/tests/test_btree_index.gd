# Parser test for btree (non-unique) index accessor generation.
#
# Guards the skip rule in SpacetimeSchemaParser.parse_schema:
#   - A single-column btree index produces a btree_indexes entry (→ filter()).
#   - A btree index whose column IS the primary key is skipped (find() covers it).
#   - A btree index whose column has a unique constraint is skipped (find() covers it).
#   - Multi-column btree indexes are skipped (single-column only for now).
#
# Builds a minimal synthetic v10 schema and asserts the resolved table's
# btree_indexes field. SpacetimeDB auto-creates a btree index for every PK and
# unique constraint, so without the skip rule those columns would gain a
# redundant filter() alongside their find().
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_btree_index.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_btree_skips_pk_and_unique()
	fails += _test_btree_skips_multicolumn()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# Circle row: entity_id (PK + unique), player_id (plain btree), mass (plain btree).
# SpacetimeDB emits a btree index for each, plus a unique constraint on entity_id.
func _circle_sections() -> Array:
	var row_type: Dictionary = {
		"Product": {
			"elements": [
				{ "name": { "some": "entity_id" }, "algebraic_type": { "U32": [] } },
				{ "name": { "some": "player_id" }, "algebraic_type": { "U32": [] } },
				{ "name": { "some": "mass" }, "algebraic_type": { "U32": [] } },
			],
		},
	}
	return [
		{ "Typespace": { "types": [row_type] } },
		{ "Types": [{ "source_name": { "scope": [], "source_name": "Circle" }, "ty": 0 }] },
		{
			"Tables": [
				{
					"source_name": "circle",
					"product_type_ref": 0,
					"primary_key": [0], # entity_id
					"indexes": [
						{ "source_name": { "some": "circle_entity_id_idx_btree" }, "accessor_name": { "some": "entity_id" }, "algorithm": { "BTree": [0] } },
						{ "source_name": { "some": "circle_player_id_idx_btree" }, "accessor_name": { "some": "player_id" }, "algorithm": { "BTree": [1] } },
						{ "source_name": { "some": "circle_mass_idx_btree" }, "accessor_name": { "some": "mass" }, "algorithm": { "BTree": [2] } },
					],
					"constraints": [
						{ "source_name": { "some": "circle_entity_id_key" }, "data": { "Unique": { "columns": [0] } } },
					],
				},
			],
		},
	]


func _find_table(schema: SpacetimeParsedSchema, table_name: String) -> Dictionary:
	for t: Dictionary in schema.tables:
		if t.get("name", "") == table_name:
			return t
	return { }


func _btree_field_names(table: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for idx: Dictionary in table.get("btree_indexes", []):
		names.append(idx.get("name", ""))
	return names


# entity_id is PK + unique → skipped; player_id + mass are plain btree → kept.
func _test_btree_skips_pk_and_unique() -> int:
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": _circle_sections() },
		"test_mod",
	)
	var f: int = 0
	var circle: Dictionary = _find_table(schema, "circle")
	f += _check_b("table resolved", not circle.is_empty(), true)
	var names: Array[String] = _btree_field_names(circle)
	f += _check_b("entity_id (PK+unique) skipped", names.has("entity_id"), false)
	f += _check_b("player_id btree kept", names.has("player_id"), true)
	f += _check_b("mass btree kept", names.has("mass"), true)
	f += _check_i("btree index count", names.size(), 2)
	return f


# A two-column btree index is skipped (single-column only).
func _test_btree_skips_multicolumn() -> int:
	var sections: Array = _circle_sections()
	sections[2]["Tables"][0]["indexes"].append(
		{ "source_name": { "some": "circle_pid_mass_idx_btree" }, "accessor_name": { "some": "player_id_mass" }, "algorithm": { "BTree": [1, 2] } },
	)
	var schema: SpacetimeParsedSchema = SpacetimeSchemaParser.parse_schema(
		{ "sections": sections },
		"test_mod",
	)
	var f: int = 0
	var circle: Dictionary = _find_table(schema, "circle")
	# Still only player_id + mass single-column indexes; the composite is dropped.
	f += _check_i("multicolumn btree dropped", _btree_field_names(circle).size(), 2)
	return f


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

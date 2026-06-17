# Test for SpacetimeDBQuery SQL generation, including the where_in (IN) and
# where_any (OR group) extensions. Asserts exact SQL strings + value escaping.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_query_builder.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

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

	f += _check(
		"plain select",
		SpacetimeDBQuery.table("player").to_sql(),
		"SELECT * FROM player",
	)

	f += _check(
		"eq + AND",
		SpacetimeDBQuery.table("player").where("online", true).where("level", 5).to_sql(),
		"SELECT * FROM player WHERE online = true AND level = 5",
	)

	f += _check(
		"comparison ops",
		SpacetimeDBQuery.table("e").where_gt("hp", 0).where_lte("hp", 100).where_ne("dead", true).to_sql(),
		"SELECT * FROM e WHERE hp > 0 AND hp <= 100 AND dead != true",
	)

	f += _check(
		"string escaping",
		SpacetimeDBQuery.table("u").where("name", "O'Brien").to_sql(),
		"SELECT * FROM u WHERE name = 'O''Brien'",
	)

	f += _check(
		"where_in",
		SpacetimeDBQuery.table("circle").where_in("player_id", [1, 2, 3]).to_sql(),
		"SELECT * FROM circle WHERE player_id IN (1, 2, 3)",
	)

	f += _check(
		"where_in strings",
		SpacetimeDBQuery.table("u").where_in("tag", ["a", "b"]).to_sql(),
		"SELECT * FROM u WHERE tag IN ('a', 'b')",
	)

	f += _check(
		"where_any OR group",
		SpacetimeDBQuery.table("e").where("alive", true).where_any([["kind", 1], ["kind", 2]]).to_sql(),
		"SELECT * FROM e WHERE alive = true AND (kind = 1 OR kind = 2)",
	)

	# Empty IN list → no-op (no invalid SQL emitted).
	f += _check(
		"empty where_in no-op",
		SpacetimeDBQuery.table("x").where_in("y", []).to_sql(),
		"SELECT * FROM x",
	)

	return f


func _check(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s\n  got:  %s\n  want: %s" % [label, got, want])
	return 1

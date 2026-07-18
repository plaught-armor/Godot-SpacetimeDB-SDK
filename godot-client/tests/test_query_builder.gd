# Test for SpacetimeDBQuery SQL generation, including the where_in (IN) and
# where_any (OR group) extensions. Asserts exact SQL strings + value escaping.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_query_builder.gd
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
		SpacetimeDBQuery
		.table("e")
		.where_gt("hp", 0)
		.where_lte("hp", 100)
		.where_ne("dead", true)
		.to_sql(),
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
		SpacetimeDBQuery
		.table("e")
		.where("alive", true)
		.where_any([["kind", 1], ["kind", 2]])
		.to_sql(),
		"SELECT * FROM e WHERE alive = true AND (kind = 1 OR kind = 2)",
	)

	# Empty IN list → no-op (no invalid SQL emitted).
	f += _check(
		"empty where_in no-op",
		SpacetimeDBQuery.table("x").where_in("y", []).to_sql(),
		"SELECT * FROM x",
	)

	# StringName value must be quoted + escaped exactly like String (was an
	# injection hole — StringName fell through to raw str()).
	f += _check(
		"StringName escaping",
		SpacetimeDBQuery.table("e").where("state", &"a'; DROP--").to_sql(),
		"SELECT * FROM e WHERE state = 'a''; DROP--'",
	)
	f += _check(
		"StringName in where_in",
		SpacetimeDBQuery.table("e").where_in("state", [&"alive", &"dead"]).to_sql(),
		"SELECT * FROM e WHERE state IN ('alive', 'dead')",
	)

	# Invalid identifier → condition skipped (no malformed ` = value` fragment).
	# push_error is expected on stderr for these.
	f += _check(
		"invalid identifier skipped",
		SpacetimeDBQuery.table("t").where("bad name", 5).where("ok", 1).to_sql(),
		"SELECT * FROM t WHERE ok = 1",
	)
	# null value → NULL literal (push_error), not the old injectable "<null>".
	f += _check(
		"null value → NULL",
		SpacetimeDBQuery.table("t").where("x", null).to_sql(),
		"SELECT * FROM t WHERE x = NULL",
	)

	# from(null) must return null, not crash.
	_total += 1
	if SpacetimeDBQuery.from(null) == null:
		print("PASS  from(null) → null")
	else:
		printerr("FAIL  from(null) should return null")
		f += 1

	return f


func _check(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s\n  got:  %s\n  want: %s" % [label, got, want])
	return 1

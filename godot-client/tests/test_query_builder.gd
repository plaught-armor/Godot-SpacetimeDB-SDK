# Test for SpacetimeDBQuery SQL generation, including the where_in and where_any OR
# groups. Asserts exact SQL strings + value escaping.
#
# Both of those emit OR groups rather than `IN (...)`: SpacetimeDB's expression parser
# (the same one behind a subscription and a one-off query) accepts comparisons joined by
# AND / OR and rejects everything else, so an emitted IN failed the whole query set. The
# strings asserted here are what the server actually parses.
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

	# An OR group, not `IN (...)`: SpacetimeDB's expression parser has no IN operator,
	# and an emitted one came back as an unsupported expression that failed the whole
	# query set. Same meaning, and it parses.
	f += _check(
		"where_in expands to an OR group",
		SpacetimeDBQuery.table("circle").where_in("player_id", [1, 2, 3]).to_sql(),
		"SELECT * FROM circle WHERE (player_id = 1 OR player_id = 2 OR player_id = 3)",
	)

	f += _check(
		"where_in strings",
		SpacetimeDBQuery.table("u").where_in("tag", ["a", "b"]).to_sql(),
		"SELECT * FROM u WHERE (tag = 'a' OR tag = 'b')",
	)

	# A single value still parenthesises, so it AND-joins with its neighbours safely.
	f += _check(
		"where_in with one value",
		SpacetimeDBQuery.table("u").where("live", true).where_in("tag", ["a"]).to_sql(),
		"SELECT * FROM u WHERE live = true AND (tag = 'a')",
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

	# Empty value list → no-op (no dangling `()` fragment).
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
		"SELECT * FROM e WHERE (state = 'alive' OR state = 'dead')",
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

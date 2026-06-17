# Runtime test for LocalDatabase query helpers: find_by / first_by / find_where /
# count_where. These back the generated table find_*() methods AND the btree index
# filter() accessor (which delegates to find_by), so this guards the scan contract
# the non-unique index API rides on: multiple matches returned, no match → empty,
# and results track live state after a row is removed.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_local_query.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


# Minimal row with a non-unique column (player_id) — mirrors a btree-indexed table
# like Blackholio's `circle` without coupling the test to generated bindings.
class _TestRow:
	extends _ModuleTableType
	@export var entity_id: int = 0
	@export var player_id: int = 0


	static func make(p_entity: int, p_player: int) -> _TestRow:
		var r: _TestRow = _TestRow.new()
		r.entity_id = p_entity
		r.player_id = p_player
		return r


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	# No disk schema → circle resolves as PK-less, so rows live in _pk_less_tables
	# and the helpers take the array-scan path (the same path filter() exercises).
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"circle"]
	var db: LocalDatabase = LocalDatabase.new(schema)

	# Three circles: player_id 1, 1, 2.
	db._pk_less_tables[&"circle"] = [
		_TestRow.make(10, 1),
		_TestRow.make(11, 1),
		_TestRow.make(12, 2),
	]

	var f: int = 0

	# find_by: non-unique column returns every match.
	f += _check_i("find_by player 1 → 2 rows", db.find_by(&"circle", &"player_id", 1).size(), 2)
	f += _check_i("find_by player 2 → 1 row", db.find_by(&"circle", &"player_id", 2).size(), 1)
	f += _check_i("find_by player 99 → 0 rows", db.find_by(&"circle", &"player_id", 99).size(), 0)

	# first_by: first match or null.
	var first: _ModuleTableType = db.first_by(&"circle", &"player_id", 2)
	f += _check_b("first_by player 2 non-null", first != null, true)
	f += _check_i("first_by player 2 entity_id", first.get(&"entity_id"), 12)
	f += _check_b("first_by player 99 null", db.first_by(&"circle", &"player_id", 99) == null, true)

	# count_where: predicate count.
	f += _check_i("count_where player==1", db.count_where(&"circle", _is_player_one), 2)

	# Scan tracks live state: remove an entity 11 (player 1) → find_by player 1 drops to 1.
	var rows: Array = db._pk_less_tables[&"circle"]
	rows.remove_at(1)
	f += _check_i("find_by player 1 after removal → 1 row", db.find_by(&"circle", &"player_id", 1).size(), 1)

	db.free()
	return f


func _is_player_one(row: _ModuleTableType) -> bool:
	return row.get(&"player_id") == 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

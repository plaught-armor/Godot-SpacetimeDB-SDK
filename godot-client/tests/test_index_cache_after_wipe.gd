# Regression test: a silent cache wipe must not leave the generated index caches holding
# rows the mirror no longer has.
#
# The unique and btree index accessors keep their caches current through LocalDatabase's
# insert/update/delete listeners. clear_local_db() reports a delete per row, so those
# listeners empty the caches with it. clear_all_tables() reports NOTHING — that is its
# documented contract, and a game's own listeners going stale is its documented cost — so
# the caches kept every row: measured, find()/filter()/the range queries answered with
# rows get_all_rows() no longer yielded, for the rest of the session, with no way for the
# caller to rebuild them (they are private to the SDK).
#
# Driven through the real generated Blackholio bindings, so what is pinned is what a game
# calls (find_by_entity_id / find_by_player_id / filter_range), not just the base class.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_index_cache_after_wipe.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
## Re-entrancy scenario state. Members rather than locals a lambda would capture by value.
var _reentrant_fires: int = 0
var _reentrant_db: LocalDatabase = null
## Times the invalidator registered from inside the fire loop has been called.
var _late_fires: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_silent_wipe_empties_the_indexes()
	fails += _test_reporting_wipe_still_empties_the_indexes()
	fails += _test_indexes_work_again_after_a_silent_wipe()
	fails += _test_freed_index_owner_does_not_break_the_wipe()
	fails += _test_reentrant_wipe_terminates()
	fails += _test_registering_during_the_fire_waits_for_the_next_wipe()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)

# --- Scenarios ---


# The bug: clear_all_tables() emptied the storage and left both index caches full.
func _test_silent_wipe_empties_the_indexes() -> int:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var table: BlackholioCircleTable = BlackholioCircleTable.new(db)
	_seed(db)

	var f: int = 0
	f += _check_i("seeded: rows in the mirror", table.count(), 3)
	f += _check_i("seeded: unique find", table.find_by_entity_id(1).size(), 1)
	f += _check_i("seeded: btree filter", table.find_by_player_id(7).size(), 2)

	db.clear_all_tables()

	f += _check_i("after the wipe: mirror empty", table.count(), 0)
	f += _check_i("after the wipe: iter empty", table.iter().size(), 0)
	f += _check_b("after the wipe: unique first is null", table.first_by_entity_id(1) == null, true)
	f += _check_i("after the wipe: unique find empty", table.find_by_entity_id(1).size(), 0)
	f += _check_b("after the wipe: btree first is null", table.first_by_player_id(7) == null, true)
	f += _check_i("after the wipe: btree filter empty", table.find_by_player_id(7).size(), 0)
	f += _check_i(
		"after the wipe: btree range empty",
		table.player_id.filter_range(0, 100).size(),
		0,
	)
	# The sorted-key mirror is what the range queries binary-search; a bucket cleared
	# without it would leave every range query walking keys with no buckets behind them.
	f += _check_i("after the wipe: btree gte empty", table.player_id.filter_gte(0).size(), 0)
	f += _check_i("after the wipe: btree lte empty", table.player_id.filter_lte(100).size(), 0)
	db.free()
	return f


# The reporting wipe was already correct (the delete listeners do the work). Pinned so a
# later change to the invalidation path cannot regress it in the other direction.
func _test_reporting_wipe_still_empties_the_indexes() -> int:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var table: BlackholioCircleTable = BlackholioCircleTable.new(db)
	_seed(db)

	var f: int = 0
	db.clear_local_db()
	f += _check_i("clear_local_db: mirror empty", table.count(), 0)
	f += _check_i("clear_local_db: unique find empty", table.find_by_entity_id(1).size(), 0)
	f += _check_i("clear_local_db: btree filter empty", table.find_by_player_id(7).size(), 0)
	f += _check_i(
		"clear_local_db: btree range empty",
		table.player_id.filter_range(0, 100).size(),
		0,
	)
	db.free()
	return f


# An emptied cache must still be a working one: the wipe drops the buckets and the sorted
# keys, and the next delivery has to rebuild both. Clearing the multimap while leaving a
# stale _sorted_keys would pass every assertion above and fail here.
func _test_indexes_work_again_after_a_silent_wipe() -> int:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var table: BlackholioCircleTable = BlackholioCircleTable.new(db)
	_seed(db)
	db.clear_all_tables()
	_apply(db, [_circle(9, 5)], [])

	var f: int = 0
	f += _check_i("rebuilt: mirror", table.count(), 1)
	f += _check_b("rebuilt: unique find", table.first_by_entity_id(9) != null, true)
	f += _check_i("rebuilt: btree filter", table.find_by_player_id(5).size(), 1)
	f += _check_i("rebuilt: btree range", table.player_id.filter_range(0, 100).size(), 1)
	# The wiped keys must not still be answering.
	f += _check_b("rebuilt: old unique key gone", table.first_by_entity_id(1) == null, true)
	f += _check_i("rebuilt: old btree key gone", table.find_by_player_id(7).size(), 0)
	db.free()
	return f


# The invalidators are Callables on the index Resources. An index whose owner has been
# released must not make the wipe fault: a GDScript runtime error unwinds the whole
# function, so clear_all_tables() would stop half done — containers cleared, later
# invalidators never called.
func _test_freed_index_owner_does_not_break_the_wipe() -> int:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var doomed: BlackholioCircleTable = BlackholioCircleTable.new(db)
	# How many invalidators one table wrapper registers, read rather than restated: it is
	# one per index the schema declares for `circle`, and an index added there for an
	# unrelated reason must not break this test.
	var per_table: int = db._index_invalidators.size()
	var survivor: BlackholioCircleTable = BlackholioCircleTable.new(db)
	_seed(db)
	# Releasing the doomed wrapper's indexes drops its whole share of the list.
	doomed.entity_id = null
	doomed.player_id = null

	var f: int = 0
	db.clear_all_tables()
	f += _check_i("freed owner: mirror empty", survivor.count(), 0)
	f += _check_i(
		"freed owner: survivor unique find empty",
		survivor.find_by_entity_id(1).size(),
		0,
	)
	f += _check_i(
		"freed owner: survivor btree filter empty",
		survivor.find_by_player_id(7).size(),
		0,
	)
	# The dead entries are dropped as they are met, not left to be walked every wipe.
	f += _check_i("freed owner: invalidators pruned", db._index_invalidators.size(), per_table)
	db.free()
	return f


# An invalidator that wipes again re-enters clear_all_tables(). The list of invalidators
# is a registry no wipe empties, so without a stop condition the nested call re-fires every
# entry — including the one that re-entered — and the descent is unbounded (measured 12
# calls for 3 invalidators before the fire was gated on this call being the one that
# dropped the rows; uncapped it overflows the stack). The two shipped invalidators are leaf
# functions and cannot reach this, but register_index_invalidator() is public.
func _test_reentrant_wipe_terminates() -> int:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var table: BlackholioCircleTable = BlackholioCircleTable.new(db)
	_seed(db)
	# A member, not a captured local: a lambda captures locals by value (#69014), so a
	# counter incremented inside one reads 0 out here and the assertion passes blind.
	_reentrant_fires = 0
	_reentrant_db = db
	db.register_index_invalidator(_wipe_again)

	var f: int = 0
	db.clear_all_tables()
	f += _check_i("re-entrant wipe: invalidator fired once", _reentrant_fires, 1)
	f += _check_i("re-entrant wipe: mirror still empty", table.count(), 0)
	f += _check_i("re-entrant wipe: index still empty", table.find_by_entity_id(1).size(), 0)
	# A second wipe of an already-empty database drops nothing, so it fires nothing: that
	# is the same gate, seen from the top rather than from inside the recursion.
	db.clear_all_tables()
	f += _check_i("wipe of an empty database fires nothing", _reentrant_fires, 1)
	_reentrant_db = null
	db.free()
	return f


func _wipe_again() -> void:
	_reentrant_fires += 1
	if _reentrant_db != null:
		_reentrant_db.clear_all_tables()


# The fire walks a COPY of the invalidator list. Registering from inside an invalidator is
# what that copy is for: `for x in array` iterates against the live size, so an append made
# during the walk would extend the walk and fire the newcomer in the same pass — an
# invalidator running before the wipe that registered it has finished. The freed-owner
# scenario above does NOT discriminate here (it frees before the call, and the fire's own
# is_valid() check covers a mid-walk free either way), so this is the assertion that pins
# the duplicate(): with it reverted the late invalidator fires during the first wipe.
func _test_registering_during_the_fire_waits_for_the_next_wipe() -> int:
	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var table: BlackholioCircleTable = BlackholioCircleTable.new(db)
	var per_table: int = db._index_invalidators.size()
	_seed(db)
	_late_fires = 0
	_reentrant_db = db
	db.register_index_invalidator(_register_late)

	var f: int = 0
	db.clear_all_tables()
	f += _check_i("late invalidator did not fire in the wipe that added it", _late_fires, 0)
	# The table's own share, plus _register_late, plus the one it registered mid-fire.
	f += _check_i("late invalidator is registered", db._index_invalidators.size(), per_table + 2)

	# The next wipe that drops rows is where it belongs, so the registration is not lost.
	_seed(db)
	db.clear_all_tables()
	f += _check_i("late invalidator fires on the next wipe", _late_fires, 1)
	f += _check_i("still empty after the second wipe", table.find_by_player_id(7).size(), 0)
	_reentrant_db = null
	db.free()
	return f


func _register_late() -> void:
	if _reentrant_db != null:
		_reentrant_db.register_index_invalidator(_late_invalidator)


func _late_invalidator() -> void:
	_late_fires += 1

# --- Helpers ---


# Three circles: entity ids 1/2/3, player 7 holding two of them and player 8 one.
func _seed(db: LocalDatabase) -> void:
	_apply(db, [_circle(1, 7), _circle(2, 7), _circle(3, 8)], [])


func _circle(entity_id: int, player_id: int) -> BlackholioCircle:
	return BlackholioCircle.create(
		entity_id,
		player_id,
		BlackholioDbVector2.create(0.0, 0.0),
		1.0,
		0,
	)


func _apply(db: LocalDatabase, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"circle"
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	db.apply_table_update(u)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %d, want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
	return 1

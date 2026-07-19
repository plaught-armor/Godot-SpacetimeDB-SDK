# Reads the generated index accessors against a live server.
#
# The btree index (a multimap cache, shipped in v2.5.0) and the unique indexes are
# pure client state: they are built from insert/update/delete callbacks off
# LocalDatabase, so no captured wire fixture can exercise them. Everything that has
# tested them so far fed the cache synthetic rows. What was never checked is the
# thing a game does — subscribe, cause real row churn, and read back through
# `db.<table>.<column>.find()/filter()`.
#
# The module already carries both index kinds: circle.player_id is #[index(btree)]
# and player.player_id is #[unique] #[auto_inc], so no module change is needed.
#
#   spacetime start ... && cd blackholio-server && ./publish.sh
#   cd godot-client && GODOT=/path/to/godot tests/_live_index.sh
#   echo $?   # number of failed checks
#
# Run it through that driver rather than on its own: it starts a second client, so
# the btree holds more than one key and the range accessors have a window to
# search. This harness fails on purpose if it finds a single-player world.
#
# Every index read is asserted against a linear iter() scan of the same table: the
# scan is the ground truth, the index is the thing under test. Underscore-prefixed
# so run_tests.sh skips it; the suite must stay runnable with no server.
extends Node

## Name this client enters the game under.
const PLAYER_NAME: String = "IndexProbe"
## Covers connect, the connect lifecycle reducer, enter_game and the first circle.
const SPAWN_TIMEOUT: float = 30.0
## Row churn after a reducer settles is a round trip, not a spawn.
const CHURN_TIMEOUT: float = 10.0
## Every reducer here is a local round trip.
const REDUCER_TIMEOUT: float = 10.0

# C1: never const a Packed*Array.
var _queries: PackedStringArray = ["SELECT * FROM player", "SELECT * FROM circle"]
var _fails: int = 0
var _total: int = 0
var _identity: PackedByteArray
var _circle_updates: int = 0
var _circles: BlackholioCircleTable
var _players: BlackholioPlayerTable
var _btree: BlackholioCirclePlayerIdBTreeIndex


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	# A fresh identity every run, so a leftover player row from an earlier run cannot
	# make a check pass that should have failed.
	options.one_time_token = true
	options.save_token = false
	SpacetimeDB.Blackholio.connected.connect(_run, CONNECT_ONE_SHOT)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


func _run(identity: PackedByteArray, _token: String) -> void:
	_identity = identity
	_circles = SpacetimeDB.Blackholio.db.circle
	_players = SpacetimeDB.Blackholio.db.player
	_btree = _circles.player_id

	var sub: SpacetimeDBSubscription = SpacetimeDB.Blackholio.subscribe(_queries)
	_check("subscribed to player + circle", await sub.wait_for_applied(10.0) == OK, true)
	_circles.updated.connect(_on_circle_updated)

	# enter_game needs the player row the module's connect lifecycle reducer makes.
	await get_tree().create_timer(1.0).timeout
	var entered: bool = await _call_reducer(
		"enter_game",
		SpacetimeDB.Blackholio.reducers.enter_game(PLAYER_NAME),
	)
	if not entered:
		_finish()
		return

	var ready_in_time: bool = await _wait_until(_own_rows_present, SPAWN_TIMEOUT)
	_check("own player and circle arrived within %.0fs" % SPAWN_TIMEOUT, ready_in_time, true)
	var scanned: BlackholioPlayer = _scan_own_player()
	if scanned == null:
		_finish()
		return

	_check_unique_indexes(scanned)
	await _check_btree_reads(scanned.player_id)
	_finish()


func _on_circle_updated(_old_row: BlackholioCircle, _new_row: BlackholioCircle) -> void:
	_circle_updates += 1

# --- unique indexes -----------------------------------------------------------


## Both of player's unique indexes must resolve to the same row object the scan
## found — not merely a row with equal fields, since the cache stores references and
## a duplicate would mean the index is rebuilding rows behind the caller's back.
##
## Note this lands on the unique index's UPDATE path, not its insert path: the
## module's connect lifecycle reducer inserts the player row first and enter_game
## then updates it with the name, so the row these reads return is the one the
## update listener stored.
func _check_unique_indexes(scanned: BlackholioPlayer) -> void:
	var pid: int = scanned.player_id
	var by_identity: BlackholioPlayer = _players.identity.find(_identity)
	var by_pid: BlackholioPlayer = _players.player_id.find(pid)
	_check("player.identity.find is the scanned row", by_identity == scanned, true)
	_check("player.player_id.find is the scanned row", by_pid == scanned, true)
	# A null here is the sharpest failure this harness exists to catch, so read the
	# row only once it is known to be there — a crash would replace the fail count
	# with a stack trace.
	if by_identity != null:
		_check("player.identity.find carries the name", by_identity.name, PLAYER_NAME)

	# A miss has to be a miss: an index that returned something for an absent key
	# would have made every check above pass by accident.
	var absent: PackedByteArray = _identity.duplicate()
	absent[0] = absent[0] ^ 0xFF
	var identity_miss: bool = _players.identity.find(absent) == null
	var pid_miss: bool = _players.player_id.find(-pid - 1) == null
	_check("player.identity.find misses an absent key", identity_miss, true)
	_check("player.player_id.find misses an absent key", pid_miss, true)

# --- btree index --------------------------------------------------------------


## circle.player_id is the only non-unique index in the module, so it is the only
## place the multimap cache and its sorted-key list are exercised for real.
func _check_btree_reads(pid: int) -> void:
	var scanned: Array[BlackholioCircle] = _scan_circles(pid)
	_check("the scan found at least one own circle", scanned.size() >= 1, true)
	# With one player in the world every range accessor returns either that single
	# bucket or nothing, and the sorted-key window is never really searched. Fail
	# rather than report a green run that proved nothing — _live_index.sh puts a
	# second client in the world for exactly this.
	_check("the world holds more than one player_id", _distinct_player_ids() >= 2, true)

	var filtered: Array[BlackholioCircle] = _btree.filter(pid) # gdlint: ignore[C3]
	var miss: Array[BlackholioCircle] = _btree.filter(-pid - 1) # gdlint: ignore[C3]
	_check("circle.player_id.filter matches the scan", _ids(filtered), _ids(scanned))
	_check("circle.player_id.filter misses an absent key", miss.is_empty(), true)

	_check_ranges(pid)
	await _check_update_path(pid)
	await _check_delete_path(pid)


## Every bound accessor is checked against the same scan, so a wrong bsearch window
## (the easy way to get these off by one) shows up as a mismatched id list.
func _check_ranges(pid: int) -> void:
	var gte: PackedInt32Array = _ids(_btree.filter_gte(pid))
	var gt: PackedInt32Array = _ids(_btree.filter_gt(pid))
	var lte: PackedInt32Array = _ids(_btree.filter_lte(pid))
	var lt: PackedInt32Array = _ids(_btree.filter_lt(pid))
	var only_pid: PackedInt32Array = _ids(_btree.filter_range(pid, pid))
	_check("filter_gte(pid)", gte, _ids(_scan_where_pid_gte(pid)))
	_check("filter_gt(pid) excludes pid", gt, _ids(_scan_where_pid_gte(pid + 1)))
	_check("filter_lte(pid)", lte, _ids(_scan_where_pid_lte(pid)))
	_check("filter_lt(pid) excludes pid", lt, _ids(_scan_where_pid_lte(pid - 1)))
	_check("filter_range(pid, pid) is just pid", only_pid, _ids(_scan_circles(pid)))
	# Another player's key sits on one side of pid or the other. If neither strict
	# bound returned anything, both windows were empty and the bounds proved nothing.
	_check("a strict bound spans another player's key", gt.size() + lt.size() >= 1, true)


## An update moves a row instance in the cache. A bucket that appended instead of
## swapping would still hold the stale row, so the row count is the tell.
func _check_update_path(pid: int) -> void:
	var direction: BlackholioDbVector2 = BlackholioDbVector2.create(1.0, 0.0)
	var settled: bool = await _call_reducer(
		"update_player_input",
		SpacetimeDB.Blackholio.reducers.update_player_input(direction),
	)
	if not settled:
		return

	var updated: bool = await _wait_until(_saw_circle_update, CHURN_TIMEOUT)
	_check("a circle update arrived", updated, true)

	var filtered: Array[BlackholioCircle] = _btree.filter(pid) # gdlint: ignore[C3]
	var scanned: Array[BlackholioCircle] = _scan_circles(pid)
	_check("filter still matches the scan after an update", _ids(filtered), _ids(scanned))
	_check("the filtered rows are the live instances", _same_rows(filtered, scanned), true)


## The delete path empties a bucket and unregisters its key, which is the one edge
## the range accessors read through _sorted_keys. suicide() destroys every circle
## this player owns.
func _check_delete_path(pid: int) -> void:
	var settled: bool = await _call_reducer("suicide", SpacetimeDB.Blackholio.reducers.suicide())
	if not settled:
		return

	var gone: bool = await _wait_until(_own_circles_gone.bind(pid), CHURN_TIMEOUT)
	_check("the scan lost every own circle", gone, true)

	var filtered: Array[BlackholioCircle] = _btree.filter(pid) # gdlint: ignore[C3]
	_check("filter is empty after the delete", filtered.is_empty(), true)
	# If the emptied key stayed in _sorted_keys, the ranges spanning it would still
	# gather the dead rows — or fault on a bucket that is no longer there.
	_check(
		"filter_gte dropped the deleted rows",
		_ids(_btree.filter_gte(pid)),
		_ids(_scan_where_pid_gte(pid)),
	)
	_check(
		"filter_lte dropped the deleted rows",
		_ids(_btree.filter_lte(pid)),
		_ids(_scan_where_pid_lte(pid)),
	)

# --- scans (the ground truth every index read is compared against) -------------


func _scan_circles(pid: int) -> Array[BlackholioCircle]:
	var out: Array[BlackholioCircle] = []
	for row: BlackholioCircle in _circles.iter():
		if row.player_id == pid:
			out.append(row)
	return out


func _scan_where_pid_gte(pid: int) -> Array[BlackholioCircle]:
	var out: Array[BlackholioCircle] = []
	for row: BlackholioCircle in _circles.iter():
		if row.player_id >= pid:
			out.append(row)
	return out


func _scan_where_pid_lte(pid: int) -> Array[BlackholioCircle]:
	var out: Array[BlackholioCircle] = []
	for row: BlackholioCircle in _circles.iter():
		if row.player_id <= pid:
			out.append(row)
	return out


## How many distinct keys the btree cache should be holding.
func _distinct_player_ids() -> int:
	var seen: Dictionary[int, bool] = { }
	for row: BlackholioCircle in _circles.iter():
		seen[row.player_id] = true
	return seen.size()


func _scan_own_player() -> BlackholioPlayer:
	for row: BlackholioPlayer in _players.iter():
		if row.identity == _identity:
			return row
	return null

# --- predicates for _wait_until -----------------------------------------------


func _own_rows_present() -> bool:
	var mine: BlackholioPlayer = _scan_own_player()
	if mine == null:
		return false
	return not _scan_circles(mine.player_id).is_empty()


func _own_circles_gone(pid: int) -> bool:
	return _scan_circles(pid).is_empty()


func _saw_circle_update() -> bool:
	return _circle_updates > 0

# --- helpers ------------------------------------------------------------------


## Sorted entity ids, so two row lists compare regardless of bucket order.
func _ids(rows: Array[BlackholioCircle]) -> PackedInt32Array:
	var out: PackedInt32Array = []
	for row: BlackholioCircle in rows:
		out.append(row.entity_id)
	out.sort()
	return out


## True when both lists hold the same row objects, not merely equal ids.
func _same_rows(a: Array[BlackholioCircle], b: Array[BlackholioCircle]) -> bool:
	if a.size() != b.size():
		return false
	for row: BlackholioCircle in a:
		if not b.has(row):
			return false
	return true


## Awaits a reducer call and reports its outcome. Returns false when it did not
## settle OK, so the caller can stop instead of asserting on rows that never came.
func _call_reducer(label: String, call: SpacetimeDBReducerCall) -> bool:
	var settled: SpacetimeDBReducerCall = await call.wait_for_response(REDUCER_TIMEOUT)
	_check("%s succeeded" % label, settled.outcome, SpacetimeDBReducerCall.Outcome.OK)
	return settled.outcome == SpacetimeDBReducerCall.Outcome.OK


## Polls [param predicate] until it returns true or [param timeout] elapses.
func _wait_until(predicate: Callable, timeout: float) -> bool:
	var deadline: SceneTreeTimer = get_tree().create_timer(timeout)
	while deadline.time_left > 0.0:
		if predicate.call():
			return true
		await get_tree().process_frame
	return predicate.call()


func _finish() -> void:
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	get_tree().quit(_fails)


func _check(label: String, got: Variant, want: Variant) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1

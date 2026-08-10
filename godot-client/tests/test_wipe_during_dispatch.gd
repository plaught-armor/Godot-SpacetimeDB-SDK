# Regression test: a cache wipe that happens INSIDE a row callback must not leave the
# rest of that batch behind in the mirror.
#
# apply_table_update hoists its containers into locals before it dispatches, and every
# listener call is game code. clear_local_db() empties the INNER containers of _tables /
# _pk_less_tables (those locals stay live) but clears the OUTER maps of _ref_counts /
# _pk_less_counts (those locals detach), so a batch that carried on after the wipe wrote
# rows into the live mirror and their refcounts into a dictionary nothing reads any more.
# Measured before the fix: the rows the rest of the batch inserted were cached with NO
# refcount — the state the refcount paths treat as impossible. A later delete read 0 and
# skipped, so those rows never left the mirror and no on_delete ever fired, and on the
# PK-less side every re-delivery cached another copy.
#
# Reachable from game code that restarts the session out of a row handler
# (disconnect_db() then connect_db(), which wipes synchronously) — see
# tests/_probe_reentrant_clear_client.gd, which drives a real SpacetimeDBClient.
#
# Asserts:
#   - the batch is abandoned at the wipe on both table shapes (PK and PK-less),
#   - the mirror's rows and its refcount containers agree afterwards (the invariant that
#     was broken: every cached row has a refcount, every refcount has a cached row),
#   - a row the wiped batch would have stranded is not there to be re-delivered twice,
#     and a later delete leaves nothing behind,
#   - no transactions_completed is reported for the abandoned batch,
#   - a multi-table update stops at the wipe instead of applying the later tables,
#   - an event-table batch stops too,
#   - a wipe from inside the wipe's OWN delete callback reports each row once, not twice,
#   - prune_query stops instead of rebuilding membership for a query the wipe forgot,
#   - the ordinary (unwiped) paths are untouched.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_wipe_during_dispatch.gd
#
# Exit code = number of failed cases (0 = all pass).

extends SceneTree

## Loaded by path rather than named: a --script main loop compiles before autoloads
## register, and the client script is what the addon's autoload is built from.
const CLIENT_SCRIPT: String = "res://addons/SpacetimeDB/core/spacetimedb_client.gd"

var _total: int = 0
var _db: LocalDatabase
## Value/pk whose insert callback wipes the mirror; -1 disables.
var _wipe_on_pk: int = -1
var _wipe_on_value: int = -1
var _wipes: int = 0
var _tx_completed: int = 0
var _deleted_pks: PackedInt32Array = []
var _deleted_values: PackedInt32Array = []


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	f += _test_pk_batch_abandoned()
	f += _test_pk_less_batch_abandoned()
	f += _test_multi_table_update_stops()
	f += _test_event_batch_stops()
	f += _test_wipe_inside_the_wipe()
	f += _test_prune_stops_at_wipe()
	f += _test_wipe_from_a_delete_callback()
	f += _test_wipe_from_before_delete()
	f += _test_clear_all_tables_also_stops_a_batch()
	f += _test_subscribe_applied_stops()
	f += _test_pk_less_delete_arm_stops()
	f += _test_client_transaction_loop_stops()
	f += _test_client_loop_survives_clear_all_tables()
	f += _test_silent_wipe_still_terminates()
	f += _test_pk_delete_pass_terminates()
	f += _test_multi_table_message_survives_clear_all_tables()
	f += _test_unwiped_paths_unchanged()
	if _db != null:
		_db.free()
		_db = null
	return f


# The PK-less delete arm, wiped from a row_deleted callback. Those rows are already out
# of the row array by then, so the wipe's own snapshot cannot report them — this loop is
# their only record and must run to the end. Every before_delete owes a delete.
func _test_wipe_from_a_delete_callback() -> int:
	var f: int = 0
	_fresh()
	var before: Array[int] = [] # gdlint: ignore[S6]
	var gone: Array[int] = [] # gdlint: ignore[S6]
	var wiped: Array[int] = [0] # gdlint: ignore[S6]
	_db.subscribe_to_transactions_completed(&"flat", _on_tx_completed)
	_db.subscribe_to_before_deletes(
		&"flat",
		func(row: _ModuleTableType) -> void:
			before.append(row.get(&"value")),
	)
	_db.subscribe_to_deletes(
		&"flat",
		func(row: _ModuleTableType) -> void:
			gone.append(row.get(&"value"))
			if wiped[0] == 0:
				wiped[0] += 1
				_db.clear_local_db(),
	)
	_apply(&"flat", [_flat(1), _flat(2), _flat(3)], [])
	_tx_completed = 0 # the setup batch's own terminator is not what this measures
	_apply(&"flat", [], [_flat(1), _flat(2), _flat(3)])

	f += _check_i("every row was announced", before.size(), 3)
	f += _check_i("every announced row was reported gone", gone.size(), 3)
	# The wipe's own snapshot of this table is EMPTY here (the compaction ran before the
	# dispatch), so the wipe reports no transaction and this batch owes the terminator for
	# the three deletes it delivered. Suppressing it left them unterminated (measured: 0).
	f += _check_i("the delivered deletes were terminated", _tx_completed, 1)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)
	return f


# The PK delete pass, wiped from a before_delete callback. There the row IS still cached
# when the wipe snapshots it, so the wipe reports the delete — carrying on reported the
# same row a second time, after the wipe's own transactions_completed.
func _test_wipe_from_before_delete() -> int:
	var f: int = 0
	_fresh()
	var reported: Array[int] = [] # gdlint: ignore[S6]
	var wiped: Array[int] = [0] # gdlint: ignore[S6]
	_db.subscribe_to_before_deletes(
		&"keyed",
		func(_row: _ModuleTableType) -> void:
			if wiped[0] == 0:
				wiped[0] += 1
				_db.clear_local_db(),
	)
	_db.subscribe_to_deletes(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			reported.append(row.get(&"id")),
	)
	_apply(&"keyed", [_keyed(1), _keyed(2)], [])
	_apply(&"keyed", [], [_keyed(1)])

	f += _check_i("both cached rows reported once each", reported.size(), 2)
	f += _check_i("pk 1 reported exactly once", reported.count(1), 1)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)
	return f


# clear_all_tables() empties the same containers as clear_local_db (it just reports
# nothing), so it strands the rest of a batch the same way.
func _test_clear_all_tables_also_stops_a_batch() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_inserts(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			if row.get(&"id") == 1:
				_db.clear_all_tables(),
	)
	_apply(&"keyed", [_keyed(1), _keyed(2), _keyed(3)], [])

	f += _check_i("no row of the wiped batch is cached", _db.get_all_rows(&"keyed").size(), 0)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)
	return f


# The subscribe snapshot walks its tables the same way a transaction update does, and is
# the bigger batch of the two — the initial snapshot is where a game most often reacts.
func _test_subscribe_applied_stops() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_inserts(&"keyed", _on_keyed_insert)
	_wipe_on_pk = 1

	var applied: SubscribeAppliedMessage = SubscribeAppliedMessage.new()
	applied.query_set_id = QueryIdData.new()
	applied.tables = [
		_table_update(&"keyed", [_keyed(1)], []),
		_table_update(&"flat", [_flat(5)], []),
	]
	_db.apply_database_subscription_applied(applied)
	_wipe_on_pk = -1

	f += _check_i("the wipe fired once", _wipes, 1)
	f += _check_i(
		"the later table of the snapshot did not apply",
		_db.get_all_rows(&"flat").size(),
		0,
	)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)
	return f


# The PK-less DELETE arm, wiped from a before_delete callback — the row array has not
# been compacted yet at that point, so the wipe's own snapshot still holds these rows
# and reports them. Carrying on compacted and reported them a second time.
func _test_pk_less_delete_arm_stops() -> int:
	var f: int = 0
	_fresh()
	var gone: Array[int] = [] # gdlint: ignore[S6]
	var wiped: Array[int] = [0] # gdlint: ignore[S6]
	_db.subscribe_to_before_deletes(
		&"flat",
		func(_row: _ModuleTableType) -> void:
			if wiped[0] == 0:
				wiped[0] += 1
				_db.clear_local_db(),
	)
	_db.subscribe_to_deletes(
		&"flat",
		func(row: _ModuleTableType) -> void:
			gone.append(row.get(&"value")),
	)
	_apply(&"flat", [_flat(1), _flat(2), _flat(3)], [])
	_apply(&"flat", [], [_flat(1), _flat(2)])

	f += _check_i("each cached row reported deleted once", gone.size(), 3)
	f += _check_i("value 1 reported exactly once", gone.count(1), 1)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)
	return f


# The client walks a transaction's query sets, one apply_database_update each. That loop
# is above LocalDatabase's own guard, so it needs the same stop: without it the sets
# after the wipe land in the NEXT session's mirror, where nothing can remove them.
func _test_client_transaction_loop_stops() -> int:
	var f: int = 0
	_fresh()
	var client: Node = load(CLIENT_SCRIPT).new()
	client._local_db = _db
	_db.subscribe_to_inserts(&"keyed", _on_keyed_insert)
	_wipe_on_pk = 1

	var first: DatabaseUpdateData = DatabaseUpdateData.new()
	first.query_id = QueryIdData.new()
	first.tables = [_table_update(&"keyed", [_keyed(1)], [])]
	var second: DatabaseUpdateData = DatabaseUpdateData.new()
	second.query_id = QueryIdData.new()
	second.tables = [_table_update(&"keyed", [_keyed(9)], [])]
	var message: TransactionUpdateMessage = TransactionUpdateMessage.new()
	message.query_sets = [first, second]
	client._handle_transaction_update(message)
	_wipe_on_pk = -1

	f += _check_i("the second query set did not apply", _db.get_all_rows(&"keyed").size(), 0)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)
	client.free()
	return f


# The counters are two, on purpose. clear_all_tables() detaches the same containers, so
# LocalDatabase still abandons the batch under it — but it says nothing about the socket,
# so the CLIENT must keep walking a live transaction's remaining query sets. One counter
# for both made a mid-session rebuild silently drop the rest of the transaction and never
# emit transaction_update_received.
func _test_client_loop_survives_clear_all_tables() -> int:
	var f: int = 0
	_fresh()
	var client: Node = load(CLIENT_SCRIPT).new()
	client._local_db = _db
	var announced: Array[int] = [0] # gdlint: ignore[S6]
	client.transaction_update_received.connect(
		func(_m: TransactionUpdateMessage) -> void:
			announced[0] += 1,
	)
	_db.subscribe_to_inserts(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			if row.get(&"id") == 1:
				_db.clear_all_tables(),
	)

	var first: DatabaseUpdateData = DatabaseUpdateData.new()
	first.query_id = QueryIdData.new()
	first.tables = [_table_update(&"keyed", [_keyed(1)], [])]
	var second: DatabaseUpdateData = DatabaseUpdateData.new()
	second.query_id = QueryIdData.new()
	second.tables = [_table_update(&"keyed", [_keyed(9)], [])]
	var message: TransactionUpdateMessage = TransactionUpdateMessage.new()
	message.query_sets = [first, second]
	client._handle_transaction_update(message)

	f += _check_i(
		"the live session's second query set applied",
		_db.get_all_rows(&"keyed").size(),
		1,
	)
	f += _check_i("the transaction was announced", announced[0], 1)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)
	client.free()
	return f


# clear_all_tables() reports NOTHING — no delete, no terminator — so a batch it abandons
# has no wipe-side terminator to fall back on. Both shapes, both loops.
func _test_silent_wipe_still_terminates() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_transactions_completed(&"keyed", _on_tx_completed)
	_db.subscribe_to_inserts(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			if row.get(&"id") == 1:
				_db.clear_all_tables(),
	)
	_apply(&"keyed", [_keyed(1), _keyed(2), _keyed(3)], [])
	f += _check_i("the pk insert batch was terminated", _tx_completed, 1)

	# The PK-less delete arm, wiped silently from a before_delete: without a terminator
	# at the bail, the announced rows are left with neither a delete nor a close.
	_fresh()
	var announced: Array[int] = [] # gdlint: ignore[S6]
	var wiped: Array[int] = [0] # gdlint: ignore[S6]
	_db.subscribe_to_transactions_completed(&"flat", _on_tx_completed)
	_db.subscribe_to_before_deletes(
		&"flat",
		func(row: _ModuleTableType) -> void:
			announced.append(row.get(&"value"))
			if wiped[0] == 0:
				wiped[0] += 1
				_db.clear_all_tables(),
	)
	_apply(&"flat", [_flat(1), _flat(2)], [])
	_tx_completed = 0
	_apply(&"flat", [], [_flat(1), _flat(2)])
	f += _check_i("a row was announced before the silent wipe", announced.size(), 1)
	f += _check_i("the pk-less delete batch was terminated", _tx_completed, 1)
	return f


# The PK delete pass erases each row BEFORE it dispatches, so a table whose last row this
# batch removed is already empty when a wipe snapshots it — the wipe reports no
# terminator for it and this batch owes one. Reaching the bail needs a second delete in
# the list, which the server supplies routinely (one pk may appear several times).
func _test_pk_delete_pass_terminates() -> int:
	var f: int = 0
	_fresh()
	var reported: Array[int] = [] # gdlint: ignore[S6]
	var wiped: Array[int] = [0] # gdlint: ignore[S6]
	_db.subscribe_to_transactions_completed(&"keyed", _on_tx_completed)
	_db.subscribe_to_deletes(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			reported.append(row.get(&"id"))
			if wiped[0] == 0:
				wiped[0] += 1
				_db.clear_local_db(),
	)
	_apply(&"keyed", [_keyed(1)], [])
	_tx_completed = 0
	# pk 9 was never cached, so it only carries the loop to a second iteration.
	_apply(&"keyed", [], [_keyed(1), _keyed(9)])

	f += _check_i("the cached row was reported deleted", reported.size(), 1)
	f += _check_i("the delete batch was terminated", _tx_completed, 1)
	return f


# The tables of ONE message, below the client's loop: each iteration re-hoists its own
# containers, so a mid-session clear_all_tables() leaves the rest of the message
# applicable — dropping it would lose rows the server sent on a live connection.
func _test_multi_table_message_survives_clear_all_tables() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_inserts(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			if row.get(&"id") == 1:
				_db.clear_all_tables(),
	)
	var update: DatabaseUpdateData = DatabaseUpdateData.new()
	update.query_id = QueryIdData.new()
	update.tables = [
		_table_update(&"keyed", [_keyed(1)], []),
		_table_update(&"flat", [_flat(5)], []),
	]
	_db.apply_database_update(update)

	f += _check_i(
		"the second table of the live message applied",
		_db.get_all_rows(&"flat").size(),
		1,
	)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)
	return f


# The PK path: three inserts, the first one's callback wipes. pk 2 and 3 are added by the
# rest of the same loop — i.e. after the mirror was emptied under it.
func _test_pk_batch_abandoned() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_inserts(&"keyed", _on_keyed_insert)
	_db.subscribe_to_deletes(&"keyed", _on_keyed_delete)
	_db.subscribe_to_transactions_completed(&"keyed", _on_tx_completed)

	_wipe_on_pk = 1
	_apply(&"keyed", [_keyed(1), _keyed(2), _keyed(3)], [])
	_wipe_on_pk = -1

	f += _check_i("the wipe fired once", _wipes, 1)
	f += _check_i("no row of the wiped batch is cached", _db.get_all_rows(&"keyed").size(), 0)
	f += _check_i("pk 2 was not stranded", _cached_pks().size(), 0)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)
	# Two terminators: the wipe's own (pk 1 was cached when it ran, so it reported the
	# delete and closed the table) and the abandoned batch's, which is emitted at the bail
	# because the wipe cannot be relied on to have sent one — clear_all_tables reports
	# nothing at all. A consumer flushes twice; the alternative starves it.
	f += _check_i("the wipe reported pk 1 deleted", _deleted_pks.size(), 1)
	f += _check_i("both the wipe and the batch terminated the table", _tx_completed, 2)

	# What the stranded rows used to cost: the server deletes them and they stay.
	_deleted_pks.clear()
	_apply(&"keyed", [], [_keyed(2), _keyed(3)])
	f += _check_i("nothing left for the delete to report", _deleted_pks.size(), 0)
	f += _check_i("nothing survives the delete", _db.get_all_rows(&"keyed").size(), 0)
	return f


# The PK-less path, where a stranded row also duplicates: with no counts entry, every
# re-delivery of the same value is a fresh 0->1 insert.
func _test_pk_less_batch_abandoned() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_inserts(&"flat", _on_flat_insert)
	_db.subscribe_to_deletes(&"flat", _on_flat_delete)

	_wipe_on_value = 10
	_apply(&"flat", [_flat(10), _flat(20), _flat(30)], [])
	_wipe_on_value = -1

	f += _check_i("no row of the wiped batch is cached", _db.get_all_rows(&"flat").size(), 0)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)

	# Re-delivery of a value the wiped batch had inserted: exactly one cached copy.
	_apply(&"flat", [_flat(20)], [])
	f += _check_i("re-delivery caches one copy", _db.get_all_rows(&"flat").size(), 1)
	f += _check_b("rows and counts still agree", _pk_less_consistent(&"flat"), true)

	_deleted_values.clear()
	_apply(&"flat", [], [_flat(20), _flat(30)])
	f += _check_i("the re-delivered row is reported deleted", _deleted_values.size(), 1)
	f += _check_i("nothing survives the delete", _db.get_all_rows(&"flat").size(), 0)
	return f


# apply_database_update walks several TableUpdateData in one message. A wipe inside the
# first one's callbacks ends the message, rather than applying the later tables into a
# mirror the caller just abandoned.
func _test_multi_table_update_stops() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_inserts(&"keyed", _on_keyed_insert)
	_wipe_on_pk = 1

	var update: DatabaseUpdateData = DatabaseUpdateData.new()
	update.query_id = QueryIdData.new()
	update.tables = [
		_table_update(&"keyed", [_keyed(1)], []),
		_table_update(&"flat", [_flat(5)], []),
	]
	_db.apply_database_update(update)
	_wipe_on_pk = -1

	f += _check_i("the wipe fired once", _wipes, 1)
	f += _check_i("the later table did not apply", _db.get_all_rows(&"flat").size(), 0)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)
	return f


# Event tables store nothing, but a wiped batch still has to stop: the rows after the
# wipe belong to a session the caller ended.
func _test_event_batch_stops() -> int:
	var f: int = 0
	_fresh()
	var seen: Array[int] = [] # gdlint: ignore[S6]
	_db.subscribe_to_inserts(
		&"events",
		func(row: _ModuleTableType) -> void:
			seen.append(row.get(&"value"))
			if row.get(&"value") == 1:
				_db.clear_local_db(),
	)
	_db.subscribe_to_transactions_completed(&"events", _on_tx_completed)
	var u: TableUpdateData = _table_update(&"events", [_flat(1), _flat(2), _flat(3)], [])
	u.is_event = true
	_db.apply_table_update(u)

	f += _check_i("the event batch stopped at the wipe", seen.size(), 1)
	# Unlike a stored-row table, an event table is empty in the mirror, so the wipe
	# reports no transaction of its own for it — the events already delivered would be
	# left unterminated if the abandoned batch reported nothing either.
	f += _check_i("the delivered events were still terminated", _tx_completed, 1)
	return f


# clear_local_db reports every row it dropped, and that reporting is game code too: a
# listener that wipes again from inside it must not make the outer wipe report the rest
# of its rows a second time.
func _test_wipe_inside_the_wipe() -> int:
	var f: int = 0
	_fresh()
	_apply(&"keyed", [_keyed(1), _keyed(2), _keyed(3)], [])
	var reported: Array[int] = [] # gdlint: ignore[S6]
	var wipes: Array[int] = [0] # gdlint: ignore[S6]
	_db.subscribe_to_deletes(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			reported.append(row.get(&"id"))
			if wipes[0] == 0:
				wipes[0] += 1
				_db.clear_local_db(),
	)
	_db.clear_local_db()

	f += _check_i("each row reported exactly once", reported.size(), 3)
	f += _check_i("the mirror is empty", _db.get_all_rows(&"keyed").size(), 0)
	return f


# prune_query rebuilds a query's deletes from membership and applies them, which runs
# game code. A wipe from there clears _query_rows, so carrying on would re-create
# membership for a query the wipe just forgot.
func _test_prune_stops_at_wipe() -> int:
	var f: int = 0
	_fresh()
	# One query holding rows in two tables, so the prune has a second table to reach.
	var update: DatabaseUpdateData = DatabaseUpdateData.new()
	var qid: QueryIdData = QueryIdData.new()
	qid.id = 7
	update.query_id = qid
	update.tables = [
		_table_update(&"keyed", [_keyed(1)], []),
		_table_update(&"flat", [_flat(5)], []),
	]
	_db.apply_database_update(update)
	f += _check_i("setup: both tables hold a row", _db.get_all_rows(&"keyed").size(), 1)

	_db.subscribe_to_deletes(
		&"keyed",
		func(_row: _ModuleTableType) -> void:
			_db.clear_local_db(),
	)
	# The discriminating assertion is the SECOND table's fate, not _query_rows: prune
	# erases its own entry either way, and the wipe empties the mirror either way. What
	# separates the builds is that an unguarded prune goes on to apply `flat`'s deletes
	# into the already-emptied mirror, which warns about a delete matching no cached row.
	_db.prune_query(7)

	f += _check_b("the wiped prune did not delete into an empty mirror", _warned(&"flat"), false)
	f += _check_i("no query membership survived the wipe", _db._query_rows.size(), 0)
	f += _check_i("the mirror is empty", _db.get_all_rows(&"flat").size(), 0)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)
	return f


# The generation check must cost the ordinary paths nothing: an update with no wipe in
# it behaves exactly as before.
func _test_unwiped_paths_unchanged() -> int:
	var f: int = 0
	_fresh()
	_db.subscribe_to_transactions_completed(&"keyed", _on_tx_completed)
	_db.subscribe_to_deletes(&"keyed", _on_keyed_delete)

	_apply(&"keyed", [_keyed(1), _keyed(2)], [])
	f += _check_i("both rows cached", _db.get_all_rows(&"keyed").size(), 2)
	f += _check_i("one transactions_completed", _tx_completed, 1)

	_apply(&"keyed", [], [_keyed(1)])
	f += _check_i("the delete was reported", _deleted_pks.size(), 1)
	f += _check_i("one row left", _db.get_all_rows(&"keyed").size(), 1)
	f += _check_i("a second transactions_completed", _tx_completed, 2)
	f += _check_b("rows and refcounts agree", _pk_consistent(&"keyed"), true)

	_apply(&"flat", [_flat(1), _flat(2)], [])
	_apply(&"flat", [], [_flat(1)])
	f += _check_i("pk-less rows left", _db.get_all_rows(&"flat").size(), 1)
	f += _check_b("rows and counts agree", _pk_less_consistent(&"flat"), true)
	return f

# --- invariants ---


# Every cached PK row has a refcount and every refcount has a cached row.
func _warned(table: StringName) -> bool:
	return _db._unmatched_delete_warned.has(table)


func _pk_consistent(table: StringName) -> bool:
	var rows: Dictionary = _db._tables.get(table, { })
	var refs: Dictionary = _db._ref_counts.get(table, { })
	for pk: Variant in rows:
		if refs.get(pk, 0) <= 0:
			return false
	for pk: Variant in refs:
		if not rows.has(pk):
			return false
	return true


# Every listed PK-less row is counted, and the counts add up to the rows listed.
func _pk_less_consistent(table: StringName) -> bool:
	var rows: Array = _db._pk_less_tables.get(table, [])
	var counts: Dictionary = _db._pk_less_counts.get(table, { })
	var entries: int = 0
	for h: int in counts:
		for entry: Array in counts[h]:
			if entry[1] <= 0:
				return false
			entries += 1
	return entries == rows.size()

# --- callbacks ---


func _on_keyed_insert(row: _ModuleTableType) -> void:
	if row.get(&"id") == _wipe_on_pk:
		_wipes += 1
		_db.clear_local_db()


func _on_keyed_delete(row: _ModuleTableType) -> void:
	_deleted_pks.append(row.get(&"id"))


func _on_flat_insert(row: _ModuleTableType) -> void:
	if row.get(&"value") == _wipe_on_value:
		_wipes += 1
		_db.clear_local_db()


func _on_flat_delete(row: _ModuleTableType) -> void:
	_deleted_values.append(row.get(&"value"))


func _on_tx_completed() -> void:
	_tx_completed += 1

# --- harness ---


func _fresh() -> void:
	if _db != null:
		_db.free()
	_db = _mk_db()
	_wipes = 0
	_tx_completed = 0
	_deleted_pks.clear()
	_deleted_values.clear()


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"flat", &"keyed", &"events"]
	schema.types[&"flat"] = _FlatRow
	schema.tables[&"flat"] = _FlatRow
	schema.types[&"events"] = _FlatRow
	schema.tables[&"events"] = _FlatRow
	schema.types[&"keyed"] = _KeyedRow
	schema.tables[&"keyed"] = _KeyedRow
	return LocalDatabase.new(schema)


func _cached_pks() -> Array:
	return (_db._tables.get(&"keyed", { }) as Dictionary).keys()


func _table_update(table_name: StringName, inserts: Array, deletes: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	return u


func _apply(table_name: StringName, inserts: Array, deletes: Array) -> void:
	_db.apply_table_update(_table_update(table_name, inserts, deletes))


func _keyed(id: int) -> _KeyedRow:
	return _KeyedRow.new(id)


func _flat(value: int) -> _FlatRow:
	return _FlatRow.new(value)


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


class _FlatRow:
	extends _ModuleTableType
	@export var value: int = 0


	func _init(p_value: int = 0) -> void:
		value = p_value


class _KeyedRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0


	func _init(p_id: int = 0) -> void:
		id = p_id

# The reconnect reconciles the mirror against the new session's snapshot instead of
# wiping it.
#
# A row deleted server-side while the client was away has to reach the game as a delete,
# or a consumer keyed by primary key keeps whatever it built for that row for the rest of
# the session (in the Blackholio example, eaten food stayed on screen after every
# auto-reconnect). The SDK used to get there by wiping the mirror before the resubscribe,
# which also reported every row that was still there as deleted and then inserted again.
# Now _prepare_for_reconnect leaves the rows alone, and the SubscribeBatchApplied is
# applied together with a delete of every row no new-session query set holds, as ONE
# message, so the usual pairing decides what fires:
#   - a deleted row gets before_delete + delete;
#   - an unchanged row gets nothing;
#   - a changed row gets one update.
#
# The second half covers game code that runs while the snapshot is being applied: a
# snapshot handed in from a row callback, a wipe or a prune from inside its callbacks,
# and a delete queued ahead of it.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_reconnect_row_deletes.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const _OLD_QUERY: int = 0
const _NEW_QUERY: int = 5

var _total: int = 0
## Every row callback in emission order: "ins:1", "upd:3", "before:2", "del:2",
## "ins:flat:a", "before:flat:b", "del:flat:b", "tx:tbl".
var _events: PackedStringArray = []
## Called from the matching callback once, then cleared. Each takes the row (for an
## update, the new one).
var _on_insert_hook: Callable = Callable()
var _on_before_delete_hook: Callable = Callable()


func _initialize() -> void:
	var f: int = 0
	f += _test_prepare_keeps_the_rows()
	f += _test_snapshot_reports_only_what_changed()
	f += _test_empty_snapshot_deletes_everything()
	f += _test_a_new_session_subscription_keeps_its_rows()
	f += _test_snapshot_from_a_callback_is_queued()
	f += _test_a_stale_queued_snapshot_is_dropped()
	f += _test_delete_queued_ahead_of_the_snapshot()
	f += _test_wipe_from_a_before_delete()
	f += _test_wipe_from_an_insert()
	f += _test_prune_from_a_callback()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


# Dropping the socket reports nothing and keeps every row queryable.
func _test_prepare_keeps_the_rows() -> int:
	var f: int = 0
	# Built with .new() and never added to the tree, so _ready (auto-connect, threads)
	# never runs — same harness as tests/test_reconnect_state.gd.
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var db: LocalDatabase = _seeded_db()
	client._local_db = db
	var generation: int = db.session_generation()

	client._prepare_for_reconnect()

	f += _check_s("prepare: no callback fired", ", ".join(_events), "")
	f += _check_i("prepare: keyed rows kept", db._tables[&"tbl"].size(), 3)
	f += _check_i("prepare: unkeyed rows kept", db._pk_less_tables[&"flat"].size(), 2)
	f += _check_i("prepare: refcounts kept", db._ref_counts.get(&"tbl", { }).size(), 3)
	f += _check_i("prepare: old membership dropped", db._query_rows.size(), 0)
	f += _check_b("prepare: session ended", db.session_generation() != generation, true)
	client.free()
	db.free()
	return f


func _test_snapshot_reports_only_what_changed() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()

	# Row 1 unchanged, row 2 gone, row 3 changed, row 4 new; "a" unchanged, "b" gone.
	db.apply_reconnect_snapshot(
		[
			_mk_update(&"tbl", [_mk_row(1, 10), _mk_row(3, 31), _mk_row(4, 40)]),
			_mk_update(&"flat", [_mk_flat("a")]),
		],
		PackedInt64Array([_NEW_QUERY, _NEW_QUERY]),
	)

	f += _check_s(
		"snapshot: only the changes fire",
		", ".join(_events),
		"before:2, before:flat:b, ins:4, upd:3, del:2, tx:tbl, del:flat:b, tx:flat",
	)
	f += _check_i("snapshot: mirror holds 1, 3, 4", db._tables[&"tbl"].size(), 3)
	f += _check_i("snapshot: row 3 carries the new value", db._tables[&"tbl"][3].val, 31)
	f += _check_b("snapshot: row 2 evicted", db._tables[&"tbl"].has(2), false)
	f += _check_i("snapshot: one reference each", _total_refs(db), 3)
	f += _check_i("snapshot: unkeyed mirror holds a", db._pk_less_tables[&"flat"].size(), 1)
	f += _check_b(
		"snapshot: rows now belong to the new query set",
		db._query_rows.has(_NEW_QUERY) and not db._query_rows.has(_OLD_QUERY),
		true,
	)
	db.free()
	return f


# The reconcile with nothing saved: no set comes back, so nothing is held.
func _test_empty_snapshot_deletes_everything() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	db.apply_reconnect_snapshot([], PackedInt64Array())
	f += _check_s(
		"empty: every row deleted once",
		", ".join(_events),
		(
			"before:1, before:2, before:3, before:flat:a, before:flat:b, "
			+ "del:1, del:2, del:3, tx:tbl, del:flat:a, del:flat:b, tx:flat"
		),
	)
	f += _check_i("empty: mirror emptied", db._tables[&"tbl"].size(), 0)
	f += _check_i("empty: refcounts emptied", db._ref_counts[&"tbl"].size(), 0)
	f += _check_b("empty: table key survived", db._tables.has(&"tbl"), true)
	db.free()
	return f


# A query the game subscribed to on the new socket, applied before the batch landed,
# holds its rows: the reconcile only drops the old session's references.
func _test_a_new_session_subscription_keeps_its_rows() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	db.apply_table_update(_mk_update(&"tbl", [_mk_row(1, 10)]), 9)
	_events.clear()

	db.apply_reconnect_snapshot([], PackedInt64Array())
	f += _check_b("new sub: row 1 kept", db._tables[&"tbl"].has(1), true)
	f += _check_i("new sub: by its one reference", db._ref_counts[&"tbl"].get(1, 0), 1)
	f += _check_b("new sub: row 1 not reported", ", ".join(_events).contains(":1,"), false)
	f += _check_b("new sub: row 2 deleted", _events.has("del:2"), true)
	db.free()
	return f


# Handed in from a row callback, the snapshot waits for the message being dispatched and
# is applied after it, counting the references as they stand then.
func _test_snapshot_from_a_callback_is_queued() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	_on_insert_hook = func(_row: _ModuleTableType) -> void:
		db.apply_reconnect_snapshot(
			[_mk_update(&"tbl", [_mk_row(1, 10)])],
			PackedInt64Array([_NEW_QUERY]),
		)
	# Row 9 under a new-session query; its insert callback hands the snapshot in.
	db.apply_table_update(_mk_update(&"tbl", [_mk_row(9, 90)]), 9)
	f += _check_s(
		"queued: snapshot ran after the outer message",
		", ".join(_events),
		(
			"ins:9, tx:tbl, before:2, before:3, before:flat:a, before:flat:b, "
			+ "del:2, del:3, tx:tbl, del:flat:a, del:flat:b, tx:flat"
		),
	)
	f += _check_b("queued: the outer message's row survived", db._tables[&"tbl"].has(9), true)
	f += _check_b("queued: the re-delivered row survived", db._tables[&"tbl"].has(1), true)
	f += _check_i("queued: nothing left queued", db._queued_batches.size(), 0)
	db.free()
	return f


# A snapshot queued in one session and still waiting when a second reconnect starts
# belongs to a set of handles that no longer exist: it is dropped, not applied.
func _test_a_stale_queued_snapshot_is_dropped() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	_on_insert_hook = func(_row: _ModuleTableType) -> void:
		db.apply_reconnect_snapshot([], PackedInt64Array())
		db.begin_reconnect_session()
	db.apply_table_update(_mk_update(&"tbl", [_mk_row(9, 90)]), 9)
	f += _check_s("stale: nothing deleted", ", ".join(_events), "ins:9, tx:tbl")
	f += _check_i("stale: mirror untouched", db._tables[&"tbl"].size(), 4)
	db.free()
	return f


# A delete queued ahead of the snapshot releases the row first; the snapshot then sees
# it gone and re-delivers it as an insert, with no delete of its own (a void delete would
# pair it into a spurious update).
func _test_delete_queued_ahead_of_the_snapshot() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	_on_insert_hook = func(_row: _ModuleTableType) -> void:
		var drop: TableUpdateData = _mk_update(&"tbl", [])
		drop.deletes.append(_mk_row(2, 20))
		db.apply_table_update(drop)
		db.apply_reconnect_snapshot(
			[_mk_update(&"tbl", [_mk_row(1, 10), _mk_row(2, 20), _mk_row(3, 30)])],
			PackedInt64Array([_NEW_QUERY]),
		)
	db.apply_table_update(_mk_update(&"tbl", [_mk_row(9, 90)]), 9)
	f += _check_s(
		"queued delete: deleted then re-inserted once",
		", ".join(_events),
		(
			"ins:9, tx:tbl, before:2, del:2, tx:tbl, before:flat:a, before:flat:b, "
			+ "ins:2, tx:tbl, del:flat:a, del:flat:b, tx:flat"
		),
	)
	f += _check_i("queued delete: row 2 held once", db._ref_counts[&"tbl"].get(2, 0), 1)
	db.free()
	return f


# A before-delete that wipes the mirror ends the snapshot before any of it is applied. The
# wipe reports every cached row deleted once. It announces the row in hand again (the
# listeners after the wiping one never heard it, see _fire_table_before_deletes), but no
# row twice that the snapshot had already fully announced.
func _test_wipe_from_a_before_delete() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	_on_before_delete_hook = func(_row: _ModuleTableType) -> void:
		db.clear_local_db()
	db.apply_reconnect_snapshot(
		[_mk_update(&"tbl", [_mk_row(1, 10), _mk_row(4, 40)])],
		PackedInt64Array([_NEW_QUERY]),
	)
	f += _check_i("wipe in before: row 4 never reported", _count_with(":4"), 0)
	f += _check_i("wipe in before: row 3 announced once", _events.count("before:3"), 1)
	f += _check_i("wipe in before: row 1 announced once", _events.count("before:1"), 1)
	f += _check_i("wipe in before: row 2 deleted once", _events.count("del:2"), 1)
	f += _check_i("wipe in before: row 1 deleted once", _events.count("del:1"), 1)
	f += _check_i("wipe in before: row 3 deleted once", _events.count("del:3"), 1)
	f += _check_i("wipe in before: mirror empty", db._tables[&"tbl"].size(), 0)
	f += _check_i("wipe in before: nothing left queued", db._queued_batches.size(), 0)
	db.free()
	return f


# A wipe from the snapshot's first insert callback reports what the game knows: the row
# it was just told about and the rows it had, but not a row of the snapshot it never
# heard of.
func _test_wipe_from_an_insert() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	_on_insert_hook = func(_row: _ModuleTableType) -> void:
		db.clear_local_db()
	db.apply_reconnect_snapshot(
		[_mk_update(&"tbl", [_mk_row(1, 10), _mk_row(4, 40), _mk_row(5, 50)])],
		PackedInt64Array([_NEW_QUERY]),
	)
	f += _check_i("wipe in insert: row 5 never reported", _count_with(":5"), 0)
	f += _check_i("wipe in insert: row 4 inserted then deleted", _events.count("del:4"), 1)
	f += _check_i("wipe in insert: row 1 deleted once", _events.count("del:1"), 1)
	f += _check_i("wipe in insert: row 2 before-deleted once", _events.count("before:2"), 1)
	f += _check_i("wipe in insert: row 2 deleted once", _events.count("del:2"), 1)
	f += _check_i("wipe in insert: mirror empty", db._tables[&"tbl"].size(), 0)
	db.free()
	return f


# A prune of the new query set from inside the snapshot's callbacks is queued behind it
# and then drops the rows the snapshot just delivered.
func _test_prune_from_a_callback() -> int:
	var f: int = 0
	var db: LocalDatabase = _seeded_db()
	db.begin_reconnect_session()
	_on_insert_hook = func(_row: _ModuleTableType) -> void:
		db.prune_query(_NEW_QUERY)
	db.apply_reconnect_snapshot(
		[_mk_update(&"tbl", [_mk_row(1, 10), _mk_row(4, 40)])],
		PackedInt64Array([_NEW_QUERY]),
	)
	f += _check_i("prune: row 4 inserted once", _events.count("ins:4"), 1)
	f += _check_i("prune: then deleted once", _events.count("del:4"), 1)
	f += _check_i("prune: row 1 deleted once", _events.count("del:1"), 1)
	f += _check_i("prune: mirror empty", db._tables[&"tbl"].size(), 0)
	f += _check_b("prune: membership gone", db._query_rows.has(_NEW_QUERY), false)
	db.free()
	return f


# Rows 1 (10), 2 (20), 3 (30) and unkeyed "a", "b", all under the old session's query.
func _seeded_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"tbl", &"flat"]
	# A table lives in both maps, exactly as _add_table_names writes it.
	schema.types[&"tbl"] = _PkRow
	schema.tables[&"tbl"] = _PkRow
	schema.types[&"flat"] = _FlatRow
	schema.tables[&"flat"] = _FlatRow
	var db: LocalDatabase = LocalDatabase.new(schema)
	db.apply_table_update(
		_mk_update(&"tbl", [_mk_row(1, 10), _mk_row(2, 20), _mk_row(3, 30)]),
		_OLD_QUERY,
	)
	db.apply_table_update(_mk_update(&"flat", [_mk_flat("a"), _mk_flat("b")]), _OLD_QUERY)
	db.subscribe_to_inserts(&"tbl", _on_insert)
	db.subscribe_to_updates(&"tbl", _on_update)
	db.subscribe_to_before_deletes(&"tbl", _on_before_delete)
	db.subscribe_to_deletes(&"tbl", _on_delete)
	db.subscribe_to_inserts(&"flat", _on_flat_insert)
	db.subscribe_to_before_deletes(&"flat", _on_flat_before_delete)
	db.subscribe_to_deletes(&"flat", _on_flat_delete)
	db.row_transactions_completed.connect(_on_tx_completed)
	_events.clear()
	_on_insert_hook = Callable()
	_on_before_delete_hook = Callable()
	return db


func _mk_row(id_val: int, v: int) -> Resource:
	var r: Resource = _PkRow.new()
	r.id = id_val
	r.val = v
	return r


func _mk_flat(label: String) -> Resource:
	var r: Resource = _FlatRow.new()
	r.label = label
	return r


func _mk_update(table: StringName, inserts: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	u.inserts.assign(inserts)
	u.is_event = false
	return u


func _total_refs(db: LocalDatabase) -> int:
	var total: int = 0
	for pk: Variant in db._ref_counts[&"tbl"]:
		total += db._ref_counts[&"tbl"][pk]
	return total


func _count_with(fragment: String) -> int:
	var n: int = 0
	for event: String in _events:
		if event.ends_with(fragment):
			n += 1
	return n


func _on_insert(row: _ModuleTableType) -> void:
	_events.append("ins:%d" % row.id)
	_fire_once(true, row)


func _on_update(_old: _ModuleTableType, new_row: _ModuleTableType) -> void:
	_events.append("upd:%d" % new_row.id)


func _on_before_delete(row: _ModuleTableType) -> void:
	_events.append("before:%d" % row.id)
	_fire_once(false, row)


func _on_delete(row: _ModuleTableType) -> void:
	_events.append("del:%d" % row.id)


func _on_flat_insert(row: _ModuleTableType) -> void:
	_events.append("ins:flat:%s" % row.label)


func _on_flat_before_delete(row: _ModuleTableType) -> void:
	_events.append("before:flat:%s" % row.label)


func _on_flat_delete(row: _ModuleTableType) -> void:
	_events.append("del:flat:%s" % row.label)


func _on_tx_completed(table_name: StringName) -> void:
	_events.append("tx:%s" % table_name)


func _fire_once(insert: bool, row: _ModuleTableType) -> void:
	var hook: Callable = _on_insert_hook if insert else _on_before_delete_hook
	if not hook.is_valid():
		return
	if insert:
		_on_insert_hook = Callable()
	else:
		_on_before_delete_hook = Callable()
	hook.call(row)


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


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


# Exported columns, as a generated row has them: the mirror compares rows by their
# storage properties, so a row with plain `var` columns reads as changed every time.
class _PkRow:
	extends _ModuleTableType

	const PRIMARY_KEY: StringName = &"id"

	@export var id: int = 0
	@export var val: int = 0


class _FlatRow:
	extends _ModuleTableType

	@export var label: String = ""

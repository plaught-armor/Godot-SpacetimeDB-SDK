# Regression test: a server message is applied whole, merged per table across its query
# sets, before any row callback runs — the semantics of the official Rust, C# and
# TypeScript SDKs (Rust db_connection.rs apply_update, C# ApplyUpdate's PreApply / Apply /
# PostApply, TypeScript's pending-callback list).
#
# Two bugs this pins:
#   - A row moving from one query set to another in one transaction (an entity crossing
#     between two separately subscribed cells) arrived as a delete in one set and an
#     insert in the other. Applied set by set, a delete landing first took the row to
#     refcount 0 and fired on_delete, and the insert brought it back with on_insert: a
#     false despawn and respawn. Merged per table it is one on_update.
#   - Callbacks fired while the message was still being applied, so a callback for one
#     table could not see a row the same transaction put in a later table (a player's
#     on_insert looking up its entity got null), nor find it through an index.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_message_apply_semantics.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## Loaded by path rather than named: a --script main loop compiles before autoloads
## register, and the client script is what the addon's autoload is built from.
const CLIENT_SCRIPT: String = "res://addons/SpacetimeDB/core/spacetimedb_client.gd"

var _total: int = 0
var _db: LocalDatabase
var _index: _TagIndex
## "insert:<id>" / "update:<id>" / "delete:<id>" / "before:<id>" / "done" per table.
var _log: PackedStringArray = []


func _initialize() -> void:
	var fails: int = _run()
	if _db != null:
		_db.free()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	f += _test_move_across_sets(true)
	f += _test_move_across_sets(false)
	f += _test_pkless_move_across_sets()
	f += _test_insert_sees_later_table()
	f += _test_before_delete_sees_message_unapplied()
	f += _test_delete_sees_message_applied()
	f += _test_one_terminator_per_table()
	f += _test_client_applies_one_message()
	f += _test_wipe_reports_only_announced()
	f += _test_wipe_during_updates()
	f += _test_lone_delivery_with_held_rows(20, "insert:1, insert:3")
	f += _test_lone_delivery_with_held_rows(21, "insert:1, insert:3, update:2")
	f += _test_void_pairs_take_one_membership()
	f += _test_void_pairs_from_two_queries()
	f += _test_before_delete_wipe_reports_once()
	f += _test_nested_delete_from_before_delete()
	f += _test_queued_message_dropped_by_wipe()
	f += _test_prune_from_callback()
	f += _test_before_delete_relay()
	return f


## The entity leaves set 1 and enters set 2 in one transaction, with the delete's set
## first in the message ([param delete_first]) or last.
func _test_move_across_sets(delete_first: bool) -> int:
	var tag: String = "move (delete set %s)" % ("first" if delete_first else "last")
	_fresh()
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"entity", [_ent(1, 10)], [])])]))
	_log.clear()
	var leave: DatabaseUpdateData = _qset(1, [_table(&"entity", [], [_ent(1, 10)])])
	var enter: DatabaseUpdateData = _qset(2, [_table(&"entity", [_ent(1, 11)], [])])
	_db.apply_transaction_update(_tx([leave, enter] if delete_first else [enter, leave]))

	var f: int = _check_s("%s: one update, nothing else" % tag, _entity_events(), "update:1")
	f += _check_i("%s: refcount 1" % tag, _db._ref_counts[&"entity"][1], 1)
	f += _check_i("%s: new value cached" % tag, _db.get_row_by_pk(&"entity", 1).tag, 11)
	f += _check_b("%s: set 1 no longer holds it" % tag, _holds(1, &"entity", 1), false)
	f += _check_b("%s: set 2 holds it" % tag, _holds(2, &"entity", 1), true)
	f += _check_b(
		"%s: index follows" % tag,
		_index.find(11) == _db.get_row_by_pk(&"entity", 1),
		true,
	)
	f += _check_b("%s: old tag released" % tag, _index.find(10) == null, true)
	return f


## The same move on a table with no primary key, value unchanged: the row keeps one
## reference throughout, so nothing is reported at all.
func _test_pkless_move_across_sets() -> int:
	_fresh()
	var seen: PackedStringArray = []
	_db.subscribe_to_inserts(
		&"flat",
		func(_r: _ModuleTableType) -> void:
			seen.append("insert"),
	)
	_db.subscribe_to_deletes(
		&"flat",
		func(_r: _ModuleTableType) -> void:
			seen.append("delete"),
	)
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"flat", [_FlatRow.new(3)], [])])]))
	seen.clear()
	_db.apply_transaction_update(
		_tx(
			[
				_qset(1, [_table(&"flat", [], [_FlatRow.new(3)])]),
				_qset(2, [_table(&"flat", [_FlatRow.new(3)], [])]),
			],
		),
	)
	var f: int = _check_s("pk-less move: no callbacks", ", ".join(seen), "")
	f += _check_i("pk-less move: still one row", _db.count_all_rows(&"flat"), 1)
	return f


## A player and its entity arrive in one transaction, the player's table first. Its
## on_insert already sees the entity, by primary key and through the index.
func _test_insert_sees_later_table() -> int:
	_fresh()
	var found: Array[bool] = [false, false]
	_db.subscribe_to_inserts(
		&"player",
		func(p: _ModuleTableType) -> void:
			found[0] = _db.get_row_by_pk(&"entity", p.entity_id) != null
			found[1] = _index.find(50) != null,
	)
	_db.apply_transaction_update(
		_tx(
			[
				_qset(
					1,
					[_table(&"player", [_player(1, 5)], []), _table(&"entity", [_ent(5, 50)], [])],
				)
			]
		),
	)
	var f: int = _check_b("insert: entity visible by pk", found[0], true)
	f += _check_b("insert: entity visible through the index", found[1], true)
	return f


## A transaction deletes a player and its entity. Every before-delete runs before the
## message touches the mirror, so each sees the other row still there.
func _test_before_delete_sees_message_unapplied() -> int:
	_fresh()
	_seed_player_and_entity()
	var saw: Array[bool] = [false, false]
	_db.subscribe_to_before_deletes(
		&"player",
		func(_p: _ModuleTableType) -> void:
			saw[0] = _db.get_row_by_pk(&"entity", 5) != null,
	)
	_db.subscribe_to_before_deletes(
		&"entity",
		func(_e: _ModuleTableType) -> void:
			saw[1] = _db.get_row_by_pk(&"player", 1) != null,
	)
	_db.apply_transaction_update(
		_tx(
			[
				_qset(
					1,
					[_table(&"player", [], [_player(1, 5)]), _table(&"entity", [], [_ent(5, 50)])],
				)
			]
		),
	)
	var f: int = _check_b("before-delete: player's sees the entity", saw[0], true)
	f += _check_b("before-delete: entity's sees the player", saw[1], true)
	f += _check_s("before-deletes come first", ", ".join(_log), "before:5, delete:5, done")
	return f


## The same transaction: on_delete for the player already sees the entity gone, though
## the entity's table comes later in the message.
func _test_delete_sees_message_applied() -> int:
	_fresh()
	_seed_player_and_entity()
	var entity_left: Array[bool] = [false]
	_db.subscribe_to_deletes(
		&"player",
		func(_p: _ModuleTableType) -> void:
			entity_left[0] = _db.get_row_by_pk(&"entity", 5) == null,
	)
	_db.apply_transaction_update(
		_tx(
			[
				_qset(
					1,
					[_table(&"player", [], [_player(1, 5)]), _table(&"entity", [], [_ent(5, 50)])],
				)
			]
		),
	)
	var f: int = _check_b("delete: entity already gone", entity_left[0], true)
	f += _check_b("delete: index already released it", _index.find(50) == null, true)
	return f


## Two query sets touching one table: one message, so one terminator for it.
func _test_one_terminator_per_table() -> int:
	_fresh()
	_db.apply_transaction_update(
		_tx(
			[
				_qset(1, [_table(&"entity", [_ent(1, 10)], [])]),
				_qset(2, [_table(&"entity", [_ent(2, 20)], [])]),
			],
		),
	)
	return _check_s("one terminator for two sets", ", ".join(_log), "insert:1, insert:2, done")


## The client hands a transaction to the mirror as one message.
func _test_client_applies_one_message() -> int:
	_fresh()
	var client: Node = load(CLIENT_SCRIPT).new()
	client._local_db = _db
	client._handle_transaction_update(_tx([_qset(1, [_table(&"entity", [_ent(1, 10)], [])])]))
	_log.clear()
	client._handle_transaction_update(
		_tx(
			[
				_qset(1, [_table(&"entity", [], [_ent(1, 10)])]),
				_qset(2, [_table(&"entity", [_ent(1, 11)], [])]),
			],
		),
	)
	var f: int = _check_s("client: move is one update", _entity_events(), "update:1")
	client.free()
	return f


## The same wipe from an update callback: the update already reported is gone as its new
## row, the one not yet reported as the row it replaced.
func _test_wipe_during_updates() -> int:
	_fresh()
	_db.apply_transaction_update(
		_tx([_qset(1, [_table(&"entity", [_ent(1, 10), _ent(2, 20)], [])])])
	)
	_db.subscribe_to_updates(
		&"entity",
		func(_old: _ModuleTableType, r: _ModuleTableType) -> void:
			if r.id == 1:
				_db.clear_local_db(),
	)
	var gone: PackedStringArray = []
	_db.row_deleted.connect(
		func(table: StringName, r: _ModuleTableType) -> void:
			gone.append("%s:%d:%d" % [table, r.id, r.tag]),
	)
	var entity: TableUpdateData = _table(
		&"entity",
		[_ent(1, 11), _ent(2, 21)],
		[_ent(1, 10), _ent(2, 20)],
	)
	_db.apply_transaction_update(_tx([_qset(1, [entity])]))
	return _check_s(
		"wipe mid-updates: only announced rows reported",
		", ".join(gone),
		"entity:1:11, entity:2:20",
	)


## One delivery whose inserts are mostly new, with a row another query already holds in
## the middle (value [param held_tag], 20 = unchanged) and first: the new rows are still
## each reported once, in order, and the held one only as an update when it changed.
func _test_lone_delivery_with_held_rows(held_tag: int, want: String) -> int:
	var f: int = 0
	for held_first: bool in [false, true]:
		var tag: String = "lone delivery (tag %d, held %s)" % [
			held_tag,
			"first" if held_first else "mid",
		]
		_fresh()
		_db.apply_transaction_update(_tx([_qset(1, [_table(&"entity", [_ent(2, 20)], [])])]))
		_log.clear()
		var rows: Array = [_ent(1, 10), _ent(2, held_tag), _ent(3, 30)]
		if held_first:
			rows = [_ent(2, held_tag), _ent(1, 10), _ent(3, 30)]
		_db.apply_transaction_update(_tx([_qset(2, [_table(&"entity", rows, [])])]))
		f += _check_s("%s: events" % tag, _entity_events(), want)
		f += _check_i("%s: refcount of held row" % tag, _db._ref_counts[&"entity"][2], 2)
		f += _check_i("%s: rows" % tag, _db.count_all_rows(&"entity"), 3)
	return f


## A callback wipes the mirror while the message is still being reported. Every row of
## the message is already in the mirror by then, but the wipe must report only what a
## consumer was told about: an insert it never heard of is not reported gone, and an update
## it never heard of is reported gone as the row it knows.
func _test_wipe_reports_only_announced() -> int:
	_fresh()
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"entity", [_ent(1, 10)], [])])]))
	_log.clear()
	_db.subscribe_to_inserts(
		&"entity",
		func(r: _ModuleTableType) -> void:
			if r.id == 2:
				_db.clear_local_db(),
	)
	var gone: PackedStringArray = []
	_db.row_deleted.connect(
		func(table: StringName, r: _ModuleTableType) -> void:
			gone.append("%s:%d" % [table, r.id] + (":%d" % r.tag if r is _EntityRow else "")),
	)
	var entity: TableUpdateData = _table(
		&"entity",
		[_ent(1, 11), _ent(2, 20), _ent(3, 30)],
		[_ent(1, 10)],
	)
	_db.apply_transaction_update(_tx([_qset(1, [entity, _table(&"player", [_player(7, 1)], [])])]))

	var f: int = _check_s(
		"wipe mid-message: only announced rows reported",
		", ".join(gone),
		"entity:1:10, entity:2:20",
	)
	f += _check_s(
		"wipe mid-message: entity events",
		", ".join(_log),
		"insert:2, before:1, delete:1, before:2, delete:2, done, done",
	)
	f += _check_i("wipe mid-message: mirror empty", _db.get_all_rows(&"entity").size(), 0)
	f += _check_i("wipe mid-message: player empty", _db.get_all_rows(&"player").size(), 0)
	return f


## A pk nothing holds, delivered twice by one query as a delete + insert pair (the
## server's update encoding for a row this mirror never got). It takes ONE reference, and
## the query's membership must say one too: pruning the query then releases exactly that
## reference and leaves another query's hold on the row alone.
func _test_void_pairs_take_one_membership() -> int:
	_fresh()
	var pairs: TableUpdateData = _table(
		&"entity",
		[_ent(9, 1), _ent(9, 1)],
		[_ent(9, 0), _ent(9, 0)],
	)
	_db.apply_transaction_update(_tx([_qset(1, [pairs])]))
	var f: int = _check_i("void pairs: one reference", _db._ref_counts[&"entity"][9], 1)
	_db.apply_transaction_update(_tx([_qset(2, [_table(&"entity", [_ent(9, 1)], [])])]))
	_db.prune_query(1)
	f += _check_i("void pairs: query 2 still holds it", _db._ref_counts[&"entity"].get(9, 0), 1)
	f += _check_b("void pairs: still cached", _db.get_row_by_pk(&"entity", 9) != null, true)
	return f


## Two queries each deliver a void pair for the same pk in one message. Each holds a
## reference of its own, so pruning one leaves the row to the other.
func _test_void_pairs_from_two_queries() -> int:
	_fresh()
	var pair_a: TableUpdateData = _table(&"entity", [_ent(9, 1)], [_ent(9, 0)])
	var pair_b: TableUpdateData = _table(&"entity", [_ent(9, 1)], [_ent(9, 0)])
	_db.apply_transaction_update(_tx([_qset(1, [pair_a]), _qset(2, [pair_b])]))
	var f: int = _check_i("void pairs x2 queries: two references", _db._ref_counts[&"entity"][9], 2)
	f += _check_b("void pairs x2 queries: query 2 holds it", _holds(2, &"entity", 9), true)
	_db.prune_query(1)
	f += _check_b(
		"void pairs x2 queries: survives pruning query 1",
		_db.get_row_by_pk(&"entity", 9) != null,
		true,
	)
	_db.prune_query(2)
	f += _check_i("void pairs x2 queries: gone after both", _db.get_all_rows(&"entity").size(), 0)
	return f


## A before-delete listener that wipes the mirror, on the first evicted row or a later one,
## in this table or in a later table of the message. The wipe reports every cached row
## deleted, but a row whose before-delete the message already reported is not announced
## again, and the row in hand is announced once, by the wipe.
func _test_before_delete_wipe_reports_once() -> int:
	var f: int = 0
	f += _before_delete_wipe_case(&"entity", 1)
	f += _before_delete_wipe_case(&"entity", 2)
	f += _before_delete_wipe_case(&"player", 7)
	return f


func _before_delete_wipe_case(table: StringName, wipe_on: int) -> int:
	_fresh()
	var seed: Array = [
		_table(&"entity", [_ent(1, 10), _ent(2, 20)], []),
		_table(&"player", [_player(7, 1)], []),
	]
	_db.apply_transaction_update(_tx([_qset(1, seed)]))
	var before: PackedStringArray = []
	var deleted: PackedStringArray = []
	_db.row_before_delete.connect(
		func(_table_name: StringName, r: _ModuleTableType) -> void:
			before.append(str(r.id)),
	)
	_db.row_deleted.connect(
		func(_table_name: StringName, r: _ModuleTableType) -> void:
			deleted.append(str(r.id)),
	)
	_db.subscribe_to_before_deletes(
		table,
		func(r: _ModuleTableType) -> void:
			if r.id == wipe_on:
				_db.clear_local_db(),
	)
	var gone: Array = [
		_table(&"entity", [], [_ent(1, 10), _ent(2, 20)]),
		_table(&"player", [], [_player(7, 1)]),
	]
	_db.apply_transaction_update(_tx([_qset(1, gone)]))
	var tag: String = "before-delete wipe on %s %d" % [table, wipe_on]
	var f: int = _check_s("%s: each row announced once" % tag, ", ".join(before), "1, 2, 7")
	f += _check_s("%s: each row deleted once" % tag, ", ".join(deleted), "1, 2, 7")
	return f


## A before-delete listener applies a message of its own that deletes the same row. It is
## queued until the outer message has finished, as the official SDKs process messages one
## at a time: every before-delete listener, including one registered after the trigger,
## still sees the row cached, the row is announced and deleted once, and the queued
## message then finds nothing left to delete.
func _test_nested_delete_from_before_delete() -> int:
	_fresh()
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"entity", [_ent(5, 50)], [])])]))
	_log.clear()
	var applied: Array[bool] = [false] # gdlint: ignore[S6] — one-shot flag the lambda flips
	var present: PackedStringArray = []
	_db.subscribe_to_before_deletes(
		&"entity",
		func(r: _ModuleTableType) -> void:
			if r.id == 5 and not applied[0]:
				applied[0] = true
				_db.apply_table_update(_table(&"entity", [], [_ent(5, 50)])),
	)
	_db.subscribe_to_before_deletes(
		&"entity",
		func(r: _ModuleTableType) -> void:
			present.append(str(_db.get_row_by_pk(&"entity", r.id) != null)),
	)
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"entity", [], [_ent(5, 50)])])]))
	var f: int = _check_s(
		"nested delete: one before-delete, one delete",
		_entity_events(),
		"before:5, delete:5",
	)
	f += _check_s("nested delete: a later listener sees the row cached", ", ".join(present), "true")
	f += _check_i("nested delete: row gone", _db.get_all_rows(&"entity").size(), 0)
	f += _check_b("nested delete: queued message applied", applied[0], true)
	return f


## A callback queues a message, then a later callback of the same message ends the session
## (clear_local_db). The queued message belonged to the ended session, so it is dropped
## rather than applied into the new one; a message queued after the wipe still applies.
func _test_queued_message_dropped_by_wipe() -> int:
	_fresh()
	_db.apply_transaction_update(
		_tx([_qset(1, [_table(&"entity", [_ent(1, 10), _ent(2, 20)], [])])])
	)
	_db.subscribe_to_deletes(
		&"entity",
		func(r: _ModuleTableType) -> void:
			if r.id == 1:
				_db.apply_table_update(_table(&"player", [_player(7, 1)], []))
			elif r.id == 2:
				_db.clear_local_db()
				_db.apply_table_update(_table(&"player", [_player(8, 1)], [])),
	)
	_db.apply_transaction_update(
		_tx([_qset(1, [_table(&"entity", [], [_ent(1, 10), _ent(2, 20)])])])
	)
	var f: int = _check_b(
		"queued then wiped: old-session row dropped",
		_db.get_row_by_pk(&"player", 7) == null,
		true,
	)
	f += _check_b(
		"queued then wiped: new-session row applied",
		_db.get_row_by_pk(&"player", 8) != null,
		true,
	)
	return f


## prune_query from inside a row callback: the drop is queued behind the current message,
## and the pruned query's membership is not re-created by it.
func _test_prune_from_callback() -> int:
	_fresh()
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"entity", [_ent(3, 30)], [])])]))
	_db.apply_transaction_update(_tx([_qset(2, [_table(&"player", [_player(4, 3)], [])])]))
	_db.subscribe_to_inserts(
		&"player",
		func(r: _ModuleTableType) -> void:
			if r.id == 5:
				_db.prune_query(1),
	)
	_db.apply_transaction_update(_tx([_qset(2, [_table(&"player", [_player(5, 3)], [])])]))
	var f: int = _check_b(
		"prune in callback: row evicted",
		_db.get_row_by_pk(&"entity", 3) == null,
		true,
	)
	f += _check_b("prune in callback: membership gone", _db._query_rows.has(1), false)
	f += _check_b("prune in callback: other query kept", _holds(2, &"player", 4), true)
	return f


## The client relays LocalDatabase's before-delete signal instead of connecting a
## forwarder to it, so the forwarding does not count as a listener: with nothing connected
## to either signal, a delete skips reading which rows it evicts. A listener on the relay
## hears each evicted row while it is still cached, before a listener connected to
## LocalDatabase itself, and a wipe announces the rows it drops to both.
func _test_before_delete_relay() -> int:
	_fresh()
	var client: Node = load(CLIENT_SCRIPT).new()
	_db.register_before_delete_relay(client.row_before_delete)
	_db.apply_transaction_update(
		_tx([_qset(1, [_table(&"player", [_player(7, 1), _player(8, 1)], [])])])
	)
	var f: int = _check_b(
		"relay: nothing listening",
		_db._has_before_delete_consumers(&"player"),
		false,
	)
	var heard: PackedStringArray = []
	client.row_before_delete.connect(
		func(_t: StringName, r: _ModuleTableType) -> void:
			var cached: bool = _db.get_row_by_pk(&"player", r.id) != null
			heard.append("relay:%d:%s" % [r.id, "cached" if cached else "gone"]),
	)
	f += _check_b("relay: its listener counts", _db._has_before_delete_consumers(&"player"), true)
	_db.row_before_delete.connect(
		func(_t: StringName, r: _ModuleTableType) -> void:
			heard.append("db:%d" % r.id),
	)
	_db.apply_transaction_update(_tx([_qset(1, [_table(&"player", [], [_player(7, 1)])])]))
	f += _check_s("relay: delete announced", ", ".join(heard), "relay:7:cached, db:7")
	heard.clear()
	_db.clear_local_db()
	f += _check_s("relay: wipe announced", ", ".join(heard), "relay:8:gone, db:8")
	client.free()
	return f

# --- harness ---


func _fresh() -> void:
	if _db != null:
		_db.free()
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"entity", &"player", &"flat"]
	schema.types[&"entity"] = _EntityRow
	schema.tables[&"entity"] = _EntityRow
	schema.types[&"player"] = _PlayerRow
	schema.tables[&"player"] = _PlayerRow
	schema.types[&"flat"] = _FlatRow
	schema.tables[&"flat"] = _FlatRow
	_db = LocalDatabase.new(schema)
	_index = _TagIndex.new(_db)
	_log.clear()
	_db.subscribe_to_inserts(
		&"entity",
		func(r: _ModuleTableType) -> void:
			_log.append("insert:%d" % r.id),
	)
	_db.subscribe_to_updates(
		&"entity",
		func(_o: _ModuleTableType, r: _ModuleTableType) -> void:
			_log.append("update:%d" % r.id),
	)
	_db.subscribe_to_before_deletes(
		&"entity",
		func(r: _ModuleTableType) -> void:
			_log.append("before:%d" % r.id),
	)
	_db.subscribe_to_deletes(
		&"entity",
		func(r: _ModuleTableType) -> void:
			_log.append("delete:%d" % r.id),
	)
	_db.subscribe_to_transactions_completed(
		&"entity",
		func() -> void:
			_log.append("done"),
	)


func _seed_player_and_entity() -> void:
	_db.apply_transaction_update(
		_tx(
			[
				_qset(
					1,
					[_table(&"player", [_player(1, 5)], []), _table(&"entity", [_ent(5, 50)], [])],
				)
			]
		),
	)
	_log.clear()


## The entity table's row events, without the terminator.
func _entity_events() -> String:
	var events: PackedStringArray = []
	for e: String in _log:
		if e != "done":
			events.append(e)
	return ", ".join(events)


func _holds(query_id: int, table: StringName, pk: int) -> bool:
	var tables: Dictionary = _db._query_rows.get(query_id, { })
	var membership: Dictionary = tables.get(table, { })
	return membership.has(pk)


func _table(table_name: StringName, inserts: Array, deletes: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	u.inserts.assign(inserts)
	u.deletes.assign(deletes)
	return u


func _qset(query_id: int, tables: Array) -> DatabaseUpdateData:
	var d: DatabaseUpdateData = DatabaseUpdateData.new()
	d.query_id = QueryIdData.new()
	d.query_id.id = query_id
	d.tables.assign(tables)
	return d


func _tx(sets: Array) -> TransactionUpdateMessage:
	var m: TransactionUpdateMessage = TransactionUpdateMessage.new()
	m.query_sets.assign(sets)
	return m


func _ent(id: int, p_tag: int) -> _EntityRow:
	return _EntityRow.new(id, p_tag)


func _player(id: int, entity_id: int) -> _PlayerRow:
	return _PlayerRow.new(id, entity_id)


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


class _EntityRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var tag: int = 0


	func _init(p_id: int = 0, p_tag: int = 0) -> void:
		id = p_id
		tag = p_tag


class _PlayerRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var entity_id: int = 0


	func _init(p_id: int = 0, p_entity_id: int = 0) -> void:
		id = p_id
		entity_id = p_entity_id


class _FlatRow:
	extends _ModuleTableType
	@export var value: int = 0


	func _init(p_value: int = 0) -> void:
		value = p_value


## A unique index on entity.tag, the shape codegen emits.
class _TagIndex:
	extends _ModuleTableUniqueIndex
	var _cache: Dictionary = { }


	func _init(db: LocalDatabase) -> void:
		_table_name = &"entity"
		_field_name = &"tag"
		_connect_cache_to_db(_cache, db)


	func find(value: int) -> _ModuleTableType:
		return _cache.get(value)

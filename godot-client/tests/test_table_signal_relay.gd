# A generated table wrapper's typed inserted / updated / deleted signals are emitted by
# LocalDatabase itself (register_table_relays), not by a listener the wrapper registers
# to re-emit them.
#
# Pinned through the real generated Blackholio bindings (BlackholioEntityTable):
#   - each signal carries the rows the matching listener gets, wipe included;
#   - it fires before the table's listeners, where the wrapper's listener used to sit;
#   - the wrapper registers no listener of its own;
#   - two wrappers on one database both get every row;
#   - a freed wrapper is skipped, and pruned when the next one registers;
#   - with the client's signals relayed too: wrapper signal, table listener, client
#     signal, LocalDatabase's own signal.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_table_signal_relay.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## Loaded by path rather than named: a --script main loop compiles before autoloads.
const CLIENT_SCRIPT: String = "res://addons/SpacetimeDB/core/spacetimedb_client.gd"

var _total: int = 0
var _db: LocalDatabase = null
## What reached the signals and listeners, in order, as short strings.
var _log: PackedStringArray = []


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	_db = LocalDatabase.new(SpacetimeDBSchema.new("Blackholio"))
	var table: BlackholioEntityTable = BlackholioEntityTable.new(_db)
	f += _check_b("no wrapper listeners", _db._insert_listeners_by_table.has(&"entity"), false)
	table.inserted.connect(_on_inserted.bind("a"))
	table.updated.connect(_on_updated.bind("a"))
	table.deleted.connect(_on_deleted.bind("a"))
	table.on_insert(_on_listener_insert)

	_apply([_entity(1, 10), _entity(2, 20)], [])
	f += _check_s("insert: signal then listener", _log, "ins a 1,listener 1,ins a 2,listener 2")
	_apply([_entity(1, 11)], [_entity(1, 10)])
	f += _check_s("update: old and new", _log, "upd a 10>11")
	_apply([], [_entity(2, 20)])
	f += _check_s("delete", _log, "del a 2")
	_db.clear_local_db()
	f += _check_s("wipe: delete per row", _log, "del a 1")

	var second: BlackholioEntityTable = BlackholioEntityTable.new(_db)
	second.inserted.connect(_on_inserted.bind("b"))
	_apply([_entity(3, 30)], [])
	f += _check_s("two wrappers: both", _log, "ins a 3,ins b 3,listener 3")

	second = null # the only reference: the wrapper is freed here
	_apply([_entity(4, 40)], [])
	f += _check_s("freed wrapper: skipped", _log, "ins a 4,listener 4")
	f += _check_i("freed wrapper: still listed", _db._insert_relays_by_table[&"entity"].size(), 2)
	var third: BlackholioEntityTable = BlackholioEntityTable.new(_db)
	f += _check_i("freed wrapper: pruned", _db._insert_relays_by_table[&"entity"].size(), 2)
	f += _check_b(
		"third registered",
		_db._insert_relays_by_table[&"entity"].has(third.inserted),
		true,
	)

	# As a game runs: the client's row signals relayed as well as the wrapper's.
	var client: Node = (load(CLIENT_SCRIPT) as GDScript).new()
	_db.register_row_relays(
		client.row_inserted,
		client.row_updated,
		client.row_before_delete,
		client.row_deleted,
		client.row_transactions_completed,
	)
	client.row_inserted.connect(_on_row_inserted.bind("client"))
	_db.row_inserted.connect(_on_row_inserted.bind("db"))
	_apply([_entity(5, 50)], [])
	f += _check_s("with the client: full order", _log, "ins a 5,listener 5,client 5,db 5")
	client.free()
	_db.free()
	return f


func _on_inserted(row: BlackholioEntity, tag: String) -> void:
	_log.append("ins %s %d" % [tag, row.entity_id])


func _on_updated(old_row: BlackholioEntity, new_row: BlackholioEntity, tag: String) -> void:
	_log.append("upd %s %d>%d" % [tag, old_row.mass, new_row.mass])


func _on_deleted(row: BlackholioEntity, tag: String) -> void:
	_log.append("del %s %d" % [tag, row.entity_id])


func _on_row_inserted(_table_name: StringName, row: _ModuleTableType, tag: String) -> void:
	_log.append("%s %d" % [tag, row.entity_id])


func _on_listener_insert(row: _ModuleTableType) -> void:
	_log.append("listener %d" % row.entity_id)


func _entity(id: int, mass: int) -> BlackholioEntity:
	return BlackholioEntity.create(id, BlackholioDbVector2.create(0.0, 0.0), mass)


func _apply(inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"entity"
	u.inserts.assign(inserts)
	u.deletes.assign(deletes)
	_db.apply_table_update(u)


## Compares the log so far with [param want], then clears it.
func _check_s(label: String, got: PackedStringArray, want: String) -> int:
	_total += 1
	var joined: String = ",".join(got)
	_log.clear()
	if joined == want:
		print("PASS  %s = %s" % [label, joined])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, joined, want])
	return 1


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

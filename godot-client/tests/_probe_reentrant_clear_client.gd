# Reachability probe for the wipe-during-dispatch fix: does a REAL SpacetimeDBClient
# wipe its mirror from inside a row callback?
#
# The path under test is game code that restarts the session from a row handler
# ("the config row changed, reconnect to the new host"):
#     func _on_config_inserted(row): client.disconnect_db(); client.connect_db(url, db)
# connect_db() wipes the mirror SYNCHRONOUSLY (it refuses only while the socket is open,
# and disconnect_db just closed it), so the wipe lands underneath the apply_table_update
# frame that is still walking the rest of the batch.
#
# No socket: base_url points at a closed loopback port, so the token request fails on its
# own time and nothing here waits for it. Rows are fed straight into the client's own
# LocalDatabase, which is what the receive path does.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_reentrant_clear_client.gd

extends SceneTree

const CLOSED_URL: String = "http://127.0.0.1:1"
const TABLE: StringName = &"entity"

var _client: Node
var _restarted: bool = false


func _initialize() -> void:
	root.call_deferred(&"add_child", _mk_client())
	# process_frame is the SceneTree's own signal, not the root Window's — a probe that
	# connects it on get_root() faults inside _initialize, and a fault there unwinds past
	# every quit() and leaves a headless run spinning.
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _mk_client() -> Node:
	var script: GDScript = load("res://addons/SpacetimeDB/core/spacetimedb_client.gd")
	var client: Node = script.new()
	client.module_name = "blackholio"
	client.schema_path = "res://spacetime_bindings/schema"
	client.base_url = CLOSED_URL
	client.database_name = "probe"
	client.token_save_path = "user://__probe_reentrant_token.dat"
	client.save_token = false
	_client = client
	return client


func _run() -> void:
	_client.initialize_and_connect()
	var db: LocalDatabase = _client._local_db
	db.subscribe_to_inserts(TABLE, _on_insert)

	var gen_before: int = db._generation
	_apply(db, [_entity(1), _entity(2), _entity(3)])

	print("session restarted from the callback: %s" % _restarted)
	print("mirror wiped mid-dispatch (generation moved): %s" % [db._generation != gen_before])
	print("rows cached after the batch: %d" % db.get_all_rows(TABLE).size())
	print("rows with a refcount: %d" % (db._ref_counts.get(TABLE, { }) as Dictionary).size())

	# What the stranded rows cost: the server deletes them and the mirror keeps them.
	# Array, not PackedInt32Array: a lambda captures a local by value and a Packed*Array
	# is a value type, so appends inside the callback would never reach this one (#69014).
	var deleted: Array[int] = [] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		TABLE,
		func(row: _ModuleTableType) -> void:
			deleted.append(row.get(&"entity_id")),
	)
	_apply_delete(db, [_entity(2), _entity(3)])
	print("on_delete fired for: %s" % [deleted])
	print("rows still cached: %d" % db.get_all_rows(TABLE).size())
	quit(0)


func _on_insert(row: _ModuleTableType) -> void:
	if row.get(&"entity_id") != 1 or _restarted:
		return
	_restarted = true
	_client.disconnect_db()
	_client.connect_db(CLOSED_URL, "probe")


func _entity(id: int) -> Resource:
	var script: GDScript = load("res://spacetime_bindings/schema/types/blackholio_entity.gd")
	var row: Resource = script.new()
	row.set(&"entity_id", id)
	return row


func _apply(db: LocalDatabase, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = TABLE
	var ins: Array[Resource] = []
	ins.assign(rows)
	u.inserts = ins
	db.apply_table_update(u)


func _apply_delete(db: LocalDatabase, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = TABLE
	var del: Array[Resource] = []
	del.assign(rows)
	u.deletes = del
	db.apply_table_update(u)

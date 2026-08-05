# Probe: RowReceiver lifecycle against a real LocalDatabase attached to the real
# generated Blackholio module client (the autoload the receiver resolves through).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_row_receiver.gd
#
# Exit code = number of failed checks.
extends SceneTree

var _total: int = 0
var _fails: int = 0
var _db: LocalDatabase
var _receiver_script: GDScript = null
var _client: SpacetimeDBClient

# Per-receiver counters, keyed by receiver instance id.
var _inserts: Dictionary = { }
var _updates: Dictionary = { }
var _deletes: Dictionary = { }
var _txn_done: Dictionary = { }


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _drive()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _drive() -> void:
	# Resolved by path, not by the `SpacetimeDB` global: this script IS the main
	# loop, so it compiles before the autoload names are registered.
	# Loaded here, not at member-init or by class_name: row_receiver.gd reads the
	# `SpacetimeDB` autoload global, which is registered after the main-loop script
	# (and everything it statically depends on) has already compiled.
	_receiver_script = load("res://addons/SpacetimeDB/nodes/row_receiver/row_receiver.gd")
	var autoload: Node = root.get_node_or_null(^"/root/SpacetimeDB")
	if autoload == null:
		printerr("no SpacetimeDB autoload in the tree")
		_fails += 1
		return
	_client = autoload.get("Blackholio")
	if _client == null:
		printerr("no Blackholio client on the SpacetimeDB autoload")
		_fails += 1
		return
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new(
		"blackholio",
		"res://__no_schema__",
		false,
	)
	schema.raw_table_names = [&"circle", &"entity"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"circle"] = &"entity_id"
	_db._primary_key_cache[&"entity"] = &"entity_id"
	_client._local_db = _db
	_client.add_child(_db)

	await _scenario_replay_and_live()
	await _scenario_reentry()
	await _scenario_rapid_reentry()
	await _scenario_table_switch()
	await _scenario_free_while_subscribed()
	await _scenario_two_receivers()
	await _scenario_free_inside_callback()
	await _scenario_queue_free_inside_callback()
	await _scenario_self_free_inside_callback()

# --- scenarios ---


# Rows already in the mirror are replayed on entry; later traffic arrives once.
func _scenario_replay_and_live() -> void:
	_apply_inserts(&"circle", [_circle(1), _circle(2)])
	var r: Node = await _add_receiver()
	_check("replay: existing rows delivered", _inserts[r.get_instance_id()], 2)
	_check("replay: one transactions_completed", _txn_done[r.get_instance_id()], 1)

	_apply_inserts(&"circle", [_circle(3)])
	_check("live insert delivered once", _inserts[r.get_instance_id()], 3)
	_apply_update(&"circle", _circle(3), _circle(3, 9))
	_check("live update delivered once", _updates[r.get_instance_id()], 1)
	_apply_deletes(&"circle", [_circle(3, 9)])
	_check("live delete delivered once", _deletes[r.get_instance_id()], 1)

	_free_receiver(r)
	_clear_table(&"circle")


# Leaving and re-entering the tree re-subscribes exactly once — a second
# subscription would double every later row.
func _scenario_reentry() -> void:
	_apply_inserts(&"circle", [_circle(1)])
	var r: Node = await _add_receiver()
	_check("reentry: first replay", _inserts[r.get_instance_id()], 1)

	root.remove_child(r)
	await process_frame
	_apply_inserts(&"circle", [_circle(2)])
	_check("reentry: nothing delivered while out of tree", _inserts[r.get_instance_id()], 1)

	root.add_child(r)
	await process_frame
	await process_frame
	# Two rows are in the mirror now, both replayed on the second entry.
	_check("reentry: second replay", _inserts[r.get_instance_id()], 3)

	_apply_inserts(&"circle", [_circle(3)])
	_check("reentry: live insert delivered ONCE", _inserts[r.get_instance_id()], 4)

	_free_receiver(r)
	_clear_table(&"circle")


# Leave and re-enter inside one frame, while the first entry's deferred
# subscription pass is still queued.
func _scenario_rapid_reentry() -> void:
	_apply_inserts(&"circle", [_circle(1)])
	var r: Node = _new_receiver()
	root.add_child(r)
	root.remove_child(r)
	root.add_child(r)
	await process_frame
	await process_frame
	_apply_inserts(&"circle", [_circle(2)])
	_check("rapid reentry: live insert delivered ONCE", _live_count(r), 1)

	_free_receiver(r)
	_clear_table(&"circle")


# table_to_receive reassigned at runtime, then a re-entry: the receiver must
# follow the new table and stop hearing the old one.
func _scenario_table_switch() -> void:
	var r: Node = await _add_receiver()
	var before: int = _inserts[r.get_instance_id()]
	r.table_to_receive = BlackholioEntity.new()
	root.remove_child(r)
	await process_frame
	root.add_child(r)
	await process_frame
	await process_frame

	_apply_inserts(&"circle", [_circle(7)])
	_check("switch: old table no longer delivered", _inserts[r.get_instance_id()] - before, 0)
	_apply_inserts(&"entity", [_entity(7)])
	_check("switch: new table delivered", _inserts[r.get_instance_id()] - before, 1)

	_free_receiver(r)
	_clear_table(&"circle")
	_clear_table(&"entity")


# A receiver freed while subscribed must not leave a Callable behind that the
# database calls on the next row event.
func _scenario_free_while_subscribed() -> void:
	var r: Node = await _add_receiver()
	var id: int = r.get_instance_id()
	r.free() # not queue_free: the listener must be gone before the next line
	_apply_inserts(&"circle", [_circle(4)])
	_check("free while subscribed: no delivery to a dead node", _inserts.get(id, 0), 0)
	var listeners: Array = _db._insert_listeners_by_table.get(&"circle", [])
	_check("free while subscribed: listener removed", listeners.size(), 0)
	_clear_table(&"circle")


# Two receivers on one table each get every row exactly once.
func _scenario_two_receivers() -> void:
	var a: Node = await _add_receiver()
	var b: Node = await _add_receiver()
	_apply_inserts(&"circle", [_circle(5)])
	_check("two receivers: a got it once", _inserts[a.get_instance_id()], 1)
	_check("two receivers: b got it once", _inserts[b.get_instance_id()], 1)
	_free_receiver(a)
	_free_receiver(b)
	_clear_table(&"circle")

# One receiver's row handler frees another receiver — the listener snapshot the
# database is iterating still holds the dead node's Callable.
func _scenario_free_inside_callback() -> void:
	var a: Node = await _add_receiver()
	var b: Node = await _add_receiver()
	var b_id: int = b.get_instance_id()
	a.insert.connect(
		func(_row: _ModuleTableType) -> void:
			if is_instance_valid(b):
				root.remove_child(b)
				b.free(),
	)
	_apply_inserts(&"circle", [_circle(10), _circle(11), _circle(12)])
	_check("free-in-callback: a saw every row", _inserts[a.get_instance_id()], 3)
	_check("free-in-callback: mirror holds every row", _db.get_all_rows(&"circle").size(), 3)
	print("       b saw %d rows before it was freed" % _inserts[b_id])
	_free_receiver(a)
	_clear_table(&"circle")


# The same shape with queue_free(), which defers the free past the batch.
func _scenario_queue_free_inside_callback() -> void:
	var a: Node = await _add_receiver()
	var b: Node = await _add_receiver()
	a.insert.connect(
		func(_row: _ModuleTableType) -> void:
			if is_instance_valid(b):
				b.queue_free(),
	)
	_apply_inserts(&"circle", [_circle(20), _circle(21), _circle(22)])
	_check("queue_free-in-callback: a saw every row", _inserts[a.get_instance_id()], 3)
	_check(
		"queue_free-in-callback: mirror holds every row",
		_db.get_all_rows(&"circle").size(),
		3,
	)
	await process_frame
	_free_receiver(a)
	_clear_table(&"circle")


# A receiver that frees its OWN owner from inside its own row handler.
func _scenario_self_free_inside_callback() -> void:
	var a: Node = await _add_receiver()
	var id: int = a.get_instance_id()
	a.insert.connect(
		func(_row: _ModuleTableType) -> void:
			if is_instance_valid(a):
				root.remove_child(a)
				a.free(),
	)
	_apply_inserts(&"circle", [_circle(30), _circle(31)])
	_check("self-free-in-callback: mirror holds every row", _db.get_all_rows(&"circle").size(), 2)
	print("       receiver saw %d rows before freeing itself" % _inserts[id])
	_clear_table(&"circle")


# --- harness ---


func _new_receiver() -> Node:
	var r: Node = _receiver_script.new()
	r.table_to_receive = BlackholioCircle.new()
	var id: int = r.get_instance_id()
	_inserts[id] = 0
	_updates[id] = 0
	_deletes[id] = 0
	_txn_done[id] = 0
	r.insert.connect(
		func(_row: _ModuleTableType) -> void:
			_inserts[id] += 1,
	)
	r.update.connect(
		func(_p: _ModuleTableType, _row: _ModuleTableType) -> void:
			_updates[id] += 1,
	)
	r.delete.connect(
		func(_row: _ModuleTableType) -> void:
			_deletes[id] += 1,
	)
	r.transactions_completed.connect(
		func() -> void:
			_txn_done[id] += 1,
	)
	return r


func _add_receiver() -> Node:
	var r: Node = _new_receiver()
	root.add_child(r)
	await process_frame
	await process_frame
	return r


func _free_receiver(r: Node) -> void:
	if is_instance_valid(r):
		if r.is_inside_tree():
			root.remove_child(r)
		r.free()


func _live_count(r: Node) -> int:
	# Inserts seen since the last replay: the caller knows the replay size, so this
	# just returns the delta the scenario cares about (replay of 1 + live of 1 = 2).
	return _inserts[r.get_instance_id()] - 1


func _circle(id: int, player: int = 0) -> BlackholioCircle:
	var c: BlackholioCircle = BlackholioCircle.new()
	c.entity_id = id
	c.player_id = player
	return c


func _entity(id: int) -> BlackholioEntity:
	var e: BlackholioEntity = BlackholioEntity.new()
	e.entity_id = id
	return e


func _clear_table(table: StringName) -> void:
	var rows: Array[_ModuleTableType] = _db.get_all_rows(table)
	if rows.is_empty():
		return
	_apply_deletes(table, rows)


func _apply_inserts(table: StringName, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.inserts = typed
	_db.apply_table_update(u)


func _apply_deletes(table: StringName, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.deletes = typed
	_db.apply_table_update(u)


func _apply_update(table: StringName, old_row: Resource, new_row: Resource) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var ins: Array[Resource] = []
	ins.assign([new_row])
	var del: Array[Resource] = []
	del.assign([old_row])
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u)


func _check(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	_fails += 1

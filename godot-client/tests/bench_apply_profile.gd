# Saturated worst-case profile of LocalDatabase.apply_table_update — the main-thread
# apply path. Splits the budget across insert / update(detect) / delete waves, for
# three rows. The all-primitive row is written here, so it carries no generated
# `_row_eq` and its update detection runs the generic LocalDatabase._rows_equal walk.
# BlackholioEntity (a nested record column) and BlackholioCircle (nested record plus a
# float) are generated rows, so theirs runs the typed comparison codegen emits. Reveals
# where the apply budget goes under load, so the next optimization target is measured,
# not guessed. The `game` row repeats the entity row as a game runs it: with
# SpacetimeDBClient's signal forwarders connected, as they always are, and a unique index
# on the primary key, as generated bindings register. Each row signal then runs a
# handler and each change an index hook, which the bare-LocalDatabase rows never pay.
extends SceneTree

## Loaded by path rather than named: a --script main loop compiles before autoloads
## register, and the client script is what the addon's autoload is built from.
const CLIENT_SCRIPT: String = "res://addons/SpacetimeDB/core/spacetimedb_client.gd"
const N: int = 100000
const REPS: int = 7


class PrimRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int
	@export var a: int
	@export var b: int
	@export var c: float
	@export var d: float
	@export var e: int


func _prim(id: int, salt: int) -> PrimRow:
	var r: PrimRow = PrimRow.new()
	r.id = id
	r.a = id
	r.b = id * 2
	r.c = 1.0
	r.d = 2.0
	r.e = salt
	return r


func _ent(id: int, mass: int) -> BlackholioEntity:
	var p: BlackholioDbVector2 = BlackholioDbVector2.new()
	p.x = 1.0
	p.y = 2.0
	return BlackholioEntity.create(id, p, mass)


# The changed column is `direction`, the nested record a moving circle rewrites.
func _circ(id: int, salt: int) -> BlackholioCircle:
	var d: BlackholioDbVector2 = BlackholioDbVector2.create(0.6, 0.8 - salt * 0.5)
	return BlackholioCircle.create(id, id % 64, d, 1.25, 1700000000000)


func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for r: int in REPS:
		var s: int = Time.get_ticks_usec()
		fn.call()
		var el: int = Time.get_ticks_usec() - s
		if el < best:
			best = el
	return best


func _seed(db: LocalDatabase, table: StringName, pk: StringName, props: Array[StringName]) -> void:
	db._primary_key_cache[table] = pk
	db._row_property_cache[table] = props
	db._tables[table] = { }


func _wave(table: StringName, ins: Array[Resource], del: Array[Resource]) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	u.inserts.assign(ins)
	u.deletes.assign(del)
	return u


func _run(
		label: String,
		table: StringName,
		pk: StringName,
		props: Array[StringName],
		mk: Callable,
		game: bool = false,
) -> void:
	var empty: Array[Resource] = []
	# Pre-build row sets once (outside timing).
	var first: Array[Resource] = []
	var second: Array[Resource] = []
	for i: int in N:
		first.append(mk.call(i, 0))
		second.append(mk.call(i, 1)) # same pk, changed non-pk field -> real update

	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("x"))
	_seed(db, table, pk, props)
	var client: Node = null
	var index: _ModuleTableUniqueIndex = null
	if game:
		index = _ModuleTableUniqueIndex.new()
		index._table_name = table
		index._field_name = pk
		index._connect_cache_to_db({ }, db)
		client = (load(CLIENT_SCRIPT) as GDScript).new()
		db.row_inserted.connect(client._forward_row_inserted)
		db.row_updated.connect(client._forward_row_updated)
		db.register_before_delete_relay(client.row_before_delete)
		db.row_deleted.connect(client._forward_row_deleted)
		db.row_transactions_completed.connect(client._forward_row_transactions_completed)

	# INSERT wave (subscribe): empty table -> N inserts.
	var ins_us: int = _best(
		func() -> void:
			db._tables[table] = { }
			db._ref_counts[table] = { }
			db.apply_table_update(_wave(table, first, empty))
	)

	# UPDATE wave (detect_updates): deletes=old, inserts=new same pks -> _row_eq fires.
	# Re-seed to a full table each rep, then apply the update.
	var upd_us: int = _best(
		func() -> void:
			db._tables[table] = { }
			db._ref_counts[table] = { }
			db.apply_table_update(_wave(table, first, empty)) # setup (counted, but same both rows)
			db.apply_table_update(_wave(table, second, first))
	) # the update under test

	# DELETE wave: full table -> N deletes.
	var del_us: int = _best(
		func() -> void:
			db._tables[table] = { }
			db._ref_counts[table] = { }
			db.apply_table_update(_wave(table, first, empty)) # setup
			db.apply_table_update(_wave(table, empty, first))
	) # the delete under test

	# The update/delete waves each pay one insert wave as setup, so the per-row cost
	# of the operation under test is the difference. Printed explicitly — the derived
	# number is the one quoted in docs/performance.md, so the bench, not the reader,
	# owns the arithmetic. (Subtracting two best-of-7 minima biases the result
	# slightly high; the waves are stable enough that it stays within run variance.)
	print(
		(
			"[%s] N=%d  insert=%.2fms (%.0fns/row)  update=%.2fms (%.0fns/row)"
			+ "  delete=%.2fms (%.0fns/row)"
		)
		% [
			label,
			N,
			ins_us / 1000.0,
			ins_us * 1000.0 / N,
			(upd_us - ins_us) / 1000.0,
			(upd_us - ins_us) * 1000.0 / N,
			(del_us - ins_us) / 1000.0,
			(del_us - ins_us) * 1000.0 / N,
		]
	)
	if client != null:
		client.free()
	db.free()


func _initialize() -> void:
	_run(
		"prim ",
		&"primrow",
		&"id",
		[&"id", &"a", &"b", &"c", &"d", &"e"] as Array[StringName],
		_prim,
	)
	_run(
		"entity",
		&"entity",
		&"entity_id",
		[&"entity_id", &"position", &"mass"] as Array[StringName],
		_ent,
	)
	_run(
		"circle",
		&"circle",
		&"entity_id",
		[&"entity_id", &"player_id", &"direction", &"speed", &"last_split_time"] as Array[StringName],
		_circ,
	)
	_run(
		"game  ",
		&"entity",
		&"entity_id",
		[&"entity_id", &"position", &"mass"] as Array[StringName],
		_ent,
		true,
	)
	quit()

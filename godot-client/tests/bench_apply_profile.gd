# Saturated worst-case profile of LocalDatabase.apply_table_update — the main-thread
# apply path. Splits the budget across insert / update(detect) / delete waves, for
# both a nested-object row (BlackholioEntity, _rows_equal bails early) and an
# all-primitive row (full _rows_equal walk). Reveals where the apply budget goes
# under load, so the next optimization target is measured, not guessed.
extends SceneTree

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
	r.id = id; r.a = id; r.b = id * 2; r.c = 1.0; r.d = 2.0; r.e = salt
	return r

func _ent(id: int, mass: int) -> BlackholioEntity:
	var p: BlackholioDbVector2 = BlackholioDbVector2.new()
	p.x = 1.0; p.y = 2.0
	return BlackholioEntity.create(id, p, mass)

func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for r: int in REPS:
		var s: int = Time.get_ticks_usec()
		fn.call()
		var el: int = Time.get_ticks_usec() - s
		if el < best: best = el
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

func _run(label: String, table: StringName, pk: StringName, props: Array[StringName], mk: Callable) -> void:
	var empty: Array[Resource] = []
	# Pre-build row sets once (outside timing).
	var first: Array[Resource] = []
	var second: Array[Resource] = []
	for i: int in N:
		first.append(mk.call(i, 0))
		second.append(mk.call(i, 1))   # same pk, changed non-pk field -> real update

	var db: LocalDatabase = LocalDatabase.new(SpacetimeDBSchema.new("x"))
	_seed(db, table, pk, props)

	# INSERT wave (subscribe): empty table -> N inserts.
	var ins_us: int = _best(func() -> void:
		db._tables[table] = { }; db._ref_counts[table] = { }
		db.apply_table_update(_wave(table, first, empty)))

	# UPDATE wave (detect_updates): deletes=old, inserts=new same pks -> _rows_equal fires.
	# Re-seed to a full table each rep, then apply the update.
	var upd_us: int = _best(func() -> void:
		db._tables[table] = { }; db._ref_counts[table] = { }
		db.apply_table_update(_wave(table, first, empty))      # setup (counted, but same both rows)
		db.apply_table_update(_wave(table, second, first)))    # the update under test

	# DELETE wave: full table -> N deletes.
	var del_us: int = _best(func() -> void:
		db._tables[table] = { }; db._ref_counts[table] = { }
		db.apply_table_update(_wave(table, first, empty))      # setup
		db.apply_table_update(_wave(table, empty, first)))     # the delete under test

	print("[%s] N=%d  insert=%.2fms (%.0fns/row)  update+setup=%.2fms  delete+setup=%.2fms"
		% [label, N, ins_us/1000.0, ins_us*1000.0/N, upd_us/1000.0, del_us/1000.0])

func _initialize() -> void:
	_run("prim ", &"primrow", &"id", [&"id", &"a", &"b", &"c", &"d", &"e"] as Array[StringName], _prim)
	_run("entity", &"entity", &"entity_id", [&"entity_id", &"position", &"mass"] as Array[StringName], _ent)
	quit()

# In-process micro-benchmark of LocalDatabase.apply_table_update — no server, no
# network, no fps cap, so it saturates the apply hot path by construction (unlike the
# bot-load bench_load/bench_measure, which are network-bound and can hide per-row cost).
# Times insert / update / delete of N rows over ITERS rounds for a PK table and a
# PK-less table, with and without query_id membership tracking, and reports rows/sec.
#
#   <godot> --headless --path . --script res://benchmark/micro_bench.gd
#
# To compare branches (e.g. an apply-path change): run it on each branch and diff the
# rows/sec. It uses string-based get()/callv() so it compiles on any branch regardless
# of the _row_property_cache rename or the apply_table_update(query_id) signature.
extends SceneTree

const N: int = 5000
const ITERS: int = 40


class _Row:
	extends _ModuleTableType
	@export var id: int = 0
	@export var val: int = 0


var _supports_query_id: bool = false


func _make_rows(count: int, val: int) -> Array[Resource]:
	var rows: Array[Resource] = []
	rows.resize(count)
	for i: int in count:
		var r: _Row = _Row.new()
		r.id = i
		r.val = val
		rows[i] = r
	return rows


func _tu(table: StringName, inserts: Array[Resource], deletes: Array[Resource]) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	u.inserts.assign(inserts)
	u.deletes.assign(deletes)
	return u


func _new_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("bench", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk", &"pkless"]
	var db: LocalDatabase = LocalDatabase.new(schema)
	# Seed the PK + property caches directly so no disk schema is needed.
	var pkc: Dictionary = db.get(&"_primary_key_cache")
	pkc[&"pk"] = &"id"
	pkc[&"pkless"] = &""
	var props: Array[StringName] = [&"id", &"val"] as Array[StringName]
	var rc: Variant = db.get(&"_row_property_cache") # null on the pre-rename branch
	if rc != null:
		rc[&"pk"] = props
		rc[&"pkless"] = props
	else:
		db.get(&"_pk_less_property_cache")[&"pkless"] = props
	return db


func _apply(db: LocalDatabase, u: TableUpdateData, query_id: int) -> void:
	if _supports_query_id:
		db.callv(&"apply_table_update", [u, query_id])
	else:
		db.apply_table_update(u)


func _phase(label: String, table: StringName, query_id: int) -> void:
	var db: LocalDatabase = _new_db()
	var fresh: Array[Resource] = _make_rows(N, 1)
	var updated: Array[Resource] = _make_rows(N, 2)
	var t_ins: int = 0
	var t_upd: int = 0
	var t_del: int = 0
	for _it: int in ITERS:
		var t0: int = Time.get_ticks_usec()
		_apply(db, _tu(table, fresh, [] as Array[Resource]), query_id) # pure insert
		t_ins += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		_apply(db, _tu(table, updated, fresh), query_id) # delete-old + insert-new = update
		t_upd += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		_apply(db, _tu(table, [] as Array[Resource], updated), query_id) # pure delete
		t_del += Time.get_ticks_usec() - t0
	var total: int = N * ITERS
	print(
		(
				"%-22s insert=%9.0f upd=%9.0f del=%9.0f rows/s"
				% [label, total / (t_ins / 1e6), total / (t_upd / 1e6), total / (t_del / 1e6)]
		),
	)


func _initialize() -> void:
	_supports_query_id = _new_db().get(&"_row_property_cache") != null
	print("micro_bench N=%d ITERS=%d query_id_support=%s" % [N, ITERS, _supports_query_id])
	_phase("PK (no query_id)", &"pk", -1)
	_phase("PK-less (no query_id)", &"pkless", -1)
	if _supports_query_id:
		_phase("PK (query_id)", &"pk", 1)
		_phase("PK-less (query_id)", &"pkless", 1)
	quit(0)

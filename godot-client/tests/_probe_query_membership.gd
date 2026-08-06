# Probe: what per-query membership records when ONE query set delivers the same row
# more than once.
#
# The server evaluates each query in a subscribe independently — execute_plans in
# crates/core/src/subscription/mod.rs maps every plan fragment to its OWN TableUpdate
# with no dedupe across the set — so a subscribe like
#   ["SELECT * FROM entity", "SELECT * FROM entity WHERE entity_id = 1"]
# sends entity row 1 twice under one query id. The cache refcounts both deliveries.
# The question is whether the query's membership index records both, since that index
# is what prune_query (the SubscriptionError path) reconstructs the deletes from.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_query_membership.gd
extends SceneTree

var _total: int = 0
var _fails: int = 0
var _db: LocalDatabase


class _Row:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var tag: int = 0


	static func make(p_id: int, p_tag: int = 0) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		r.tag = p_tag
		return r


func _initialize() -> void:
	_fresh()
	_scenario_pk_same_query_twice()
	_fresh()
	_scenario_pkless_same_query_twice()
	_fresh()
	_scenario_two_queries()
	_fresh()
	_scenario_unsubscribe_echo()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# One query set, one PK row, delivered by two of its queries.
func _scenario_pk_same_query_twice() -> void:
	_insert(&"pk", 1, [_Row.make(1)])
	_insert(&"pk", 1, [_Row.make(1)])
	_check("pk: one cached row", _db.get_all_rows(&"pk").size(), 1)
	_check("pk: refcount", _db._ref_counts[&"pk"][1], 2)
	_check("pk: membership entries", _db._query_rows[1][&"pk"].size(), 1)
	_db.prune_query(1)
	_check("pk: mirror empty after prune", _db.get_all_rows(&"pk").size(), 0)


# The PK-less path keeps a count per distinct value, so the same shape should prune.
func _scenario_pkless_same_query_twice() -> void:
	_insert(&"pkless", 1, [_Row.make(5, 7)])
	_insert(&"pkless", 1, [_Row.make(5, 7)])
	_check("pkless: one cached row", _db.get_all_rows(&"pkless").size(), 1)
	_db.prune_query(1)
	_check("pkless: mirror empty after prune", _db.get_all_rows(&"pkless").size(), 0)


# Control: two DIFFERENT query sets holding one row. Pruning one must keep it, pruning
# both must drop it.
func _scenario_two_queries() -> void:
	_insert(&"pk", 1, [_Row.make(2)])
	_insert(&"pk", 2, [_Row.make(2)])
	_db.prune_query(1)
	_check("two sets: row survives the first prune", _db.get_all_rows(&"pk").size(), 1)
	_db.prune_query(2)
	_check("two sets: gone after the second", _db.get_all_rows(&"pk").size(), 0)


# The unsubscribe path: the server echoes the dropped rows, once per query that
# delivered them, so the refcount comes back down symmetrically.
func _scenario_unsubscribe_echo() -> void:
	_insert(&"pk", 1, [_Row.make(3)])
	_insert(&"pk", 1, [_Row.make(3)])
	_delete(&"pk", 1, [_Row.make(3)])
	_delete(&"pk", 1, [_Row.make(3)])
	_check("unsubscribe echo: mirror empty", _db.get_all_rows(&"pk").size(), 0)
	_db.forget_query(1)
	_check("unsubscribe echo: no refcount left", _db._ref_counts[&"pk"].size(), 0)

# --- harness ---


func _fresh() -> void:
	if is_instance_valid(_db):
		_db.free()
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("probe", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk", &"pkless"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"pk"] = &"id"
	_db._primary_key_cache[&"pkless"] = &""


func _insert(table: StringName, query_id: int, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.inserts = typed
	_db.apply_table_update(u, query_id)


func _delete(table: StringName, query_id: int, rows: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var typed: Array[Resource] = []
	typed.assign(rows)
	u.deletes = typed
	_db.apply_table_update(u, query_id)


func _check(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	_fails += 1

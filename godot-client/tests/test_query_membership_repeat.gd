# Regression test: a query set that delivers the same row twice can still be pruned.
#
# The server evaluates each query in a subscribe independently — execute_plans in
# crates/core/src/subscription/mod.rs emits one TableUpdate per query fragment with no
# dedupe across the set — so
#   subscribe(["SELECT * FROM entity", "SELECT * FROM entity WHERE entity_id = 1"])
# delivers entity row 1 twice under ONE query id, and the cache refcounts both.
#
# The PK-side membership index recorded the pk once (`qmem[pk] = row`), so
# prune_query — which reconstructs the deletes from that index on a SubscriptionError
# for an already-applied subscription — handed back one reference of the two. Measured:
# the row stayed cached at refcount 1 with its query gone, so nothing could ever
# release it, no row_deleted fired, and it survived until the next reconnect wiped the
# mirror. The PK-less side already counted repeats; this makes the PK side match.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_query_membership_repeat.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase
var _deleted: int = 0


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
	var f: int = 0
	f += _case_repeat_within_one_query()
	f += _case_repeat_three_times()
	f += _case_two_query_sets()
	f += _case_update_takes_no_reference()
	f += _case_unsubscribe_echo()
	f += _case_partial_delete_then_prune()
	f += _case_pk_less_repeat()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## Two of the set's queries match one row: pruning the set must release both.
func _case_repeat_within_one_query() -> int:
	_fresh()
	_insert(&"pk", 1, [_Row.make(1)])
	_insert(&"pk", 1, [_Row.make(1)])
	var f: int = _check_i("repeat: refcounted twice", _db._ref_counts[&"pk"][1], 2)
	f += _check_i("repeat: one cached row", _db.get_all_rows(&"pk").size(), 1)
	_db.prune_query(1)
	f += _check_i("repeat: gone after prune", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("repeat: refcount released", _db._ref_counts[&"pk"].size(), 0)
	f += _check_i("repeat: row_deleted fired once", _deleted, 1)
	return f


## Three overlapping queries in one set — the count is not a flag.
func _case_repeat_three_times() -> int:
	_fresh()
	for _i: int in 3:
		_insert(&"pk", 1, [_Row.make(2)])
	var f: int = _check_i("three: refcounted three times", _db._ref_counts[&"pk"][2], 3)
	_db.prune_query(1)
	f += _check_i("three: gone after prune", _db.get_all_rows(&"pk").size(), 0)
	return f


## Two different subscriptions holding one row: pruning one keeps it, pruning both
## drops it. The repeat count must not leak across query sets.
func _case_two_query_sets() -> int:
	_fresh()
	_insert(&"pk", 1, [_Row.make(3)])
	_insert(&"pk", 1, [_Row.make(3)]) # set 1 holds two references
	_insert(&"pk", 2, [_Row.make(3)])
	var f: int = _check_i("two sets: refcount", _db._ref_counts[&"pk"][3], 3)
	_db.prune_query(1)
	f += _check_i("two sets: survives the first prune", _db.get_all_rows(&"pk").size(), 1)
	f += _check_i("two sets: set 2's reference remains", _db._ref_counts[&"pk"][3], 1)
	_db.prune_query(2)
	f += _check_i("two sets: gone after the second", _db.get_all_rows(&"pk").size(), 0)
	return f


## An update (delete + insert of one pk in a single batch) leaves the refcount alone,
## so it must not add a membership reference either — a prune would otherwise hand
## back one this query never took, evicting a row another subscription holds.
func _case_update_takes_no_reference() -> int:
	_fresh()
	_insert(&"pk", 1, [_Row.make(4, 10)])
	_insert(&"pk", 2, [_Row.make(4, 10)])
	_update(&"pk", 1, _Row.make(4, 10), _Row.make(4, 11))
	var f: int = _check_i("update: refcount unchanged", _db._ref_counts[&"pk"][4], 2)
	_db.prune_query(1)
	f += _check_i("update: set 2 still holds the row", _db.get_all_rows(&"pk").size(), 1)
	f += _check_i("update: row carries the newer value", _db.get_all_rows(&"pk")[0].tag, 11)
	_db.prune_query(2)
	f += _check_i("update: gone once both prune", _db.get_all_rows(&"pk").size(), 0)
	return f


## The unsubscribe path: the server echoes the dropped rows once per query that
## delivered them, and those deletes must still balance the refcount exactly.
func _case_unsubscribe_echo() -> int:
	_fresh()
	_insert(&"pk", 1, [_Row.make(5)])
	_insert(&"pk", 1, [_Row.make(5)])
	_delete(&"pk", 1, [_Row.make(5)])
	var f: int = _check_i("echo: first delete keeps the row", _db.get_all_rows(&"pk").size(), 1)
	_delete(&"pk", 1, [_Row.make(5)])
	f += _check_i("echo: second delete drops it", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("echo: refcount released", _db._ref_counts[&"pk"].size(), 0)
	_db.forget_query(1)
	f += _check_i("echo: membership dropped", _db._query_rows.size(), 0)
	return f


## Only one of the two deletes arrives before the subscription errors: the prune has to
## hand back the reference that is still outstanding. A delete that dropped the whole
## membership entry would leave the row cached at refcount 1 with nothing left to
## release it — the same leak, moved to the delete side.
func _case_partial_delete_then_prune() -> int:
	_fresh()
	_insert(&"pk", 1, [_Row.make(9)])
	_insert(&"pk", 1, [_Row.make(9)])
	_delete(&"pk", 1, [_Row.make(9)])
	var f: int = _check_i(
		"partial: still cached after one delete",
		_db.get_all_rows(&"pk").size(),
		1,
	)
	f += _check_i("partial: one reference left", _db._ref_counts[&"pk"][9], 1)
	_db.prune_query(1)
	f += _check_i("partial: gone after prune", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("partial: refcount released", _db._ref_counts[&"pk"].size(), 0)
	return f


## The PK-less side already counted repeats; it has to keep doing so.
func _case_pk_less_repeat() -> int:
	_fresh()
	_insert(&"pkless", 1, [_Row.make(6, 1)])
	_insert(&"pkless", 1, [_Row.make(6, 1)])
	var f: int = _check_i("pk-less: one cached row", _db.get_all_rows(&"pkless").size(), 1)
	_db.prune_query(1)
	f += _check_i("pk-less: gone after prune", _db.get_all_rows(&"pkless").size(), 0)
	return f

# --- harness ---


func _fresh() -> void:
	if is_instance_valid(_db):
		_db.free()
	_deleted = 0
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk", &"pkless"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"pk"] = &"id"
	_db._primary_key_cache[&"pkless"] = &""
	_db.subscribe_to_deletes(&"pk", _on_delete)


func _on_delete(_row: _ModuleTableType) -> void:
	_deleted += 1


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


func _update(table: StringName, query_id: int, old_row: Resource, new_row: Resource) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var ins: Array[Resource] = []
	ins.assign([new_row])
	var del: Array[Resource] = []
	del.assign([old_row])
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u, query_id)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

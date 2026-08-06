# Regression test: an update delivered once per overlapping query must not inflate the
# refcount, and its surplus deletes must still be applied.
#
# The server groups every query fragment's rows for one table under a single TableUpdate
# (send_v2_computed_queries in crates/core/src/subscription/module_subscription_manager.rs
# keys its BTreeMap by (client, query_set, table) and pushes one TableUpdateRows per
# fragment), and the deserializer flattens those blocks into one inserts list and one
# deletes list. So for
#   subscribe(["SELECT * FROM entity", "SELECT * FROM entity WHERE entity_id = 1"])
# a transaction that updates entity 1 arrives as TWO inserts and TWO deletes of that pk.
#
# The insert/delete pairing that recognises an update used a SET of deleted pks: the first
# insert erased the pk, the second took the "new reference" branch and bumped the refcount,
# and the now-empty set made the whole delete pass skip. Measured: refcount grew by one per
# update (2 -> 3 -> 4 ...), so when the server finally deleted the row both deletes only
# walked it back down to 2 — the row stayed in the mirror forever with no row_deleted, a
# ghost the game keeps rendering. The mirror image (more deletes than inserts, a row that
# leaves one of the two queries) lost the surplus delete the same way and kept the
# reference. The pairing counts now.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_duplicate_update_refcount.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase
var _deleted: int = 0
var _updated: int = 0
var _inserted: int = 0


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
	f += _case_duplicate_update_keeps_refcount()
	f += _case_repeated_updates_do_not_accumulate()
	f += _case_row_still_leaves_on_delete()
	f += _case_surplus_delete_is_applied()
	f += _case_surplus_insert_takes_a_reference()
	f += _case_prune_after_duplicate_update()
	f += _case_single_update_unchanged()
	f += _case_paired_delete_for_uncached_pk()
	f += _case_pk_less_parity()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## Two overlapping queries hold the row; one transaction updates it, so both report the
## delete+insert pair. Net refcount change is zero and exactly one on_update fires.
func _case_duplicate_update_keeps_refcount() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(1, 10), _Row.make(1, 10)], [])
	var f: int = _check_i("dup: subscribe refcount", _db._ref_counts[&"pk"][1], 2)
	f += _check_i("dup: one cached row", _db.get_all_rows(&"pk").size(), 1)
	_apply(&"pk", 1, [_Row.make(1, 11), _Row.make(1, 11)], [_Row.make(1, 10), _Row.make(1, 10)])
	f += _check_i("dup: refcount unchanged by the update", _db._ref_counts[&"pk"][1], 2)
	f += _check_i("dup: still one cached row", _db.get_all_rows(&"pk").size(), 1)
	f += _check_i("dup: carries the newer value", _db.get_all_rows(&"pk")[0].tag, 11)
	f += _check_i("dup: on_update fired once", _updated, 1)
	f += _check_i("dup: no on_insert for an update", _inserted, 1)
	return f


## The inflation was per transaction, so a row updated repeatedly drifted further with
## every one. Ten updates must leave the refcount where the subscribe put it.
func _case_repeated_updates_do_not_accumulate() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(2, 0), _Row.make(2, 0)], [])
	for i: int in 10:
		_apply(
			&"pk",
			1,
			[_Row.make(2, i + 1), _Row.make(2, i + 1)],
			[_Row.make(2, i), _Row.make(2, i)],
		)
	var f: int = _check_i("repeat: refcount after ten updates", _db._ref_counts[&"pk"][2], 2)
	f += _check_i("repeat: latest value", _db.get_all_rows(&"pk")[0].tag, 10)
	f += _check_i("repeat: on_update per transaction", _updated, 10)
	return f


## The consequence that reached game code: after the updates, the server's delete has to
## empty the mirror and report it.
func _case_row_still_leaves_on_delete() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(3, 0), _Row.make(3, 0)], [])
	_apply(&"pk", 1, [_Row.make(3, 1), _Row.make(3, 1)], [_Row.make(3, 0), _Row.make(3, 0)])
	_apply(&"pk", 1, [], [_Row.make(3, 1), _Row.make(3, 1)])
	var f: int = _check_i("delete: mirror empty", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("delete: refcount released", _db._ref_counts[&"pk"].size(), 0)
	f += _check_i("delete: row_deleted fired once", _deleted, 1)
	return f


## Asymmetric: the row leaves one of the two queries. That fragment sends a bare delete
## while the other sends the update pair, so one delete is left over and must be applied —
## the row stays cached at one reference, carrying the new value.
func _case_surplus_delete_is_applied() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(4, 10), _Row.make(4, 10)], [])
	_apply(&"pk", 1, [_Row.make(4, 11)], [_Row.make(4, 10), _Row.make(4, 10)])
	var f: int = _check_i("surplus delete: one reference left", _db._ref_counts[&"pk"][4], 1)
	f += _check_i("surplus delete: still cached", _db.get_all_rows(&"pk").size(), 1)
	f += _check_i("surplus delete: newer value", _db.get_all_rows(&"pk")[0].tag, 11)
	f += _check_i("surplus delete: no row_deleted", _deleted, 0)
	_apply(&"pk", 1, [], [_Row.make(4, 11)])
	f += _check_i("surplus delete: last reference drops it", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("surplus delete: row_deleted fired once", _deleted, 1)
	return f


## The mirror image: the row enters a second query as it is updated in the first, so there
## is one more insert than delete. The extra insert is a genuine new reference.
func _case_surplus_insert_takes_a_reference() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(5, 10)], [])
	var f: int = _check_i("surplus insert: one reference", _db._ref_counts[&"pk"][5], 1)
	_apply(&"pk", 1, [_Row.make(5, 11), _Row.make(5, 11)], [_Row.make(5, 10)])
	f += _check_i("surplus insert: second reference taken", _db._ref_counts[&"pk"][5], 2)
	f += _check_i("surplus insert: newer value", _db.get_all_rows(&"pk")[0].tag, 11)
	# The surplus insert carries the same value the paired one already stored, so it is a
	# reference and nothing more — a second on_update would be reporting a change that
	# did not happen.
	f += _check_i("surplus insert: one on_update for the batch", _updated, 1)
	_apply(&"pk", 1, [], [_Row.make(5, 11)])
	f += _check_i("surplus insert: survives one delete", _db.get_all_rows(&"pk").size(), 1)
	_apply(&"pk", 1, [], [_Row.make(5, 11)])
	f += _check_i("surplus insert: gone after both", _db.get_all_rows(&"pk").size(), 0)
	return f


## Per-query membership has to stay in step with the refcount: a SubscriptionError after
## the duplicate update must hand back both references and leave nothing behind.
func _case_prune_after_duplicate_update() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(6, 10), _Row.make(6, 10)], [])
	_apply(&"pk", 1, [_Row.make(6, 11), _Row.make(6, 11)], [_Row.make(6, 10), _Row.make(6, 10)])
	_db.prune_query(1)
	var f: int = _check_i("prune: mirror empty", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("prune: refcount released", _db._ref_counts[&"pk"].size(), 0)
	f += _check_i("prune: row_deleted fired once", _deleted, 1)
	f += _check_i("prune: membership dropped", _db._query_rows.size(), 0)
	return f


## The ordinary one-query case the pairing already handled: still one update, still no
## refcount change, and a pk whose delete has no matching insert is still a delete.
func _case_single_update_unchanged() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(7, 10)], [])
	_apply(&"pk", 1, [_Row.make(8, 10)], [])
	_apply(&"pk", 1, [_Row.make(7, 11)], [_Row.make(7, 10), _Row.make(8, 10)])
	var f: int = _check_i("single: updated row keeps its reference", _db._ref_counts[&"pk"][7], 1)
	f += _check_i("single: unrelated delete applied", _db._ref_counts[&"pk"].has(8), 0)
	f += _check_i("single: one row left", _db.get_all_rows(&"pk").size(), 1)
	f += _check_i("single: on_update fired once", _updated, 1)
	f += _check_i("single: row_deleted fired once", _deleted, 1)
	return f


## Desync: a batch pairs its deletes against inserts for a pk the mirror never held. The
## pairing consumes those deletes, so nothing else records the reference this delivery
## carries — the row must not be left cached at refcount 0, which no later delete could
## ever release. One reference is deliberate: under-counting self-heals on the first real
## delete, over-counting is the ghost this whole fix is about.
func _case_paired_delete_for_uncached_pk() -> int:
	_fresh()
	_apply(&"pk", 1, [_Row.make(10, 11), _Row.make(10, 11)], [_Row.make(10, 10), _Row.make(10, 10)])
	var f: int = _check_i("desync: one reference taken", _db._ref_counts[&"pk"][10], 1)
	f += _check_i("desync: row cached", _db.get_all_rows(&"pk").size(), 1)
	f += _check_i("desync: reported as an insert", _inserted, 1)
	f += _check_i("desync: nothing to update from", _updated, 0)
	_apply(&"pk", 1, [], [_Row.make(10, 11)])
	f += _check_i("desync: a later delete releases it", _db.get_all_rows(&"pk").size(), 0)
	f += _check_i("desync: row_deleted fired once", _deleted, 1)
	return f


## The PK-less path counts by row value and was already correct; pin that it stays so.
func _case_pk_less_parity() -> int:
	_fresh()
	_apply(&"pkless", 1, [_Row.make(9, 10), _Row.make(9, 10)], [])
	_apply(&"pkless", 1, [_Row.make(9, 11), _Row.make(9, 11)], [_Row.make(9, 10), _Row.make(9, 10)])
	var f: int = _check_i("pk-less: one cached row", _db.get_all_rows(&"pkless").size(), 1)
	f += _check_i("pk-less: newer value", _db.get_all_rows(&"pkless")[0].tag, 11)
	_apply(&"pkless", 1, [], [_Row.make(9, 11), _Row.make(9, 11)])
	f += _check_i("pk-less: gone after both deletes", _db.get_all_rows(&"pkless").size(), 0)
	# Two, not one: a keyless table has nothing to pair an insert with, so the update's old
	# value is a genuine eviction (row_deleted) and its new value a genuine insert. Only the
	# PK path can report that pair as an update.
	f += _check_i("pk-less: row_deleted per evicted value", _deleted, 2)
	return f

# --- harness ---


func _fresh() -> void:
	if is_instance_valid(_db):
		_db.free()
	_deleted = 0
	_updated = 0
	_inserted = 0
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk", &"pkless"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"pk"] = &"id"
	_db._primary_key_cache[&"pkless"] = &""
	# No row script is registered here, so seed the column list both paths read: the PK-less
	# path tells one row value from another with it (without it every row hashes to one
	# bucket), and the PK path treats an empty list as "always changed", which would fire an
	# on_update for every re-delivery and hide what the update counts below are pinning.
	var props: Array[StringName] = [&"id", &"tag"]
	_db._row_property_cache[&"pk"] = props
	_db._row_property_cache[&"pkless"] = props
	for table: StringName in [&"pk", &"pkless"]:
		_db.subscribe_to_deletes(table, _on_delete)
		_db.subscribe_to_updates(table, _on_update)
		_db.subscribe_to_inserts(table, _on_insert)


func _on_delete(_row: _ModuleTableType) -> void:
	_deleted += 1


func _on_update(_prev: _ModuleTableType, _row: _ModuleTableType) -> void:
	_updated += 1


func _on_insert(_row: _ModuleTableType) -> void:
	_inserted += 1


func _apply(table: StringName, query_id: int, ins: Array, del: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	var typed_ins: Array[Resource] = []
	typed_ins.assign(ins)
	var typed_del: Array[Resource] = []
	typed_del.assign(del)
	u.inserts = typed_ins
	u.deletes = typed_del
	_db.apply_table_update(u, query_id)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

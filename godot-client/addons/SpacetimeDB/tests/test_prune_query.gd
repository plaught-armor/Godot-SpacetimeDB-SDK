# Test for LocalDatabase.prune_query — precise per-query cache pruning used on a
# SubscriptionError for an already-applied subscription (the server sends no dropped
# rows on an error). A row held by two overlapping subscriptions survives pruning one
# of them and is evicted only when the last is pruned. Covers PK and PK-less tables.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_prune_query.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _pk_deletes: int = 0
var _pkless_deletes: int = 0
var _db: LocalDatabase


class _TestRow:
	extends _ModuleTableType
	@export var id: int = 0
	@export var val: int = 0


	static func make(p_id: int, p_val: int) -> _TestRow:
		var r: _TestRow = _TestRow.new()
		r.id = p_id
		r.val = p_val
		return r


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _apply(table: StringName, rows: Array, query_id: int) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table
	u.inserts.assign(rows)
	_db.apply_table_update(u, query_id)


func _run() -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk_tab", &"pkless_tab"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"pk_tab"] = &"id"
	_db._row_property_cache[&"pk_tab"] = [&"id", &"val"] as Array[StringName]
	_db._primary_key_cache[&"pkless_tab"] = &""
	_db._row_property_cache[&"pkless_tab"] = [&"id", &"val"] as Array[StringName]
	_db.subscribe_to_deletes(&"pk_tab", _on_pk_delete)
	_db.subscribe_to_deletes(&"pkless_tab", _on_pkless_delete)

	var f: int = 0

	# --- PK table: same row from two overlapping query sets (1 and 2) ---
	_apply(&"pk_tab", [_TestRow.make(1, 10)], 1)
	_apply(&"pk_tab", [_TestRow.make(1, 10)], 2)
	f += _check_i("pk: cached once across two queries", _db.count_all_rows(&"pk_tab"), 1)

	_db.prune_query(1)
	f += _check_i("pk: survives pruning query 1", _db.count_all_rows(&"pk_tab"), 1)
	f += _check_i("pk: no on_delete on first prune", _pk_deletes, 0)

	_db.prune_query(2)
	f += _check_i("pk: evicted when last query pruned", _db.count_all_rows(&"pk_tab"), 0)
	f += _check_i("pk: on_delete fired once", _pk_deletes, 1)

	# --- PK-less table: same value from two overlapping query sets ---
	_apply(&"pkless_tab", [_TestRow.make(7, 70)], 1)
	_apply(&"pkless_tab", [_TestRow.make(7, 70)], 2)
	f += _check_i("pk-less: cached once across two queries", _db.count_all_rows(&"pkless_tab"), 1)

	_db.prune_query(1)
	f += _check_i("pk-less: survives pruning query 1", _db.count_all_rows(&"pkless_tab"), 1)
	f += _check_i("pk-less: no on_delete on first prune", _pkless_deletes, 0)

	_db.prune_query(2)
	f += _check_i("pk-less: evicted when last query pruned", _db.count_all_rows(&"pkless_tab"), 0)
	f += _check_i("pk-less: on_delete fired once", _pkless_deletes, 1)

	# prune of an unknown query is a no-op.
	_db.prune_query(99)
	f += _check_i("prune unknown query is a no-op", _pk_deletes + _pkless_deletes, 2)

	_db.free()
	return f


func _on_pk_delete(_row: _ModuleTableType) -> void:
	_pk_deletes += 1


func _on_pkless_delete(_row: _ModuleTableType) -> void:
	_pkless_deletes += 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

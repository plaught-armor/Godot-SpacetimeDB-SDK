# Regression test for when a PK-less row leaves the cache relative to its callbacks.
#
# The two delete callbacks split on exactly one thing: on_before_delete runs while the
# row is still queryable, on_delete runs once it is gone. The PK path honours that — it
# erases from the table dict between the two. The PK-less path fired both from inside its
# decrement loop and only compacted the row array afterwards, so on_delete still found
# the row in iter() / get_all_rows(). A consumer that rebuilds its view from iter() on
# delete — the natural shape for a flat table — kept showing the deleted row until the
# next event touched that table.
#
# Asserts, for a PK-less table:
#   - on_before_delete sees the row still present (unchanged behaviour, pinned here),
#   - on_delete sees it gone,
#   - a row still held by another subscription is not reported deleted at all,
#   - the surviving rows are exactly the ones left, in order,
#   - the PK path's ordering is unchanged (the contract being matched),
#   - the emission SHAPE of a multi-row batch, which is where the two paths differ: the
#     PK path interleaves each row's pair, the PK-less path reports every before-delete
#     and then every delete (one compaction pass sits between them),
#   - the same value appearing twice in one deletes list is counted twice and reported
#     once.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_pkless_delete_order.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _db: LocalDatabase
## Row count visible through get_all_rows() at the moment each callback fired.
var _seen_in_before: PackedInt32Array = []
var _seen_in_delete: PackedInt32Array = []
## Whether the row handed to the callback was itself still listed.
var _row_listed_in_before: Array[bool] = []
var _row_listed_in_delete: Array[bool] = []
var _table: StringName = &"flat"


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0
	_db = _mk_db()
	_db.subscribe_to_before_deletes(_table, _on_before_delete)
	_db.subscribe_to_deletes(_table, _on_delete)

	# Three distinct values; the middle one is delivered twice (two overlapping
	# subscriptions hold it), so one delete must not evict it.
	_apply(_table, [_row(1), _row(2), _row(3)], [])
	_apply(_table, [_row(2)], [])
	f += _check_i("setup: rows cached", _db.get_all_rows(_table).size(), 3)

	# Delete row 1 (last holder) and row 2 (still held by the second delivery).
	_apply(_table, [], [_row(1), _row(2)])

	f += _check_i("one delete reported", _seen_in_delete.size(), 1)
	f += _check_i("one before_delete reported", _seen_in_before.size(), 1)
	f += _check_b("before_delete saw the row still listed", _row_listed_in_before[0], true)
	f += _check_b("delete saw the row already gone", _row_listed_in_delete[0], false)
	f += _check_i("before_delete saw the full cache", _seen_in_before[0], 3)
	f += _check_i("delete saw the shrunk cache", _seen_in_delete[0], 2)
	f += _check_i("rows left after the batch", _db.get_all_rows(_table).size(), 2)
	f += _check_b("shared row survived its first delete", _has_value(2), true)
	f += _check_b("last-holder row is gone", _has_value(1), false)
	f += _check_b("untouched row still there", _has_value(3), true)

	# Second delete of the shared value drops it, and on_delete again sees it gone.
	_seen_in_delete.clear()
	_row_listed_in_delete.clear()
	_apply(_table, [], [_row(2)])
	f += _check_i("shared row reported once its last holder left", _seen_in_delete.size(), 1)
	f += _check_b("delete saw it gone", _row_listed_in_delete[0], false)
	f += _check_i("rows left", _db.get_all_rows(_table).size(), 1)

	f += _test_pk_path_unchanged()
	f += _test_batch_shape()
	f += _test_repeated_value_in_one_batch()
	return f


# The order a multi-row batch reports, pinned on both paths so a later change to either
# one shows up as a disagreement rather than passing quietly. PK-less batches its two
# phases around the single compaction pass; the PK path erases per row and so interleaves.
func _test_batch_shape() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	# Array, not PackedStringArray: a lambda captures a local by value, and a Packed*Array
	# is a value type, so appends inside the callback would never reach this one (#69014).
	# Array is reference-counted, so the capture shares this instance.
	var order: Array[String] = [] # gdlint: ignore[S6]
	db.subscribe_to_before_deletes(
		&"flat",
		func(row: _ModuleTableType) -> void:
			order.append("bd:%d" % row.get(&"value")),
	)
	db.subscribe_to_deletes(
		&"flat",
		func(row: _ModuleTableType) -> void:
			order.append("d:%d" % row.get(&"value")),
	)
	_apply_to(db, &"flat", [_row(1), _row(2)], [])
	_apply_to(db, &"flat", [], [_row(1), _row(2)])
	f += _check_s(
		"pk-less batch reports both before-deletes, then both deletes",
		", ".join(order),
		"bd:1, bd:2, d:1, d:2",
	)

	# Array for the same capture reason as `order` above.
	var pk_order: Array[String] = [] # gdlint: ignore[S6]
	db.subscribe_to_before_deletes(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			pk_order.append("bd:%d" % row.get(&"id")),
	)
	db.subscribe_to_deletes(
		&"keyed",
		func(row: _ModuleTableType) -> void:
			pk_order.append("d:%d" % row.get(&"id")),
	)
	_apply_to(db, &"keyed", [_keyed_row(1), _keyed_row(2)], [])
	_apply_to(db, &"keyed", [], [_keyed_row(1), _keyed_row(2)])
	f += _check_s(
		"pk batch interleaves each row's pair",
		", ".join(pk_order),
		"bd:1, d:1, bd:2, d:2",
	)

	db.free()
	return f


# A batch can carry the same value twice — one delete per holder. Both are counted, and
# the row is reported exactly once, when the last holder leaves.
func _test_repeated_value_in_one_batch() -> int:
	var f: int = 0
	var db: LocalDatabase = _mk_db()
	# One-element container, not a bare int: a lambda captures a local primitive by value,
	# so `deletes += 1` inside the callback would never reach the assertion (#69014).
	var deletes: Array[int] = [0] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		&"flat",
		func(_row_arg: _ModuleTableType) -> void:
			deletes[0] += 1,
	)

	# Delivered twice (two holders), then both holders drop it in one batch.
	_apply_to(db, &"flat", [_row(9)], [])
	_apply_to(db, &"flat", [_row(9)], [])
	_apply_to(db, &"flat", [], [_row(9), _row(9)])
	f += _check_i("repeated value reported once", deletes[0], 1)
	f += _check_i("repeated value left the cache", db.get_all_rows(&"flat").size(), 0)

	# A third delete for a value nothing holds any more is a no-op, not a second report.
	_apply_to(db, &"flat", [], [_row(9)])
	f += _check_i("surplus delete adds nothing", deletes[0], 1)

	db.free()
	return f


# The contract the PK-less path is being matched to, pinned so a later change to either
# side shows up as a disagreement rather than passing quietly.
func _test_pk_path_unchanged() -> int:
	var f: int = 0
	var listed_in_before: Array[bool] = []
	var listed_in_delete: Array[bool] = []
	var before_cb: Callable = func(row: _ModuleTableType) -> void:
		listed_in_before.append(_db.get_row_by_pk(&"keyed", row.get(&"id")) != null)
	var delete_cb: Callable = func(row: _ModuleTableType) -> void:
		listed_in_delete.append(_db.get_row_by_pk(&"keyed", row.get(&"id")) != null)
	_db.subscribe_to_before_deletes(&"keyed", before_cb)
	_db.subscribe_to_deletes(&"keyed", delete_cb)

	_apply(&"keyed", [_keyed_row(7)], [])
	_apply(&"keyed", [], [_keyed_row(7)])
	f += _check_b("pk before_delete saw the row present", listed_in_before[0], true)
	f += _check_b("pk delete saw the row gone", listed_in_delete[0], false)

	_db.unsubscribe_from_before_deletes(&"keyed", before_cb)
	_db.unsubscribe_from_deletes(&"keyed", delete_cb)
	return f


func _on_before_delete(row: _ModuleTableType) -> void:
	_seen_in_before.append(_db.get_all_rows(_table).size())
	_row_listed_in_before.append(_is_listed(row))


func _on_delete(row: _ModuleTableType) -> void:
	_seen_in_delete.append(_db.get_all_rows(_table).size())
	_row_listed_in_delete.append(_is_listed(row))


# Identity, not value: the cache holds the instance it was first handed, and that is the
# one the callback receives.
func _is_listed(row: _ModuleTableType) -> bool:
	for cached: _ModuleTableType in _db.get_all_rows(_table):
		if cached == row:
			return true
	return false


func _has_value(value: int) -> bool:
	for cached: _ModuleTableType in _db.get_all_rows(_table):
		if cached.get(&"value") == value:
			return true
	return false


func _row(value: int) -> _FlatRow:
	return _FlatRow.new(value)


func _keyed_row(id: int) -> _KeyedRow:
	return _KeyedRow.new(id)


# A database with one PK-less table (`flat`) and one PK table (`keyed`). Both row scripts
# are registered the way _add_table_names writes them: the script is what resolves the
# column list the PK-less path hashes rows by — without it every row hashes alike and
# collapses into a single entry — and what decides that `flat` has no primary key.
func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"flat", &"keyed"]
	schema.types[&"flat"] = _FlatRow
	schema.tables[&"flat"] = _FlatRow
	schema.types[&"keyed"] = _KeyedRow
	schema.tables[&"keyed"] = _KeyedRow
	return LocalDatabase.new(schema)


func _apply(table_name: StringName, inserts: Array, deletes: Array) -> void:
	_apply_to(_db, table_name, inserts, deletes)


func _apply_to(db: LocalDatabase, table_name: StringName, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	db.apply_table_update(u)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = [%s]" % [label, got])
		return 0
	printerr("FAIL  %s: got [%s] want [%s]" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


class _FlatRow:
	extends _ModuleTableType
	@export var value: int = 0


	func _init(p_value: int = 0) -> void:
		value = p_value


class _KeyedRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0


	func _init(p_id: int = 0) -> void:
		id = p_id

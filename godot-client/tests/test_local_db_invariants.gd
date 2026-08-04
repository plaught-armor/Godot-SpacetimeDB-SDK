# Model-based check of LocalDatabase and its two index caches under overlapping
# subscriptions. Random-but-seeded sequences are driven against a plain-dictionary model
# of what the server holds, and after every single step four invariants are asserted:
#
#   1. the row store equals the model, row for row,
#   2. every cached row carries a refcount equal to the number of subscriptions holding
#      it, and no refcount outlives its row,
#   3. the unique index maps each row's indexed value to that row, and holds nothing else,
#   4. the btree buckets equal the model's grouping, with one sorted key per bucket.
#
# Rows arrive under several query ids at once, so the store is refcounted: a row held by
# N subscriptions survives N-1 of them dropping it. The steps mix inserts, updates,
# deletes, unique-key handoffs (one transaction giving a row's unique value to another
# row), the server's delete-plus-insert encoding for a row the store does not hold,
# prune_query (the SubscriptionError path) and clear_local_db (the reconnect wipe).
#
# It is a regression net for two bugs that were found by hand, and it is only worth
# keeping because it catches both when they are put back:
#
#   - drop the `ref_table[pk_value] = 1` line from the update branch of
#     LocalDatabase.apply_table_update  → invariant 2 fails ("refcount 0, model says 1"),
#   - make _ModuleTableUniqueIndex._on_delete erase by key unconditionally
#     → invariant 3 fails ("unique cache has no key N").
#
# Seeds are fixed, so a failure reproduces exactly; the seed is printed with the report.
# One step per batch, apart from the handoff, which is the case that needs two rows
# moving in a single update.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_local_db_invariants.gd
#
# Exit code = number of failed assertions (0 = all pass).
extends SceneTree

const SEEDS: int = 24
const ROUNDS: int = 250
const MAX_PK: int = 8
const MAX_KEY: int = 6
const MAX_GRP: int = 3
const QUERIES: int = 3


class Row:
	extends _ModuleTableType
	@export var id: int = 0
	@export var key: int = 0
	@export var grp: int = 0


var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _db: LocalDatabase
var _uniq: _ModuleTableUniqueIndex
var _uniq_cache: Dictionary = { }
var _btree: _ModuleTableBTreeIndex
var _btree_cache: Dictionary = { }
## query_id -> { pk: true }: which subscription is holding which row.
var _held: Dictionary = { }
## pk -> [key, grp]: the value every holder of that row agrees on.
var _values: Dictionary = { }
var _failures: PackedStringArray = []


func _initialize() -> void:
	var total_failures: int = 0
	for s: int in SEEDS:
		var seed_value: int = 1000 + s * 7919
		_failures = []
		_rng.seed = seed_value
		_build()
		for round_index: int in ROUNDS:
			_step()
			_check(round_index)
			if _failures.size() > 4:
				break
		if not _failures.is_empty():
			printerr("SEED %d:" % seed_value)
			for line: String in _failures:
				printerr("  " + line)
			total_failures += _failures.size()
		_db.free()
	if total_failures == 0:
		print("ALL PASS (%d seeds x %d steps, invariants held)" % [SEEDS, ROUNDS])
	else:
		printerr("%d FAIL" % total_failures)
	quit(total_failures)


func _build() -> void:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"alpha"] = &"id"
	_uniq = _ModuleTableUniqueIndex.new()
	_uniq._table_name = &"alpha"
	_uniq._field_name = &"key"
	_uniq_cache = { }
	_uniq._connect_cache_to_db(_uniq_cache, _db)
	_btree = _ModuleTableBTreeIndex.new()
	_btree._table_name = &"alpha"
	_btree._field_name = &"grp"
	_btree_cache = { }
	_btree._connect_cache_to_db(_btree_cache, _db)
	_held = { }
	_values = { }
	for q: int in QUERIES:
		_held[q] = { }


func _step() -> void:
	var choice: int = _rng.randi_range(0, 10)
	var q: int = _rng.randi_range(0, QUERIES - 1)
	if choice <= 2:
		_op_insert(q)
	elif choice <= 4:
		_op_update(q)
	elif choice <= 6:
		_op_delete(q)
	elif choice == 7:
		_op_handoff(q)
	elif choice == 8:
		_op_prune(q)
	elif choice == 9:
		_op_update_unheld(q)
	else:
		_op_wipe()


# A subscription delivers a row: a brand new one, or one another query already holds
# (same value, so the store just refcounts it).
func _op_insert(q: int) -> void:
	var pk: int = _rng.randi_range(1, MAX_PK)
	if _held[q].has(pk):
		return
	var value: Array = _values.get(pk, [] as Array)
	if value.is_empty():
		var key: int = _free_key(-1)
		if key == 0:
			return
		value = [key, _rng.randi_range(1, MAX_GRP)]
		_values[pk] = value
	_apply(q, [], [_mk(pk, value[0], value[1])])
	_held[q][pk] = true


# A row this query holds changes value. Every holder sees the same row, so the model's
# single value entry moves with it; the refcount does not change.
func _op_update(q: int) -> void:
	var pk: int = _pick_held(q)
	if pk == 0:
		return
	var old_value: Array = _values[pk]
	var key: int = old_value[0]
	if _rng.randi_range(0, 1) == 0:
		var candidate: int = _free_key(pk)
		if candidate != 0:
			key = candidate
	var grp: int = _rng.randi_range(1, MAX_GRP)
	_apply(q, [_mk(pk, old_value[0], old_value[1])], [_mk(pk, key, grp)])
	_values[pk] = [key, grp]


func _op_delete(q: int) -> void:
	var pk: int = _pick_held(q)
	if pk == 0:
		return
	var value: Array = _values[pk]
	_apply(q, [_mk(pk, value[0], value[1])], [])
	_held[q].erase(pk)
	if _holder_count(pk) == 0:
		_values.erase(pk)


# One transaction gives a unique key to a different row. Only safe to model when this
# query is the sole holder — otherwise the old row survives elsewhere and both would
# claim the key.
func _op_handoff(q: int) -> void:
	var pk: int = _pick_held(q)
	if pk == 0 or _holder_count(pk) != 1:
		return
	var new_pk: int = 0
	for _try: int in MAX_PK:
		var candidate: int = _rng.randi_range(1, MAX_PK)
		if not _values.has(candidate):
			new_pk = candidate
			break
	if new_pk == 0:
		return
	var value: Array = _values[pk]
	var grp: int = _rng.randi_range(1, MAX_GRP)
	_apply(q, [_mk(pk, value[0], value[1])], [_mk(new_pk, value[0], grp)])
	_held[q].erase(pk)
	_values.erase(pk)
	_held[q][new_pk] = true
	_values[new_pk] = [value[0], grp]


# A delete plus an insert of the same row — the server's encoding for an update —
# for a row the store does not hold. The client can be one row behind (an insert
# skipped for a null primary key, a value first seen through a change), and the SDK
# handles it as an insert, which has to leave the row referenced like any other.
func _op_update_unheld(q: int) -> void:
	var pk: int = 0
	for _try: int in MAX_PK:
		var candidate: int = _rng.randi_range(1, MAX_PK)
		if not _values.has(candidate):
			pk = candidate
			break
	if pk == 0:
		return
	var key: int = _free_key(-1)
	if key == 0:
		return
	var grp: int = _rng.randi_range(1, MAX_GRP)
	_apply(q, [_mk(pk, key, _rng.randi_range(1, MAX_GRP))], [_mk(pk, key, grp)])
	_held[q][pk] = true
	_values[pk] = [key, grp]


# The SubscriptionError path: everything this query contributed is dropped.
func _op_prune(q: int) -> void:
	_db.prune_query(q)
	for pk: int in _held[q].keys():
		_held[q].erase(pk)
		if _holder_count(pk) == 0:
			_values.erase(pk)


# The reconnect wipe: the whole mirror goes, every subscription with it.
func _op_wipe() -> void:
	_db.clear_local_db()
	_values = { }
	for q: int in QUERIES:
		_held[q] = { }


func _pick_held(q: int) -> int:
	var pks: Array = _held[q].keys()
	if pks.is_empty():
		return 0
	return pks[_rng.randi_range(0, pks.size() - 1)]


func _holder_count(pk: int) -> int:
	var n: int = 0
	for q: int in QUERIES:
		if _held[q].has(pk):
			n += 1
	return n


# A key no live row holds (ignoring `except_pk`, whose key is being replaced).
func _free_key(except_pk: int) -> int:
	var used: Dictionary = { }
	for pk: int in _values:
		if pk != except_pk:
			used[_values[pk][0]] = true
	for _try: int in MAX_KEY * 2:
		var key: int = _rng.randi_range(1, MAX_KEY)
		if not used.has(key):
			return key
	return 0


func _mk(pk: int, key: int, grp: int) -> Row:
	var r: Row = Row.new()
	r.id = pk
	r.key = key
	r.grp = grp
	return r


func _apply(query_id: int, deletes: Array, inserts: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	var d: Array[Resource] = []
	d.assign(deletes)
	var i: Array[Resource] = []
	i.assign(inserts)
	u.deletes = d
	u.inserts = i
	_db.apply_table_update(u, query_id)


func _fail(round_index: int, msg: String) -> void:
	if _failures.size() <= 4:
		_failures.append("round %d: %s" % [round_index, msg])


func _check(round_index: int) -> void:
	var store: Dictionary = _db._tables[&"alpha"]
	var refs: Dictionary = _db._ref_counts.get(&"alpha", { })

	if store.size() != _values.size():
		_fail(round_index, "store holds %d rows, model %d" % [store.size(), _values.size()])
	for pk: int in _values:
		var row: Variant = store.get(pk)
		if row == null:
			_fail(round_index, "pk %d missing from the store" % pk)
			continue
		if row.key != _values[pk][0] or row.grp != _values[pk][1]:
			_fail(
				round_index,
				(
					"pk %d is (key %d, grp %d), model says (key %d, grp %d)"
					% [pk, row.key, row.grp, _values[pk][0], _values[pk][1]]
				),
			)
		var want_ref: int = _holder_count(pk)
		if refs.get(pk, 0) != want_ref:
			_fail(round_index, "pk %d refcount %d, model says %d" % [pk, refs.get(pk, 0), want_ref])
	for pk: int in refs:
		if not _values.has(pk):
			_fail(round_index, "refcount %d left for absent pk %d" % [refs[pk], pk])

	if _uniq_cache.size() != _values.size():
		_fail(round_index, "unique cache holds %d, model %d" % [_uniq_cache.size(), _values.size()])
	for pk: int in _values:
		var cached: Variant = _uniq_cache.get(_values[pk][0])
		if cached == null:
			_fail(round_index, "unique cache has no key %d (pk %d)" % [_values[pk][0], pk])
		elif cached.id != pk:
			_fail(
				round_index,
				"unique cache key %d -> pk %d, want %d" % [_values[pk][0], cached.id, pk],
			)

	var expected: Dictionary = { }
	for pk: int in _values:
		var grp: int = _values[pk][1]
		if not expected.has(grp):
			expected[grp] = [] as Array
		expected[grp].append(pk)
	if _btree_cache.size() != expected.size():
		_fail(
			round_index,
			"btree holds %d buckets, model %d" % [_btree_cache.size(), expected.size()],
		)
	for grp: int in expected:
		var bucket: Variant = _btree_cache.get(grp)
		if bucket == null:
			_fail(round_index, "btree has no bucket %d" % grp)
			continue
		var got: PackedInt64Array = []
		for row: Variant in bucket:
			got.append(row.id)
		got.sort()
		var want: PackedInt64Array = []
		for pk: int in expected[grp]:
			want.append(pk)
		want.sort()
		if got != want:
			_fail(round_index, "btree bucket %d holds %s, want %s" % [grp, got, want])
	if _btree._sorted_keys.size() != _btree_cache.size():
		_fail(
			round_index,
			("btree sorted keys %d, buckets %d" % [_btree._sorted_keys.size(), _btree_cache.size()]),
		)

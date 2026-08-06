# Behavioral test for _ModuleTableBTreeIndex over a bytes-backed key column
# (Identity / ConnectionId / u128 / u256 all map to PackedByteArray). Those values
# have no `<`, so Array.bsearch cannot order them and the sorted-key mirror that
# backs filter_range must not be maintained for them at all. Asserts:
#   - the buckets themselves stay correct for PackedByteArray keys,
#   - deleting the last row of a key drops the bucket,
#   - the sorted-key mirror stays empty for unorderable keys, so a long-lived
#     client that churns distinct identities does not grow it without bound,
#   - an orderable (int) key column still populates the mirror.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_btree_bytes_keys.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const CHURN_ROUNDS: int = 64

var _total: int = 0
var _db: LocalDatabase


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha", &"beta"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"alpha"] = &"id" # PK path without a disk schema
	_db._primary_key_cache[&"beta"] = &"id"

	var idx: _ModuleTableBTreeIndex = _ModuleTableBTreeIndex.new()
	idx._table_name = &"alpha"
	idx._field_name = &"owner"
	var cache: Dictionary = { }
	idx._connect_cache_to_db(cache, _db)

	var f: int = 0
	var a: PackedByteArray = _identity(1)
	var b: PackedByteArray = _identity(2)

	# Two owners, three rows: the multimap itself must work on bytes keys.
	_apply(&"alpha", [_Row.new(1, a), _Row.new(2, a), _Row.new(3, b)], [])
	f += _check_i("owner-a bucket", (cache.get(a, []) as Array).size(), 2)
	f += _check_i("owner-b bucket", (cache.get(b, []) as Array).size(), 1)
	f += _check_i("first_row of owner-b", idx._first_row(b).id, 3)

	# Deleting the last row of a key prunes its bucket.
	_apply(&"alpha", [], [_Row.new(3, b)])
	f += _check_b("owner-b bucket pruned", cache.has(b), false)

	# Every distinct-key create/drop pair the mirror cannot order must leave nothing
	# behind. Pre-fix, bsearch found the wrong slot on removal and the key stayed,
	# so the mirror grew by one entry per identity the client ever saw.
	for round_idx: int in range(CHURN_ROUNDS):
		var owner: PackedByteArray = _identity(100 + round_idx)
		_apply(&"alpha", [_Row.new(1000 + round_idx, owner)], [])
	f += _check_i("buckets after churn inserts", cache.size(), CHURN_ROUNDS + 1)
	for round_idx: int in range(CHURN_ROUNDS):
		var owner: PackedByteArray = _identity(100 + round_idx)
		_apply(&"alpha", [], [_Row.new(1000 + round_idx, owner)])
	f += _check_i("buckets drained after churn deletes", cache.size(), 1)
	f += _check_i("mirror not grown by unorderable keys", idx._sorted_keys.size(), 0)

	# An orderable column still maintains the mirror — the guard must not be broad
	# enough to disable range queries on int/float/String keys.
	var int_idx: _ModuleTableBTreeIndex = _ModuleTableBTreeIndex.new()
	int_idx._table_name = &"beta"
	int_idx._field_name = &"group"
	var int_cache: Dictionary = { }
	int_idx._connect_cache_to_db(int_cache, _db)
	_apply(&"beta", [_IntRow.new(1, 30), _IntRow.new(2, 10), _IntRow.new(3, 20)], [])
	f += _check_b("int mirror sorted", int_idx._sorted_keys == [10, 20, 30], true)
	_apply(&"beta", [], [_IntRow.new(2, 10)])
	f += _check_b("int mirror drops emptied key", int_idx._sorted_keys == [20, 30], true)
	return f


# 32-byte identity whose leading byte varies, like a real Identity blob.
func _identity(seed_byte: int) -> PackedByteArray:
	var out: PackedByteArray = []
	out.resize(32)
	out.fill(0xAB)
	out[0] = seed_byte & 0xFF
	out[1] = (seed_byte >> 8) & 0xFF
	return out


func _apply(table_name: StringName, inserts: Array, deletes: Array) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	_db.apply_table_update(u)


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


class _Row:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var owner: PackedByteArray = []


	func _init(p_id: int = 0, p_owner: PackedByteArray = []) -> void:
		id = p_id
		owner = p_owner


class _IntRow:
	extends _ModuleTableType
	const PRIMARY_KEY: StringName = &"id"
	@export var id: int = 0
	@export var group: int = 0


	func _init(p_id: int = 0, p_group: int = 0) -> void:
		id = p_id
		group = p_group

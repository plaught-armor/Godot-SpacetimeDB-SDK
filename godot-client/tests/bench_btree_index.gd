# Puts a number on the real-btree-index change: btree filter() (O(1) bucket cache)
# vs the equivalent linear find_by scan it replaced, over a table of N rows spread
# across M distinct indexed values (so each lookup returns ~N/M rows).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_btree_index.gd
extends SceneTree

const N: int = 20000 # rows in the table
const M: int = 200 # distinct indexed values → ~100 rows per value
const LOOKUPS: int = 5000 # filter calls to time
const REPS: int = 5

var _db: LocalDatabase
var _idx: _ModuleTableBTreeIndex
var _cache: Dictionary = { }
var _sink: int = 0


class _Row:
	extends _ModuleTableType
	@export var id: int = 0
	@export var group: int = 0


func _initialize() -> void:
	_build()
	# Validate the two paths agree before timing.
	var a: int = _cache.get(7, []).size()
	var b: int = _db.find_by(&"alpha", &"group", 7).size()
	if a != b:
		push_error("bench_btree_index: filter (%d) and linear (%d) disagree" % [a, b])
		quit(1)
		return

	var cache_us: int = _best(func() -> void: _bench_cache())
	var linear_us: int = _best(func() -> void: _bench_linear())

	print("rows=%d  values=%d  (~%d rows/value)  lookups=%d" % [N, M, N / M, LOOKUPS])
	print("  filter() cache  : %8.2f ms" % (cache_us / 1000.0))
	print("  linear find_by  : %8.2f ms  (%.1fx)" % [linear_us / 1000.0, float(linear_us) / maxf(cache_us, 1.0)])
	print("(sink=%d)" % _sink)
	quit(0)


func _build() -> void:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("bench_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"alpha"]
	_db = LocalDatabase.new(schema)
	_db._primary_key_cache[&"alpha"] = &"id"

	_idx = _ModuleTableBTreeIndex.new()
	_idx._table_name = &"alpha"
	_idx._field_name = &"group"
	_idx._connect_cache_to_db(_cache, _db)

	var rows: Array[Resource] = []
	for i: int in range(N):
		var r: _Row = _Row.new()
		r.id = i
		r.group = i % M
		rows.append(r)
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"alpha"
	u.inserts = rows
	_db.apply_table_update(u)


func _bench_cache() -> void:
	for i: int in range(LOOKUPS):
		_sink += _cache.get(i % M, []).size()


func _bench_linear() -> void:
	for i: int in range(LOOKUPS):
		_sink += _db.find_by(&"alpha", &"group", i % M).size()


func _best(fn: Callable) -> int:
	var best: int = 1 << 62
	for r: int in range(REPS):
		var t0: int = Time.get_ticks_usec()
		fn.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best:
			best = dt
	return best

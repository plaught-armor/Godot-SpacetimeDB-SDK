# Bench: what per-query membership costs on the subscribe path.
#
# A subscribe's rows are applied with query_id >= 0, so every inserted row also lands
# in that query's membership index. Counting references there (rather than storing the
# row alone) allocates a two-element Array per pk. This measures the insert wave with
# membership tracking on, against the same wave with it off (query_id = -1).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_bench_query_membership.gd
extends SceneTree

const ROWS: int = 100_000
const REPEATS: int = 7


class _Row:
	extends _ModuleTableType
	@export var id: int = 0


	static func make(p_id: int) -> _Row:
		var r: _Row = _Row.new()
		r.id = p_id
		return r


func _initialize() -> void:
	var rows: Array[Resource] = []
	for i: int in ROWS:
		rows.append(_Row.make(i))

	var tracked: int = _best(1, rows)
	var untracked: int = _best(-1, rows)
	print("rows: %d" % ROWS)
	print(
		"query_id >= 0 (membership): %7d usec (%.0f ns/row)"
		% [tracked, float(tracked) * 1000.0 / ROWS]
	)
	print(
		"query_id  = -1 (none)     : %7d usec (%.0f ns/row)"
		% [untracked, float(untracked) * 1000.0 / ROWS]
	)
	print("membership costs %+.1f%%" % ((float(tracked) / float(untracked) - 1.0) * 100.0))
	quit(0)


func _best(query_id: int, rows: Array[Resource]) -> int:
	var best: int = 1 << 62
	for _i: int in REPEATS:
		var db: LocalDatabase = _fresh()
		var update: TableUpdateData = TableUpdateData.new()
		update.table_name = &"pk"
		update.inserts = rows
		var start: int = Time.get_ticks_usec()
		db.apply_table_update(update, query_id)
		var elapsed: int = Time.get_ticks_usec() - start
		db.free()
		if elapsed < best:
			best = elapsed
	return best


func _fresh() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("bench", "res://__no_schema__", false)
	schema.raw_table_names = [&"pk"]
	var db: LocalDatabase = LocalDatabase.new(schema)
	db._primary_key_cache[&"pk"] = &"id"
	return db

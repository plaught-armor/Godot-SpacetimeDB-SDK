# Saturated end-to-end receive bench. Sizes the codegen-specialized-parser lever
# against the WHOLE inbound path, not parse in isolation. One DatabaseUpdate
# carrying N BlackholioEntity rows (i32 + nested DbVector2{f32,f32} + i32 = 16B),
# measured in the three stages the client runs on receive (spacetimedb_client.gd:656):
#
#   1. DECOMPRESS — gzip decode (unaffected by parser; brotli decode is slower)
#   2. ROW PARSE  — _read_bsatn_row_list_as_resources, the production plan path
#                   (this is the ONLY stage a specialized parser speeds up)
#   3. DB APPLY   — LocalDatabase.apply_table_update insert (unaffected by parser)
#
# Then projects the e2e speedup from swapping generic->specialized row parse using
# the per-row delta measured in bench_specialized_parser (generic 4.70 / spec 1.90).
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/bench_e2e_receive.gd
extends SceneTree

const N: int = 100000
const REPS: int = 5
const ROW_BYTES: int = 16

# Per-row populate cost from bench_specialized_parser (generic plan vs monomorphic).
# Used only to PROJECT the e2e win — the parse stage here is measured live.
const SPEC_SAVED_US_PER_ROW: float = 4.70 - 1.90

var _d: BSATNDeserializer = BSATNDeserializer.new(SpacetimeDBSchema.new("blackholio"), false)
var _db: LocalDatabase
var _sink: int = 0


func _initialize() -> void:
	_db = LocalDatabase.new(SpacetimeDBSchema.new("blackholio"))
	# Seed caches so apply hits the PK path without depending on disk-schema table reg.
	_db._primary_key_cache[&"entity"] = &"entity_id"
	_db._row_property_cache[&"entity"] = [&"entity_id", &"position", &"mass"] as Array[StringName]
	if not _db._tables.has(&"entity"):
		_db._tables[&"entity"] = { }

	var block: PackedByteArray = _build_block(N)
	# Godot brotli is decompress-only; gzip round-trips and is a representative
	# decompress cost (brotli decode is typically slower -> decompress share would
	# only grow, parse share shrink). Server-side codec varies.
	var compressed: PackedByteArray = block.compress(FileAccess.COMPRESSION_GZIP)
	if compressed.is_empty():
		push_error("bench_e2e_receive: gzip compress failed — aborting")
		quit(1)
		return

	# Validate the parse stage produces correct rows before timing.
	var check: Array[Resource] = _parse(block)
	if check.size() != N or int(check[0].entity_id) != 0 or int(check[1].mass) != _mass(1):
		push_error("bench_e2e_receive: parse validation failed — aborting")
		quit(1)
		return

	# Warm.
	_decompress(compressed)
	var rows: Array[Resource] = _parse(block)
	_apply(rows)

	var deco_us: int = _best(func() -> void: _sink += _decompress(compressed).size())
	var parse_us: int = _best(func() -> void: _sink += _parse(block).size())
	# Isolate apply: pre-parse once, clear table each rep, re-insert the same rows.
	var apply_only_us: int = _best(
		func() -> void:
			_db._tables[&"entity"] = { }
			_apply(rows)
	)
	var stored: int = _db.count_all_rows(&"entity")
	if stored != N:
		push_error("bench_e2e_receive: apply stored %d/%d rows — measurement invalid" % [stored, N])
		quit(1)
		return

	var total_us: int = deco_us + parse_us + apply_only_us
	var saved_us: float = SPEC_SAVED_US_PER_ROW * float(N)
	var new_total: float = float(total_us) - saved_us
	var e2e_speedup: float = float(total_us) / new_total if new_total > 0 else 0.0

	print("rows=%d  raw=%dB  compressed=%dB (%.1f%%)" % [N, block.size(), compressed.size(), 100.0 * compressed.size() / block.size()])
	print("stage           |   ms   | us/row | %% of e2e")
	print("1. decompress   | %6.1f | %6.3f | %5.1f%%" % [deco_us / 1000.0, float(deco_us) / N, 100.0 * deco_us / total_us])
	print("2. row parse    | %6.1f | %6.3f | %5.1f%%  <- specialized parser target" % [parse_us / 1000.0, float(parse_us) / N, 100.0 * parse_us / total_us])
	print("3. db apply     | %6.1f | %6.3f | %5.1f%%" % [apply_only_us / 1000.0, float(apply_only_us) / N, 100.0 * apply_only_us / total_us])
	print("   e2e total    | %6.1f | %6.3f |" % [total_us / 1000.0, float(total_us) / N])
	print("")
	print("projected: specialized parse saves %.0f us/rep -> e2e %.2fx (%.1f%% faster)" % [saved_us, e2e_speedup, 100.0 * (1.0 - new_total / total_us)])
	print("(sink=%d)" % _sink)
	quit(0)


func _best(thunk: Callable) -> int:
	var best: int = 1 << 62
	for _r: int in REPS:
		var t0: int = Time.get_ticks_usec()
		thunk.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best:
			best = dt
	return best


func _decompress(compressed: PackedByteArray) -> PackedByteArray:
	return compressed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)


func _parse(block: PackedByteArray) -> Array[Resource]:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = block
	return _d._read_bsatn_row_list_as_resources(spb, BlackholioEntity, "entity")


func _apply(rows: Array[Resource]) -> void:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"entity"
	u.inserts.assign(rows)
	_db.apply_table_update(u)


# FIXED_SIZE row list (tag 0): u8 tag, u16 row_size, u32 data_len, then N rows.
func _build_block(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u8(0)
	w.put_u16(ROW_BYTES)
	w.put_u32(n * ROW_BYTES)
	for i: int in range(n):
		w.put_32(_eid(i))
		w.put_float(float(i) * 0.5)
		w.put_float(float(i) * -0.25)
		w.put_32(_mass(i))
	return w.data_array


func _eid(i: int) -> int:
	return i % 2147483647


func _mass(i: int) -> int:
	return (i * 3 + 7) % 2147483647

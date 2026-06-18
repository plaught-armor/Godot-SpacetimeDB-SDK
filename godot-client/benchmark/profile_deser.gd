# Splits the real-workload replay into parse-only vs parse+apply to isolate the
# deserializer cost from the apply cost. Reports each phase's time + rows/sec.
#   <godot> --headless --path . --script res://benchmark/profile_deser.gd
extends SceneTree

const FIXTURE: String = "res://benchmark/bench_workload.bin"
const ITERS: int = 30

var _rows: int = 0


func _on_row(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	_rows += 1


func _load() -> Array:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(FIXTURE)
	var packets: Array = []
	var pos: int = 0
	while pos + 4 <= bytes.size():
		var n: int = bytes.decode_u32(pos)
		pos += 4
		if pos + n > bytes.size():
			break
		packets.append(bytes.slice(pos, pos + n))
		pos += n
	return packets


func _apply_message(db: LocalDatabase, msg: SpacetimeDBServerMessage) -> void:
	if msg is SubscribeAppliedMessage:
		db.apply_database_subscription_applied(msg)
	elif msg is TransactionUpdateMessage:
		for ds: DatabaseUpdateData in (msg as TransactionUpdateMessage).query_sets:
			db.apply_database_update(ds)


func _initialize() -> void:
	var packets: Array = _load()
	print("profile_deser: %d packets, %d iters" % [packets.size(), ITERS])

	# Phase A: parse only.
	var msg_count: int = 0
	var parse_us: int = 0
	for _it: int in ITERS:
		var deser: BSATNDeserializer = BSATNDeserializer.new(SpacetimeDBSchema.new("Blackholio", "res://spacetime_bindings/schema", false), false)
		var t0: int = Time.get_ticks_usec()
		for packet: PackedByteArray in packets:
			if packet.size() < 2:
				continue
			var msgs: Array = deser.process_bytes_and_extract_messages(packet.slice(1))
			msg_count += msgs.size()
		parse_us += Time.get_ticks_usec() - t0

	# Phase B: parse + apply.
	var both_us: int = 0
	for _it: int in ITERS:
		var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio", "res://spacetime_bindings/schema", false)
		var deser: BSATNDeserializer = BSATNDeserializer.new(schema, false)
		var db: LocalDatabase = LocalDatabase.new(schema)
		db.row_inserted.connect(_on_row)
		db.row_updated.connect(_on_row)
		db.row_deleted.connect(_on_row)
		var t0: int = Time.get_ticks_usec()
		for packet: PackedByteArray in packets:
			if packet.size() < 2:
				continue
			for msg: SpacetimeDBServerMessage in deser.process_bytes_and_extract_messages(packet.slice(1)):
				_apply_message(db, msg)
		both_us += Time.get_ticks_usec() - t0

	var rows_per_iter: int = _rows / ITERS
	var parse_s: float = parse_us / 1e6
	var both_s: float = both_us / 1e6
	var apply_s: float = both_s - parse_s
	print("PARSE-ONLY  %.3fs  (%.0f msgs/s, %.0f rows/s)" % [parse_s, msg_count / parse_s, rows_per_iter * ITERS / parse_s])
	print("PARSE+APPLY %.3fs  (%.0f rows/s)" % [both_s, _rows / both_s])
	print(
		(
				"SPLIT: parse=%.1f%%  apply=%.1f%%   (apply-only ~%.0f rows/s)"
				% [100.0 * parse_s / both_s, 100.0 * apply_s / both_s, _rows / apply_s if apply_s > 0 else 0]
		),
	)
	quit(0)

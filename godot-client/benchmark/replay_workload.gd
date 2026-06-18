# Real-workload apply benchmark: replays a captured Blackholio inbound packet stream
# (bench_workload.bin, from capture_workload.gd) through the deserializer + LocalDatabase
# in-process — no server, no network — so it saturates the deserialize+apply hot path on
# REAL data shapes (actual entity/circle/food row sizes and insert/update/delete mix),
# unlike the synthetic micro_bench. Reports packets/sec, messages/sec, and rows/sec.
#
#   <godot> --headless --path . --script res://benchmark/replay_workload.gd
#
# To compare branches: run on each and diff. Apply work only (Identity/Reducer/etc
# messages are parsed but not applied).
extends SceneTree

const FIXTURE: String = "res://benchmark/bench_workload.bin"
const ITERS: int = 30

var _rows: int = 0


func _on_ins(_t: StringName, _r: Resource) -> void:
	_rows += 1


func _on_upd(_t: StringName, _o: Resource, _n: Resource) -> void:
	_rows += 1


func _on_del(_t: StringName, _r: Resource) -> void:
	_rows += 1


func _load_packets() -> Array:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(FIXTURE)
	var packets: Array = []
	var pos: int = 0
	# Each record: u32 little-endian length + that many bytes. Tolerate a truncated tail.
	while pos + 4 <= bytes.size():
		var len: int = bytes.decode_u32(pos)
		pos += 4
		if pos + len > bytes.size():
			break # truncated final packet
		packets.append(bytes.slice(pos, pos + len))
		pos += len
	return packets


func _apply_message(db: LocalDatabase, msg: SpacetimeDBServerMessage) -> void:
	if msg is SubscribeAppliedMessage:
		db.apply_database_subscription_applied(msg)
	elif msg is TransactionUpdateMessage:
		for dataset: DatabaseUpdateData in (msg as TransactionUpdateMessage).query_sets:
			db.apply_database_update(dataset)


func _initialize() -> void:
	var packets: Array = _load_packets()
	if packets.is_empty():
		printerr("no packets in %s — run capture_workload.gd first" % FIXTURE)
		quit(1)
		return
	print("replay_workload: %d packets, %d iters" % [packets.size(), ITERS])

	var msg_count: int = 0
	var total_us: int = 0
	for _it: int in ITERS:
		# Fresh schema + deserializer + cache each round (cold, like a new connection).
		# A new schema each iter is required: LocalDatabase._init consumes (clears) the
		# schema's raw_table_names. Schema construction is NOT timed — only the replay is.
		var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio", "res://spacetime_bindings/schema", false)
		var deser: BSATNDeserializer = BSATNDeserializer.new(schema, false)
		var db: LocalDatabase = LocalDatabase.new(schema)
		db.row_inserted.connect(_on_ins)
		db.row_updated.connect(_on_upd)
		db.row_deleted.connect(_on_del)
		var t0: int = Time.get_ticks_usec()
		for packet: PackedByteArray in packets:
			if packet.size() < 2:
				continue
			var payload: PackedByteArray = packet.slice(1) # strip compression tag (0 = none)
			var msgs: Array = deser.process_bytes_and_extract_messages(payload)
			for msg: SpacetimeDBServerMessage in msgs:
				msg_count += 1
				_apply_message(db, msg)
		total_us += Time.get_ticks_usec() - t0
	var dt: float = total_us / 1e6

	print(
		(
				"RESULT %.0f packets/s | %.0f msgs/s | %.0f rows/s  (%d rows/iter, %.3fs total)"
				% [packets.size() * ITERS / dt, msg_count / dt, _rows / dt, _rows / ITERS, dt]
		),
	)
	quit(0)

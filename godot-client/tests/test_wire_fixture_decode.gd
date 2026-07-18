# Decodes REAL bytes captured off a live SpacetimeDB server.
#
# Every other test in this suite builds its wire bytes by hand or round-trips our
# serializer against our deserializer. Both are self-consistent: if our model of
# BSATN diverges from what the server actually sends, they all stay green. That is
# not hypothetical — value-returning procedures were broken on the wire while the
# full suite and the codegen goldens passed.
#
# tests/fixtures/wire_snapshot.bin is a length-prefixed capture of the raw inbound
# frames from `SELECT * FROM config` against the Blackholio module (compression
# NONE, so this is unwrapped BSATN framing). Recapture with capture_wire.gd if the
# module or the protocol changes.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_wire_fixture_decode.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const FIXTURE: String = "res://tests/fixtures/wire_snapshot.bin"
const TXN_FIXTURE: String = "res://tests/fixtures/wire_txn.bin"
const PROC_FIXTURE: String = "res://tests/fixtures/wire_procedure.bin"
# What blackholio-server's probe_vector3 procedure returns.
const EXPECTED_VECTOR: Vector3 = Vector3(1.5, -2.25, 3.75)
# Set by the module's init reducer — the value the server actually holds.
const EXPECTED_WORLD_SIZE: int = 1000

var _total: int = 0


func _initialize() -> void:
	var fails: int = _test_real_frames_decode()
	fails += _test_real_transaction_decodes()
	fails += _test_real_procedure_return_decodes()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _frames(path: String = FIXTURE) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while f.get_position() < f.get_length():
		var size: int = f.get_32()
		out.append(f.get_buffer(size))
	f.close()
	return out


func _test_real_frames_decode() -> int:
	var frames: Array[PackedByteArray] = _frames()
	var f: int = _check_b("fixture has frames", frames.is_empty(), false)
	if frames.is_empty():
		return f

	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("Blackholio")
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(schema, false)

	var config_rows: Array[Resource] = []
	for frame: PackedByteArray in frames:
		# Byte 0 is the compression tag the client strips before parsing; the capture
		# used NONE, so the rest is BSATN as-is.
		f += _check_i("frame is uncompressed", frame[0], 0)
		var payload: PackedByteArray = frame.slice(1)
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			payload
		):
			config_rows.append_array(_config_rows_in(msg))

	f += _check_b("no decode error on real bytes", deserializer.has_error(), false)
	f += _check_b("decoded a config row", config_rows.is_empty(), false)
	if config_rows.is_empty():
		return f
	var config: Resource = config_rows[0]
	f += _check_b("row is a BlackholioConfig", config is BlackholioConfig, true)
	f += _check_i("world_size matches the server", config.world_size, EXPECTED_WORLD_SIZE)

	# The entity row carries a nested DbVector2 — the shape a decode bug hides in.
	# Asserted structurally rather than by exact coordinates, which the server picks
	# at random and would change on every recapture.
	var entity: Resource = _first_row_in(frames, "entity")
	f += _check_b("decoded an entity row", entity != null, true)
	if entity == null:
		return f
	var position: Variant = entity.get("position")
	f += _check_b("nested DbVector2 decoded", position is BlackholioDbVector2, true)
	if position is BlackholioDbVector2:
		var inside: bool = (
			position.x >= 0.0 and position.x <= float(EXPECTED_WORLD_SIZE)
			and position.y >= 0.0 and position.y <= float(EXPECTED_WORLD_SIZE)
		)
		f += _check_b(
			"position lies inside the world (%.2f, %.2f)" % [position.x, position.y],
			inside,
			true,
		)
	return f


func _first_row_in(frames: Array[PackedByteArray], table_name: String) -> Resource:
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	for frame: PackedByteArray in frames:
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			frame.slice(1)
		):
			if msg is not SubscribeAppliedMessage:
				continue
			for table: TableUpdateData in (msg as SubscribeAppliedMessage).tables:
				if String(table.table_name) == table_name and not table.inserts.is_empty():
					return table.inserts[0]
	return null


# The reducer response for our OWN call carries the row changes inside it, rather
# than arriving as a separate broadcast — so this fixture exercises the reducer
# outcome enum AND the nested transaction update in one real message.
func _test_real_transaction_decodes() -> int:
	var frames: Array[PackedByteArray] = _frames(TXN_FIXTURE)
	var f: int = _check_b("txn fixture has frames", frames.is_empty(), false)
	if frames.is_empty():
		return f

	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	var results: Array[ReducerResultMessage] = []
	for frame: PackedByteArray in frames:
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			frame.slice(1)
		):
			if msg is ReducerResultMessage:
				results.append(msg)

	f += _check_b("no decode error on real bytes", deserializer.has_error(), false)
	f += _check_b("decoded a reducer result", results.is_empty(), false)
	if results.is_empty():
		return f

	var result: ReducerResultMessage = results[0]
	f += _check_i(
		"reducer outcome is ok",
		result.reducer_result.value,
		ReducerOutcomeEnum.Options.ok,
	)
	var txn: TransactionUpdateMessage = result.reducer_result.get_ok()
	f += _check_b("carries a transaction update", txn != null, true)
	if txn == null:
		return f

	var player_inserts: int = 0
	for query_set: DatabaseUpdateData in txn.query_sets:
		for table: TableUpdateData in query_set.tables:
			if String(table.table_name) == "player":
				player_inserts += table.inserts.size()
	f += _check_i("enter_game inserted the player row", player_inserts, 1)
	return f


# The path that shipped broken. A value-returning procedure returns Result<T, E>,
# which has no named Typespace entry — the synthesized type was flushed before
# returns were parsed, so the decoder was pointed at a type that did not exist and
# every such call failed. Synthetic tests could not see it; these are real bytes.
func _test_real_procedure_return_decodes() -> int:
	var frames: Array[PackedByteArray] = _frames(PROC_FIXTURE)
	var f: int = _check_b("procedure fixture has frames", frames.is_empty(), false)
	if frames.is_empty():
		return f

	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	var payloads: Array[PackedByteArray] = []
	for frame: PackedByteArray in frames:
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			frame.slice(1)
		):
			if msg is ProcedureResultData:
				payloads.append((msg as ProcedureResultData).return_bytes)

	f += _check_b("no decode error on real bytes", deserializer.has_error(), false)
	f += _check_b("decoded a procedure result", payloads.is_empty(), false)
	if payloads.is_empty():
		return f

	# Decode the Result<Vector3, String> payload the same way a generated call does.
	var value_deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.data_array = payloads[0]
	buffer.seek(0)
	var decoded: Variant = value_deserializer._read_value_from_bsatn_type(
		buffer,
		&"BlackholioResultVector3String",
		&"procedure_return",
	)
	f += _check_b("Result payload resolved", decoded != null, true)
	if decoded == null:
		printerr("      decode error: %s" % value_deserializer.get_last_error())
		return f
	var ok_value: Variant = decoded.get_ok()
	f += _check_b("ok variant holds a Vector3", ok_value is Vector3, true)
	if ok_value is Vector3:
		f += _check_b(
			"procedure return round-trips off the wire (%s)" % [ok_value],
			(ok_value as Vector3).is_equal_approx(EXPECTED_VECTOR),
			true,
		)
	return f


func _config_rows_in(msg: SpacetimeDBServerMessage) -> Array[Resource]:
	var out: Array[Resource] = []
	if msg is not SubscribeAppliedMessage:
		return out
	for update: TableUpdateData in (msg as SubscribeAppliedMessage).tables:
		if String(update.table_name) == "config":
			out.append_array(update.inserts)
	return out


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

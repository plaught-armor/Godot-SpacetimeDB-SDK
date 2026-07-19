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
const PROC_ERR_FIXTURE: String = "res://tests/fixtures/wire_procedure_err.bin"
# What blackholio-server's probe_error procedure returns.
const EXPECTED_ERROR: String = "probe failure"
const SQL_FIXTURE: String = "res://tests/fixtures/wire_one_off_query.bin"
const UNSUB_FIXTURE: String = "res://tests/fixtures/wire_unsubscribe.bin"
const SUB_ERR_FIXTURE: String = "res://tests/fixtures/wire_subscription_error.bin"
# The table the capture subscribes to and then drops.
const UNSUB_TABLE: String = "does_not_exist"
const PROC_PARAMS_FIXTURE: String = "res://tests/fixtures/wire_procedure_params.bin"
const IDENTITY_FIXTURE: String = "res://tests/fixtures/wire_identity_token.bin"
const RESUBSCRIBE_FIXTURE: String = "res://tests/fixtures/wire_resubscribe.bin"
# SpacetimeDB identities are 32 bytes (u256), connection ids 16 (u128).
const IDENTITY_BYTES: int = 32
const CONNECTION_ID_BYTES: int = 16
# probe_params(Vector3(1, 2, 3), scale = 3, label = "hello") scales its vector
# argument, so this value is only reachable if all three parameters arrived.
const EXPECTED_SCALED: Vector3 = Vector3(3.0, 6.0, 9.0)
# Set by the module's init reducer — the value the server actually holds.
const EXPECTED_WORLD_SIZE: int = 1000

var _total: int = 0


func _initialize() -> void:
	var fails: int = _test_real_frames_decode()
	fails += _test_real_transaction_decodes()
	fails += _test_real_procedure_return_decodes()
	fails += _test_real_procedure_error_decodes()
	fails += _test_real_one_off_query_decodes()
	fails += _test_real_unsubscribe_decodes()
	fails += _test_real_subscription_error_decodes()
	fails += _test_real_procedure_params_decode()
	fails += _test_real_identity_token_decodes()
	fails += _test_real_resubscribe_decodes()

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


# The err arm of the same Result type the ok arm above exercises. Nothing in the
# suite asserted an err payload at all — the type was fixed and shipped having
# only ever been checked on its happy path.
func _test_real_procedure_error_decodes() -> int:
	var frames: Array[PackedByteArray] = _frames(PROC_ERR_FIXTURE)
	var f: int = _check_b("err fixture has frames", frames.is_empty(), false)
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
	f += _check_b("err payload resolved", decoded != null, true)
	if decoded == null:
		printerr("      decode error: %s" % value_deserializer.get_last_error())
		return f
	# get_ok()/get_err() are unguarded accessors — both just return `data`. The
	# discriminator is `value`, so that is what actually distinguishes the arms.
	f += _check_i(
		"discriminator selects err",
		decoded.value,
		BlackholioResultVector3String.Options.err,
	)
	f += _check_s("err message round-trips off the wire", str(decoded.get_err()), EXPECTED_ERROR)
	return f


# query_sql had no test of any kind — not synthetic, not wire — and its awaiter
# silently dropped every result. These are the real response bytes.
func _test_real_one_off_query_decodes() -> int:
	var frames: Array[PackedByteArray] = _frames(SQL_FIXTURE)
	var f: int = _check_b("one-off query fixture has frames", frames.is_empty(), false)
	if frames.is_empty():
		return f

	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	var responses: Array[OneOffQueryResponseMessage] = []
	for frame: PackedByteArray in frames:
		for msg: SpacetimeDBServerMessage in deserializer.process_bytes_and_extract_messages(
			frame.slice(1)
		):
			if msg is OneOffQueryResponseMessage:
				responses.append(msg)

	f += _check_b("no decode error on real bytes", deserializer.has_error(), false)
	f += _check_b("decoded a one-off query response", responses.is_empty(), false)
	if responses.is_empty():
		return f

	var response: OneOffQueryResponseMessage = responses[0]
	f += _check_b("query reported no error", response.is_error, false)
	var config_rows: Array[Resource] = []
	for table: TableUpdateData in response.tables:
		if String(table.table_name) == "config":
			config_rows.append_array(table.inserts)
	f += _check_b("returned the config row", config_rows.is_empty(), false)
	if not config_rows.is_empty():
		f += _check_i(
			"world_size matches the server",
			config_rows[0].world_size,
			EXPECTED_WORLD_SIZE,
		)
	return f


# Both of these work today. They are captured so a silent regression on the
# teardown and error paths shows up here rather than in someone's game.
func _test_real_unsubscribe_decodes() -> int:
	var messages: Array[SpacetimeDBServerMessage] = _messages_in(UNSUB_FIXTURE)
	var f: int = _check_b("unsubscribe fixture decoded", messages.is_empty(), false)
	var applied: Array[UnsubscribeAppliedMessage] = []
	for msg: SpacetimeDBServerMessage in messages:
		if msg is UnsubscribeAppliedMessage:
			applied.append(msg)
	f += _check_b("decoded an UnsubscribeApplied", applied.is_empty(), false)
	if applied.is_empty():
		return f
	f += _check_b("carries a query id", applied[0].query_id != null, true)
	return f


func _test_real_subscription_error_decodes() -> int:
	var messages: Array[SpacetimeDBServerMessage] = _messages_in(SUB_ERR_FIXTURE)
	var f: int = _check_b("subscription error fixture decoded", messages.is_empty(), false)
	var errors: Array[SubscriptionErrorMessage] = []
	for msg: SpacetimeDBServerMessage in messages:
		if msg is SubscriptionErrorMessage:
			errors.append(msg)
	f += _check_b("decoded a SubscriptionError", errors.is_empty(), false)
	if errors.is_empty():
		return f
	# The server explains itself; assert the table name survives rather than
	# pinning wording that SpacetimeDB is free to reword.
	f += _check_b(
		"error names the missing table",
		errors[0].error_message.contains(UNSUB_TABLE),
		true,
	)
	return f


# Procedure PARAMETERS had no coverage at all, and they take a different codegen
# path (_param_to_bsatn_type) than the returns fixed in 2.5.0. The module computes
# its answer from the arguments, so decoding the expected value here proves the
# arguments serialized correctly — the response is the receipt for the request.
func _test_real_procedure_params_decode() -> int:
	var payloads: Array[PackedByteArray] = []
	for msg: SpacetimeDBServerMessage in _messages_in(PROC_PARAMS_FIXTURE):
		if msg is ProcedureResultData:
			payloads.append((msg as ProcedureResultData).return_bytes)

	var f: int = _check_b("decoded a procedure result", payloads.is_empty(), false)
	if payloads.is_empty():
		return f

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
	f += _check_b("payload resolved", decoded != null, true)
	if decoded == null:
		printerr("      decode error: %s" % value_deserializer.get_last_error())
		return f
	f += _check_i(
		"discriminator selects ok",
		decoded.value,
		BlackholioResultVector3String.Options.ok,
	)
	var scaled: Variant = decoded.get_ok()
	f += _check_b(
		"arguments round-tripped (%s)" % [scaled],
		(scaled is Vector3 and (scaled as Vector3).is_equal_approx(EXPECTED_SCALED)),
		true,
	)
	return f


# The first message of every session, and the last one to get real-bytes coverage:
# it arrives mid-handshake, so the capture hook has to be attached before the
# connection completes rather than in the `connected` handler. It also carries the
# only wide scalars the suite sees off the wire — a 32-byte identity and a 16-byte
# connection id, both hand-built bytes everywhere else.
func _test_real_identity_token_decodes() -> int:
	var tokens: Array[IdentityTokenMessage] = []
	for msg: SpacetimeDBServerMessage in _messages_in(IDENTITY_FIXTURE):
		if msg is IdentityTokenMessage:
			tokens.append(msg)

	var f: int = _check_b("decoded an IdentityToken", tokens.is_empty(), false)
	if tokens.is_empty():
		return f

	var token: IdentityTokenMessage = tokens[0]
	f += _check_i("identity is a 256-bit value", token.identity.size(), IDENTITY_BYTES)
	f += _check_i(
		"connection id is a 128-bit value",
		token.connection_id.size(),
		CONNECTION_ID_BYTES,
	)
	# The identity is derived, never all-zero; a zeroed buffer is what a decode
	# that read the right length off the wrong offset would produce.
	var zeroed: PackedByteArray = []
	zeroed.resize(IDENTITY_BYTES)
	f += _check_b("identity is not a zeroed buffer", token.identity == zeroed, false)
	# Shape only — the value is a per-session credential and changes every capture.
	f += _check_i("token is a three-part JWT", token.token.split(".").size(), 3)
	return f


# What the server sends while the client recovers from a dropped socket, captured
# by _live_reconnect_check.gd. The recovery itself is client state machine
# behaviour that no fixture can replay — that harness asserts it live — but the
# snapshot the server replays to a re-subscribing client is wire data, and this is
# it: the same rows, arriving on a connection the caller never asked to open.
func _test_real_resubscribe_decodes() -> int:
	var rows: Array[Resource] = []
	for msg: SpacetimeDBServerMessage in _messages_in(RESUBSCRIBE_FIXTURE):
		rows.append_array(_config_rows_in(msg))

	var f: int = _check_b("resubscribe replayed the config row", rows.is_empty(), false)
	if rows.is_empty():
		return f
	f += _check_i("world_size survives the reconnect", rows[0].world_size, EXPECTED_WORLD_SIZE)
	return f


func _messages_in(fixture: String) -> Array[SpacetimeDBServerMessage]:
	var out: Array[SpacetimeDBServerMessage] = []
	var deserializer: BSATNDeserializer = BSATNDeserializer.new(
		SpacetimeDBSchema.new("Blackholio"),
		false,
	)
	for frame: PackedByteArray in _frames(fixture):
		out.append_array(deserializer.process_bytes_and_extract_messages(frame.slice(1)))
	return out


func _config_rows_in(msg: SpacetimeDBServerMessage) -> Array[Resource]:
	var out: Array[Resource] = []
	if msg is not SubscribeAppliedMessage:
		return out
	for update: TableUpdateData in (msg as SubscribeAppliedMessage).tables:
		if String(update.table_name) == "config":
			out.append_array(update.inserts)
	return out


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


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

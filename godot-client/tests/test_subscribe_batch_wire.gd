# Wire test for the batch subscribe pair (SpacetimeDB 2.10.2+, v2.rs @v2.16.3):
#   ClientMessage::SubscribeBatch (tag 5)
#     { request_id: u32, sets: [SubscribeSet{query_set_id: u32, query_strings: [string]}] }
#   ServerMessage::SubscribeBatchApplied (tag 8)
#     { request_id: u32, results: [SubscribeSetResult{query_set_id: u32, outcome}] }
#     outcome: tag 0 = Applied(QueryRows), tag 1 = Error(string)
#
# The client side is checked byte-for-byte against a hand-built expectation and then
# decoded back field by field (the SDK has no reader for its own outbound messages, so
# the decode lives here). The server side is fed hand-built bytes covering both outcome
# variants, an empty result list, rows that parse against a registered schema, a table
# the schema does not know, and a bad outcome tag.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_subscribe_batch_wire.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_TYPE_PATH: String = "res://tests/_test_row_type.gd"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_serialize_bytes()
	f += _test_serialize_roundtrip()
	f += _test_serialize_empty()
	f += _test_decode_mixed_outcomes()
	f += _test_decode_empty_results()
	f += _test_decode_bad_outcome_tag()
	f += _test_decode_truncated()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)

# --- client side --------------------------------------------------------------


func _batch() -> SubscribeBatchMessage:
	# Array[String], not packed: the shape SubscribeSetData.query_strings takes.
	var a: Array[String] = ["SELECT * FROM pair"] # gdlint: ignore[S6]
	var b: Array[String] = ["q1", "q22"] # gdlint: ignore[S6]
	var sets: Array[SubscribeSetData] = [SubscribeSetData.new(1, a), SubscribeSetData.new(9, b)]
	return SubscribeBatchMessage.new(7, sets)


func _serialize(msg: SubscribeBatchMessage) -> PackedByteArray:
	var ser: BSATNSerializer = BSATNSerializer.new(false)
	var bytes: PackedByteArray = ser.serialize_client_message(
		SpacetimeDBClientMessage.SUBSCRIBE_BATCH,
		msg,
	)
	if ser.has_error():
		printerr("serializer error: ", ser.get_last_error())
	return bytes


func _test_serialize_bytes() -> int:
	var w: _Writer = _Writer.new()
	w.u8(5)
	w.u32(7) # request_id
	w.u32(2) # sets
	w.u32(1) # set 0: query_set_id
	w.u32(1)
	w.str("SELECT * FROM pair")
	w.u32(9) # set 1: query_set_id
	w.u32(2)
	w.str("q1")
	w.str("q22")
	return _check_bytes("SubscribeBatch bytes", _serialize(_batch()), w.out)


func _test_serialize_roundtrip() -> int:
	var src: SubscribeBatchMessage = _batch()
	var r: _Reader = _Reader.new(_serialize(src))
	var f: int = 0
	f += _check_i("tag", r.u8(), SpacetimeDBClientMessage.SUBSCRIBE_BATCH)
	f += _check_i("request_id", r.u32(), src.request_id)
	var set_count: int = r.u32()
	f += _check_i("set count", set_count, src.sets.size())
	for i: int in mini(set_count, src.sets.size()):
		var want: SubscribeSetData = src.sets[i]
		f += _check_i("set %d id" % i, r.u32(), want.query_set_id)
		var q_count: int = r.u32()
		f += _check_i("set %d query count" % i, q_count, want.query_strings.size())
		for j: int in mini(q_count, want.query_strings.size()):
			f += _check_s("set %d query %d" % [i, j], r.str(), want.query_strings[j])
	f += _check_b("no bytes left over", r.at_end() and not r.bad, true)
	return f


func _test_serialize_empty() -> int:
	var w: _Writer = _Writer.new()
	w.u8(5)
	w.u32(3)
	w.u32(0)
	var empty: Array[SubscribeSetData] = []
	return _check_bytes(
		"empty SubscribeBatch bytes",
		_serialize(SubscribeBatchMessage.new(3, empty)),
		w.out,
	)

# --- server side --------------------------------------------------------------


func _deserializer() -> BSATNDeserializer:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("none", "res://tests/_no_such_schema_dir")
	schema.tables[&"pair"] = load(ROW_TYPE_PATH)
	return BSATNDeserializer.new(schema, false)


# FixedSize row list of `pair` rows (two u32 each).
func _pair_rows(w: _Writer, rows: Array[Vector2i]) -> void:
	w.u8(0)
	w.u16(8)
	w.u32(rows.size() * 8)
	for row: Vector2i in rows:
		w.u32(row.x)
		w.u32(row.y)


func _test_decode_mixed_outcomes() -> int:
	var w: _Writer = _Writer.new()
	w.u8(8)
	w.u32(41) # request_id
	w.u32(3) # results
	# 0: applied, two tables — one known (2 rows), one unknown (skipped, kept as empty)
	w.u32(5)
	w.u8(0)
	w.u32(2)
	w.str("pair")
	_pair_rows(w, [Vector2i(1, 2), Vector2i(3, 4)])
	w.str("mystery")
	w.u8(0)
	w.u16(4)
	w.u32(4)
	w.u32(0xDEADBEEF)
	# 1: error
	w.u32(6)
	w.u8(1)
	w.str("no such table `nope`")
	# 2: applied, no tables
	w.u32(7)
	w.u8(0)
	w.u32(0)

	var d: BSATNDeserializer = _deserializer()
	var msgs: Array[SpacetimeDBServerMessage] = d.process_bytes_and_extract_messages(w.out)
	var f: int = _check_b("mixed: no parse error", d.has_error(), false)
	f += _check_i("mixed: one message", msgs.size(), 1)
	if msgs.size() != 1 or msgs[0] is not SubscribeBatchAppliedMessage:
		return f + _check_b("mixed: is SubscribeBatchApplied", false, true)
	var m: SubscribeBatchAppliedMessage = msgs[0]
	f += _check_i("mixed: request_id", m.request_id, 41)
	f += _check_i("mixed: result count", m.results.size(), 3)
	if m.results.size() != 3:
		return f
	var r0: SubscribeSetResultData = m.results[0]
	f += _check_i("r0 id", r0.query_set_id, 5)
	f += _check_b("r0 applied", r0.is_error, false)
	f += _check_i("r0 tables", r0.tables.size(), 2)
	if r0.tables.size() == 2:
		f += _check_s("r0 t0 name", String(r0.tables[0].table_name), "pair")
		f += _check_i("r0 t0 rows", r0.tables[0].inserts.size(), 2)
		if r0.tables[0].inserts.size() == 2:
			f += _check_i("r0 t0 row1.b", r0.tables[0].inserts[1].b, 4)
		f += _check_s("r0 t1 name", String(r0.tables[1].table_name), "mystery")
		f += _check_i("r0 t1 rows dropped", r0.tables[1].inserts.size(), 0)
	var r1: SubscribeSetResultData = m.results[1]
	f += _check_i("r1 id", r1.query_set_id, 6)
	f += _check_b("r1 error", r1.is_error, true)
	f += _check_s("r1 message", r1.error_message, "no such table `nope`")
	f += _check_i("r1 no tables", r1.tables.size(), 0)
	var r2: SubscribeSetResultData = m.results[2]
	f += _check_i("r2 id", r2.query_set_id, 7)
	f += _check_b("r2 applied", r2.is_error, false)
	f += _check_i("r2 no tables", r2.tables.size(), 0)
	return f


# A batch with no sets is legal on the wire; the SDK never sends one, but the reader
# must not choke on it.
func _test_decode_empty_results() -> int:
	var w: _Writer = _Writer.new()
	w.u8(8)
	w.u32(2)
	w.u32(0)
	var d: BSATNDeserializer = _deserializer()
	var msgs: Array[SpacetimeDBServerMessage] = d.process_bytes_and_extract_messages(w.out)
	var f: int = _check_b("empty: no parse error", d.has_error(), false)
	f += _check_i("empty: one message", msgs.size(), 1)
	if msgs.size() == 1 and msgs[0] is SubscribeBatchAppliedMessage:
		f += _check_i(
			"empty: zero results",
			(msgs[0] as SubscribeBatchAppliedMessage).results.size(),
			0,
		)
	return f


func _test_decode_bad_outcome_tag() -> int:
	var w: _Writer = _Writer.new()
	w.u8(8)
	w.u32(1)
	w.u32(1)
	w.u32(5)
	w.u8(2) # no such variant
	var d: BSATNDeserializer = _deserializer()
	var msgs: Array[SpacetimeDBServerMessage] = d.process_bytes_and_extract_messages(w.out)
	var f: int = _check_b("bad tag: error set", d.has_error(), true)
	f += _check_i("bad tag: nothing delivered", msgs.size(), 0)
	f += _check_b("bad tag: names the outcome", "SubscribeSetOutcome" in d.get_last_error(), true)
	return f


# A result count promising more than the packet holds fails, it does not hang or
# deliver a partial message.
func _test_decode_truncated() -> int:
	var w: _Writer = _Writer.new()
	w.u8(8)
	w.u32(1)
	w.u32(0xFFFFFFFF)
	w.u32(5)
	w.u8(0)
	w.u32(0)
	var d: BSATNDeserializer = _deserializer()
	var msgs: Array[SpacetimeDBServerMessage] = d.process_bytes_and_extract_messages(w.out)
	var f: int = _check_b("truncated: error set", d.has_error(), true)
	f += _check_i("truncated: nothing delivered", msgs.size(), 0)
	return f

# --- helpers ------------------------------------------------------------------


class _Writer:
	var out: PackedByteArray = []


	func u8(v: int) -> void:
		out.append(v)


	func u16(v: int) -> void:
		var at: int = out.size()
		out.resize(at + 2)
		out.encode_u16(at, v)


	func u32(v: int) -> void:
		var at: int = out.size()
		out.resize(at + 4)
		out.encode_u32(at, v)


	func str(v: String) -> void:
		var b: PackedByteArray = v.to_utf8_buffer()
		u32(b.size())
		out.append_array(b)


class _Reader:
	var data: PackedByteArray
	var pos: int = 0
	var bad: bool = false


	func _init(p_data: PackedByteArray) -> void:
		data = p_data


	func u8() -> int:
		if pos + 1 > data.size():
			bad = true
			return -1
		pos += 1
		return data[pos - 1]


	func u32() -> int:
		if pos + 4 > data.size():
			bad = true
			return -1
		pos += 4
		return data.decode_u32(pos - 4)


	func str() -> String:
		var n: int = u32()
		if bad or pos + n > data.size():
			bad = true
			return ""
		pos += n
		return data.slice(pos - n, pos).get_string_from_utf8()


	func at_end() -> bool:
		return pos == data.size()


func _check_bytes(label: String, got: PackedByteArray, want: PackedByteArray) -> int:
	_total += 1
	if got == want:
		print("PASS  %s (%d bytes)" % [label, got.size()])
		return 0
	printerr("FAIL  %s:\n  got  %s\n  want %s" % [label, got.hex_encode(), want.hex_encode()])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


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

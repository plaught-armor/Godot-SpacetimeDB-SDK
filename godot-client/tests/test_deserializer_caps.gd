# Regression test for the row-list and collection bounds in BSATNDeserializer.
#
# Two things have to hold at once, and the SDK used to get only the first:
#
#   1. A malformed/hostile header carries attacker-influenced u32 counts. Without a
#      bound, `offsets.resize(count + 1)` allocates gigabytes before any read (OOM),
#      and a data_len past the buffer makes the row reader seek past EOF and silently
#      drop every following message.
#   2. A LEGITIMATE payload must still parse. The bound used to be a fixed count
#      (MAX_VEC_LEN, 131072) unrelated to the bytes present, and the server chunks
#      nothing — one query result is one row list — so a 200 000-row table (800 KB,
#      well inside the default 2 MiB inbound buffer) was refused outright, the
#      subscription never applied, and the mirror stayed empty. Same for a Vec<f32>
#      column carrying a 200 000-cell grid.
#
# So the bound is now the bytes actually behind the count. MAX_VEC_LEN survives only
# as the floor for a zero-width element type, whose count has no bytes to check.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_deserializer_caps.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const RowType: GDScript = preload("res://spacetime_bindings/schema/types/blackholio_food.gd")
const BIG: int = 200000

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_fixed_size_unbacked_len()
	fails += _test_row_offsets_unbacked_count()
	fails += _test_block_end_past_buffer()
	fails += _test_valid_header_ok()
	fails += _test_fixed_size_big_table_parses()
	fails += _test_row_offsets_big_table_parses()
	fails += _test_array_big_column_parses()
	fails += _test_array_unbacked_length()
	fails += _test_array_zero_width_floor()
	fails += _test_string_unbacked_length()
	fails += _test_vec_u8_unbacked_length()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)

# --- hostile input: a count with no bytes behind it ---


# FixedSize: u8 tag(0), u16 row_size, u32 data_len. num_rows = data_len/row_size.
func _test_fixed_size_unbacked_len() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(0)
	spb.put_u16(1) # row_size = 1
	spb.put_u32(4294967295) # data_len at u32 max, with no data following
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d._read_row_block_header(spb)
	# On the message, not just on has_error(): every one of these inputs also fails at
	# the downstream read, so an assertion that "some error fired" would pass with the
	# bound deleted and the allocation it prevents still attempted.
	return _check_b(
		"FixedSize unbacked data_len -> refused by the bound",
		d.get_last_error().contains("FixedSize block needs"),
		true,
	)


# RowOffsets: u8 tag(1), u32 num_offsets, then num_offsets u64s. The count is the OOM
# lever, and each offset it claims costs 8 bytes that have to be present.
func _test_row_offsets_unbacked_count() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(1)
	spb.put_u32(4294967295)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d._read_row_block_header(spb)
	return _check_b(
		"RowOffsets unbacked count -> refused by the bound",
		d.get_last_error().contains("RowOffsets needs"),
		true,
	)


# Valid header but data_len claims more bytes than the buffer holds -> NEEDS_MORE.
func _test_block_end_past_buffer() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(1) # RowOffsets
	spb.put_u32(1) # num_offsets = 1
	spb.put_u64(0) # offset[0] = 0
	spb.put_u32(1000) # data_len = 1000, but no row data follows
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d._read_bsatn_row_list_as_resources(spb, RowType, "tbl")
	var f: int = 0
	f += _check_b("block past buffer -> has_error", d.has_error(), true)
	f += _check_b(
		"block past buffer -> NEEDS_MORE",
		d._status == BSATNDeserializer.ParseStatus.NEEDS_MORE,
		true,
	)
	return f

# --- legitimate input: big, but backed by bytes ---


# A well-formed small FixedSize block parses cleanly — the bounds don't false-trip.
func _test_valid_header_ok() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(0)
	spb.put_u16(4) # row_size = 4
	spb.put_u32(8) # data_len = 8 -> num_rows = 2
	spb.put_u32(0)
	spb.put_u32(1)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	var header: Dictionary = d._read_row_block_header(spb)
	var f: int = 0
	f += _check_b("valid header no error", d.has_error(), false)
	f += _check_i("valid header count", header.get("count", -1), 2)
	return f


# The measured case: 200 000 rows of one i32 column. 800 KB on the wire, refused
# before this fix because the count alone was over MAX_VEC_LEN.
func _test_fixed_size_big_table_parses() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(0)
	spb.put_u16(4)
	spb.put_u32(BIG * 4)
	for i: int in BIG:
		spb.put_u32(i)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	var rows: Array[Resource] = d._read_bsatn_row_list_as_resources(spb, RowType, "food")
	var f: int = 0
	f += _check_b("big FixedSize table no error", d.has_error(), false)
	f += _check_i("big FixedSize table rows", rows.size(), BIG)
	f += _check_i(
		"big FixedSize last row value",
		(rows[BIG - 1] as Resource).get("entity_id"),
		BIG - 1,
	)
	return f


# The same row count in the offsets encoding, which the server picks for rows that are
# not all one size.
func _test_row_offsets_big_table_parses() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(1)
	spb.put_u32(BIG)
	for i: int in BIG:
		spb.put_u64(i * 4)
	spb.put_u32(BIG * 4)
	for i: int in BIG:
		spb.put_u32(i)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	var rows: Array[Resource] = d._read_bsatn_row_list_as_resources(spb, RowType, "food")
	var f: int = 0
	f += _check_b("big RowOffsets table no error", d.has_error(), false)
	f += _check_i("big RowOffsets table rows", rows.size(), BIG)
	return f


# A Vec<f32> column with 200 000 cells — a heightmap or tile grid. Same defect, other
# code path.
func _test_array_big_column_parses() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u32(BIG)
	for i: int in BIG:
		spb.put_float(float(i))
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	var out: Array = d._read_array(spb, _float_array_prop(), &"f32")
	var f: int = 0
	f += _check_b("big array column no error", d.has_error(), false)
	f += _check_i("big array column length", out.size(), BIG)
	return f


# The bomb the bound exists for: a count past both the floor and the bytes present.
func _test_array_unbacked_length() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u32(4294967295)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d._read_array(spb, _float_array_prop(), &"f32")
	return _check_b(
		"unbacked array length -> refused by the bound",
		d.get_last_error().contains("exceeds both"),
		true,
	)


# Why the bound is not bytes ALONE: a zero-width element type — a fieldless struct,
# which SpacetimeDB accepts (`#[derive(SpacetimeType)] struct Empty {}` publishes, and
# a `Vec<Empty>` column decoded correctly through this reader against a live 2.8.0
# server) — encodes N elements in no bytes at all. Its count is the one that cannot be
# checked against the data behind it, so counts up to MAX_VEC_LEN must reach the
# element reader untouched. Asserted here on the guard rather than on a fieldless
# element type, which would need a schema directory to resolve: a sub-floor count with
# no bytes behind it must fail at the element READ, not at the length bound.
func _test_array_zero_width_floor() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u32(1000) # 1000 elements, zero bytes of payload
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d._read_array(spb, _float_array_prop(), &"f32")
	var message: String = d.get_last_error()
	var f: int = 0
	f += _check_b("sub-floor count reaches the element reader", message.contains("past end"), true)
	f += _check_b(
		"sub-floor count not refused by the length bound",
		message.contains("exceeds both"),
		false,
	)
	return f

# --- byte-length fields ---


func _test_string_unbacked_length() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u32(4294967295)
	spb.put_u8(65)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d.read_string_with_u32_len(spb)
	return _check_b(
		"unbacked string length -> refused by the bound",
		d.get_last_error().contains("String length"),
		true,
	)


func _test_vec_u8_unbacked_length() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u32(4294967295)
	spb.put_u8(65)
	spb.seek(0)
	var d: BSATNDeserializer = _fresh()
	d.read_vec_u8(spb)
	return _check_b(
		"unbacked Vec<u8> length -> refused by the bound",
		d.get_last_error().contains("Vec<u8> length"),
		true,
	)

# --- helpers ---


func _fresh() -> BSATNDeserializer:
	# A real schema object: BSATNDeserializer dereferences _schema unguarded.
	return BSATNDeserializer.new(SpacetimeDBSchema.new("caps", "res://__no_schema__", false), false)


# The property dictionary codegen produces for an `Array[float]` column.
func _float_array_prop() -> Dictionary:
	return {
		"name": &"cells",
		"type": TYPE_ARRAY,
		"hint": PROPERTY_HINT_ARRAY_TYPE,
		"hint_string": str(TYPE_FLOAT),
	}


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

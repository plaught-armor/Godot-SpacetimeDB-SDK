# Correctness test for BSATN BsatnRowList deserialization. Builds row-list byte
# streams by hand and verifies both reader paths:
#   - read_bsatn_row_list           → raw per-row byte slices
#   - _read_bsatn_row_list_as_resources → parsed Array[Resource]
# Covers both row encodings (FIXED_SIZE tag 0, ROW_OFFSETS tag 1), row values,
# count, and that the message buffer is left at the block end so the caller
# resumes correctly (proven by reading a trailing sentinel after the row list).
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_row_parse.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_TYPE_PATH: String = "res://addons/SpacetimeDB/tests/_test_row_type.gd"
const SENTINEL: int = 0x12345678

var _total: int = 0
var _row_script: GDScript = load(ROW_TYPE_PATH)


func _initialize() -> void:
	var fails: int = 0
	fails += _test_fixed_size_as_resources()
	fails += _test_row_offsets_as_resources()
	fails += _test_slice_path_bytes()
	fails += _test_zero_rows()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# rows = [[a,b], ...]. Writes a FIXED_SIZE (tag 0) row list of 8-byte rows,
# then a trailing u32 sentinel. Returns a seeked-to-0 read buffer.
func _build_fixed(rows: Array) -> StreamPeerBuffer:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u8(0) # ROW_LIST_FIXED_SIZE
	w.put_u16(8) # row_size
	w.put_u32(rows.size() * 8) # data_len
	for row: Array in rows:
		w.put_u32(row[0])
		w.put_u32(row[1])
	w.put_u32(SENTINEL)
	return _reader(w)


# ROW_OFFSETS (tag 1): explicit u64 offsets then the data block + sentinel.
func _build_offsets(rows: Array) -> StreamPeerBuffer:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u8(1) # ROW_LIST_ROW_OFFSETS
	w.put_u32(rows.size()) # num_offsets
	for i: int in range(rows.size()):
		w.put_u64(i * 8)
	w.put_u32(rows.size() * 8) # data_len
	for row: Array in rows:
		w.put_u32(row[0])
		w.put_u32(row[1])
	w.put_u32(SENTINEL)
	return _reader(w)


func _reader(w: StreamPeerBuffer) -> StreamPeerBuffer:
	var r: StreamPeerBuffer = StreamPeerBuffer.new()
	r.data_array = w.data_array
	r.seek(0)
	return r


func _new_deser() -> BSATNDeserializer:
	return BSATNDeserializer.new(null, false)


func _parse_resources(d: BSATNDeserializer, spb: StreamPeerBuffer) -> Array[Resource]:
	var row_spb: StreamPeerBuffer = StreamPeerBuffer.new()
	return d._read_bsatn_row_list_as_resources(spb, _row_script, "test", row_spb)


func _test_fixed_size_as_resources() -> int:
	var d: BSATNDeserializer = _new_deser()
	var spb: StreamPeerBuffer = _build_fixed([[1, 2], [3, 4], [5, 6]])
	var rows: Array[Resource] = _parse_resources(d, spb)
	var f: int = 0
	f += _check_b("fixed: no error", d.has_error(), false)
	f += _check_i("fixed: row count", rows.size(), 3)
	if rows.size() == 3:
		f += _check_i("fixed: row0.a", rows[0].a, 1)
		f += _check_i("fixed: row0.b", rows[0].b, 2)
		f += _check_i("fixed: row2.a", rows[2].a, 5)
		f += _check_i("fixed: row2.b", rows[2].b, 6)
	# Buffer must sit at block end → the sentinel reads back intact.
	f += _check_i("fixed: spb at block end (sentinel)", d.read_u32_le(spb), SENTINEL)
	return f


func _test_row_offsets_as_resources() -> int:
	var d: BSATNDeserializer = _new_deser()
	var spb: StreamPeerBuffer = _build_offsets([[10, 20], [30, 40]])
	var rows: Array[Resource] = _parse_resources(d, spb)
	var f: int = 0
	f += _check_b("offsets: no error", d.has_error(), false)
	f += _check_i("offsets: row count", rows.size(), 2)
	if rows.size() == 2:
		f += _check_i("offsets: row0.a", rows[0].a, 10)
		f += _check_i("offsets: row1.b", rows[1].b, 40)
	f += _check_i("offsets: spb at block end (sentinel)", d.read_u32_le(spb), SENTINEL)
	return f


# Slice path returns byte-exact rows.
func _test_slice_path_bytes() -> int:
	var d: BSATNDeserializer = _new_deser()
	var spb: StreamPeerBuffer = _build_fixed([[1, 2], [3, 4]])
	var raw: Array[PackedByteArray] = d.read_bsatn_row_list(spb)
	var f: int = 0
	f += _check_b("slice: no error", d.has_error(), false)
	f += _check_i("slice: row count", raw.size(), 2)
	if raw.size() == 2:
		# row0 = u32(1) u32(2) little-endian = 01 00 00 00 02 00 00 00
		var want0: PackedByteArray = PackedByteArray([1, 0, 0, 0, 2, 0, 0, 0])
		f += _check_b("slice: row0 bytes", raw[0] == want0, true)
		f += _check_i("slice: row1 size", raw[1].size(), 8)
	f += _check_i("slice: spb at block end (sentinel)", d.read_u32_le(spb), SENTINEL)
	return f


func _test_zero_rows() -> int:
	var d: BSATNDeserializer = _new_deser()
	var spb: StreamPeerBuffer = _build_fixed([])
	var rows: Array[Resource] = _parse_resources(d, spb)
	var f: int = 0
	f += _check_b("zero: no error", d.has_error(), false)
	f += _check_i("zero: row count", rows.size(), 0)
	f += _check_i("zero: spb at block end (sentinel)", d.read_u32_le(spb), SENTINEL)
	return f


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

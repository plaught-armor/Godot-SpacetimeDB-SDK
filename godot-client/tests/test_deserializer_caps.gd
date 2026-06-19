# Regression test for the row-list header bounds caps in BSATNDeserializer.
#
# A malformed/hostile row-list header carries attacker-influenced u32 counts and a
# u32 data_len. Without caps, `offsets.resize(count + 1)` allocates gigabytes before
# any read (OOM), and a data_len past the buffer makes the row reader seek past EOF
# and silently drop every following message. The caps turn both into clean errors:
# oversize counts -> ERROR, a block longer than the buffer -> NEEDS_MORE.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_deserializer_caps.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const RowType: GDScript = preload("res://tests/_test_pk_row.gd")

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_fixed_size_count_cap()
	fails += _test_row_offsets_count_cap()
	fails += _test_block_end_past_buffer()
	fails += _test_valid_header_ok()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# FixedSize: u8 tag(0), u16 row_size, u32 data_len. num_rows = data_len/row_size.
func _test_fixed_size_count_cap() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(0)
	spb.put_u16(1) # row_size = 1
	spb.put_u32(BSATNDeserializer.MAX_VEC_LEN + 1) # data_len -> num_rows over cap
	spb.seek(0)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	d._read_row_block_header(spb)
	return _check_b("FixedSize oversize count -> error", d.has_error(), true)


# RowOffsets: u8 tag(1), u32 num_offsets, ... num_offsets is the OOM lever.
func _test_row_offsets_count_cap() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(1)
	spb.put_u32(BSATNDeserializer.MAX_VEC_LEN + 1) # num_offsets over cap
	spb.seek(0)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	d._read_row_block_header(spb)
	return _check_b("RowOffsets oversize count -> error", d.has_error(), true)


# Valid header but data_len claims more bytes than the buffer holds -> NEEDS_MORE.
func _test_block_end_past_buffer() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(1) # RowOffsets
	spb.put_u32(1) # num_offsets = 1
	spb.put_u64(0) # offset[0] = 0
	spb.put_u32(1000) # data_len = 1000, but no row data follows
	spb.seek(0)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	d._read_bsatn_row_list_as_resources(spb, RowType, "tbl")
	var f: int = 0
	f += _check_b("block past buffer -> has_error", d.has_error(), true)
	f += _check_b(
		"block past buffer -> NEEDS_MORE",
		d._status == BSATNDeserializer.ParseStatus.NEEDS_MORE,
		true,
	)
	return f


# A well-formed small FixedSize header parses cleanly — caps don't false-trip.
func _test_valid_header_ok() -> int:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.put_u8(0)
	spb.put_u16(4) # row_size = 4
	spb.put_u32(8) # data_len = 8 -> num_rows = 2
	spb.seek(0)
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var header: Dictionary = d._read_row_block_header(spb)
	var f: int = 0
	f += _check_b("valid header no error", d.has_error(), false)
	f += _check_i("valid header count", header.get("count", -1), 2)
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

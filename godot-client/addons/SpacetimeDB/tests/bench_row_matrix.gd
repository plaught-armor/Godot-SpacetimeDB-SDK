# Controlled 2-axis bench: encoding (FIXED_SIZE vs ROW_OFFSETS) x row size, OLD
# slice-path vs IN-PLACE parse. The first abandonment tested only FIXED_SIZE
# small rows (in-place was slower there); this checks whether the verdict flips
# for ROW_OFFSETS and/or larger rows. Identical harness for every cell.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/bench_row_matrix.gd
extends SceneTree

const SMALL_PATH: String = "res://addons/SpacetimeDB/tests/_test_row_type.gd"
const WIDE_PATH: String = "res://addons/SpacetimeDB/tests/_test_row_wide.gd"
const N: int = 100000
const REPS: int = 3

var _small: GDScript = load(SMALL_PATH)
var _wide: GDScript = load(WIDE_PATH)
var _sink: int = 0


func _initialize() -> void:
	print("cell                              | OLD ms | IN-PLACE ms | speedup")
	# FIXED_SIZE, small fixed rows (the only case tested before).
	_cell("FIXED  small 8B (2xu32)", _build_small_fixed(N), false)
	# ROW_OFFSETS, same 8B rows — isolates encoding effect.
	_cell("OFFSET small 8B (2xu32)", _build_small_offsets(N), true)
	# ROW_OFFSETS, wide rows with growing string payload.
	_cell("OFFSET wide str=8", _build_wide(N, 8), true, _wide)
	_cell("OFFSET wide str=64", _build_wide(N, 64), true, _wide)
	_cell("OFFSET wide str=256", _build_wide(N, 256), true, _wide)
	quit(0)


func _cell(label: String, bytes: PackedByteArray, is_offsets: bool, script: GDScript = _small) -> void:
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	# Warm.
	_old(d, bytes, script)
	_inplace(d, bytes, is_offsets, script)

	var old_us: int = _best(func() -> void: _old(d, bytes, script))
	var new_us: int = _best(func() -> void: _inplace(d, bytes, is_offsets, script))
	var speedup: float = float(old_us) / float(new_us) if new_us > 0 else 0.0
	print("%-33s | %6.1f | %11.1f | %.2fx" % [label, old_us / 1000.0, new_us / 1000.0, speedup])


func _best(thunk: Callable) -> int:
	var best: int = 1 << 62
	for _r: int in REPS:
		var t0: int = Time.get_ticks_usec()
		thunk.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best:
			best = dt
	return best


# OLD: read_bsatn_row_list (slice each row) + per-row buffer assign.
func _old(d: BSATNDeserializer, bytes: PackedByteArray, script: GDScript) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	var raw: Array[PackedByteArray] = d.read_bsatn_row_list(spb)
	var row_spb: StreamPeerBuffer = StreamPeerBuffer.new()
	for rb: PackedByteArray in raw:
		var res: Variant = script.new()
		row_spb.data_array = rb
		row_spb.seek(0)
		d._populate_resource_from_bytes(res, row_spb)
		_sink += 1


# IN-PLACE: read header once, parse each row straight from the message buffer.
func _inplace(d: BSATNDeserializer, bytes: PackedByteArray, is_offsets: bool, script: GDScript) -> void:
	var spb: StreamPeerBuffer = _reader(bytes)
	var size_hint: int = d.read_u8(spb)
	var offsets: PackedInt64Array = PackedInt64Array()
	var count: int = 0
	var data_len: int = 0
	if is_offsets:
		count = d.read_u32_le(spb)
		offsets.resize(count + 1)
		for i: int in range(count):
			offsets[i] = d.read_u64_le(spb)
		data_len = d.read_u32_le(spb)
		offsets[count] = data_len
	else:
		var row_size: int = d.read_u16_le(spb)
		data_len = d.read_u32_le(spb)
		count = data_len / row_size if row_size > 0 else 0
		offsets.resize(count + 1)
		for i: int in range(count + 1):
			offsets[i] = i * row_size
	var block_start: int = spb.get_position()
	for i: int in range(count):
		spb.seek(block_start + offsets[i])
		var res: Variant = script.new()
		d._populate_resource_from_bytes(res, spb)
		_sink += 1
	spb.seek(block_start + data_len)


func _reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var r: StreamPeerBuffer = StreamPeerBuffer.new()
	r.data_array = bytes
	r.seek(0)
	return r


func _build_small_fixed(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u8(0)
	w.put_u16(8)
	w.put_u32(n * 8)
	for i: int in range(n):
		w.put_u32(i)
		w.put_u32(i)
	return w.data_array


func _build_small_offsets(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u8(1)
	w.put_u32(n)
	for i: int in range(n):
		w.put_u64(i * 8)
	w.put_u32(n * 8)
	for i: int in range(n):
		w.put_u32(i)
		w.put_u32(i)
	return w.data_array


func _build_wide(n: int, str_len: int) -> PackedByteArray:
	var row_size: int = 12 + 4 + str_len + 4
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u8(1)
	w.put_u32(n)
	for i: int in range(n):
		w.put_u64(i * row_size)
	w.put_u32(n * row_size)
	var filler: PackedByteArray = PackedByteArray()
	filler.resize(str_len)
	filler.fill(65)
	for i: int in range(n):
		w.put_u32(i)
		w.put_u32(i)
		w.put_u32(i)
		w.put_u32(str_len)
		w.put_data(filler)
		w.put_u32(i)
	return w.data_array

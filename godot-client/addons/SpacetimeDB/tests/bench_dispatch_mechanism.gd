# Fair comparison of per-field dispatch CONSTRUCTS for the parse hot loop. Every
# variant does identical surrounding work (status check + dynamic set-by-StringName);
# ONLY the dispatch differs. Row = _test_row_type (a,b : u32). Answers: is there a
# non-Callable dispatch that beats it, and how do match / if-elif / "jump table"
# (Array[Callable] index) actually compare in interpreted GDScript.
#
#   1 CALLABLE_ARR   v = readers[j].call(spb)        — O(1) index + Callable.call (current shape)
#   2 MATCH1         match code -> read_u32_le(spb)  — 1-arm match + direct call
#   3 IFELIF1        if code==U32 -> read_u32_le     — 1-branch + direct call
#   4 MATCH_INLINE   match code -> inline get_u32    — no Callable, no reader call
#   5 IFELIF_INLINE  if code==U32 -> inline get_u32
#   6 MATCH6_LAST    6-arm match, hit last           — match linearity (worst)
#   7 IFELIF6_LAST   6-branch if/elif, hit last      — if/elif linearity (worst)
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/bench_dispatch_mechanism.gd
extends SceneTree

const ROW_PATH: String = "res://addons/SpacetimeDB/tests/_test_row_type.gd"
const N: int = 600000
const REPS: int = 7

enum Code { U8, U16, U32, U64, I32, F32 }

var _row: GDScript = load(ROW_PATH)
var _d: BSATNDeserializer = BSATNDeserializer.new(null, false)
var _names: Array[StringName] = [&"a", &"b"]
var _codes: Array[int] = [Code.U32, Code.U32]
var _readers: Array[Callable] = []
var _sink: int = 0


func _initialize() -> void:
	var bytes: PackedByteArray = _build(N)
	_readers = [_d.read_u32_le, _d.read_u32_le]

	var r1: int = _best(func() -> void: _callable_arr(bytes))
	var r2: int = _best(func() -> void: _match1(bytes))
	var r3: int = _best(func() -> void: _ifelif1(bytes))
	var r4: int = _best(func() -> void: _match_inline(bytes))
	var r5: int = _best(func() -> void: _ifelif_inline(bytes))
	var r6: int = _best(func() -> void: _match6_last(bytes))
	var r7: int = _best(func() -> void: _ifelif6_last(bytes))

	print("rows=%d  (identical status-check + dynamic set; only dispatch differs)" % N)
	_line("1 CALLABLE_ARR (current)", r1, r1)
	_line("2 MATCH1 + direct call  ", r2, r1)
	_line("3 IFELIF1 + direct call ", r3, r1)
	_line("4 MATCH + inline read   ", r4, r1)
	_line("5 IFELIF + inline read  ", r5, r1)
	_line("6 MATCH6 hit last       ", r6, r1)
	_line("7 IFELIF6 hit last      ", r7, r1)
	print(
		"vs CALLABLE_ARR: match1=%.2fx ifelif1=%.2fx match_inl=%.2fx ifelif_inl=%.2fx match6last=%.2fx ifelif6last=%.2fx" % [
			float(r1) / r2,
			float(r1) / r3,
			float(r1) / r4,
			float(r1) / r5,
			float(r1) / r6,
			float(r1) / r7,
		],
	)
	print("(sink=%d)" % _sink)
	quit(0)


func _line(label: String, us: int, base: int) -> void:
	print("%s : %6.1f ms  %6.3f us/row  %5.1f%%" % [label, us / 1000.0, float(us) / N, 100.0 * us / base])


func _best(thunk: Callable) -> int:
	var best: int = 1 << 62
	for _r: int in REPS:
		var t0: int = Time.get_ticks_usec()
		thunk.call()
		var dt: int = Time.get_ticks_usec() - t0
		if dt < best:
			best = dt
	return best


# 1: Array[Callable] indexed by field — O(1) index, then Callable.call. The closest
# GDScript has to a "jump table"; it's the shape the shipped plan already uses.
func _callable_arr(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = _readers[j].call(spb)
			if _d._status != BSATNDeserializer.ParseStatus.OK:
				break
			r.set(_names[j], v)
		_sink += r.a


func _match1(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = 0
			match _codes[j]:
				Code.U32:
					v = _d.read_u32_le(spb)
			if _d._status != BSATNDeserializer.ParseStatus.OK:
				break
			r.set(_names[j], v)
		_sink += r.a


func _ifelif1(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = 0
			var c: int = _codes[j]
			if c == Code.U32:
				v = _d.read_u32_le(spb)
			if _d._status != BSATNDeserializer.ParseStatus.OK:
				break
			r.set(_names[j], v)
		_sink += r.a


func _match_inline(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var size: int = spb.get_size()
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = 0
			match _codes[j]:
				Code.U32:
					if spb.get_position() + 4 <= size:
						v = spb.get_u32()
			r.set(_names[j], v)
		_sink += r.a


func _ifelif_inline(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var size: int = spb.get_size()
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = 0
			var c: int = _codes[j]
			if c == Code.U32:
				if spb.get_position() + 4 <= size:
					v = spb.get_u32()
			r.set(_names[j], v)
		_sink += r.a


# 6 & 7: worst-case linearity — the field's type is the LAST arm/branch of 6.
func _match6_last(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var size: int = spb.get_size()
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = 0
			match _codes[j]:
				Code.U8:
					v = spb.get_u8()
				Code.U16:
					v = spb.get_u16()
				Code.U64:
					v = spb.get_u64()
				Code.I32:
					v = spb.get_32()
				Code.F32:
					v = int(spb.get_float())
				Code.U32:
					if spb.get_position() + 4 <= size:
						v = spb.get_u32()
			r.set(_names[j], v)
		_sink += r.a


func _ifelif6_last(bytes: PackedByteArray) -> void:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	var size: int = spb.get_size()
	for _i: int in range(N):
		var r: Object = _row.new()
		for j: int in range(2):
			var v: int = 0
			var c: int = _codes[j]
			if c == Code.U8:
				v = spb.get_u8()
			elif c == Code.U16:
				v = spb.get_u16()
			elif c == Code.U64:
				v = spb.get_u64()
			elif c == Code.I32:
				v = spb.get_32()
			elif c == Code.F32:
				v = int(spb.get_float())
			elif c == Code.U32:
				if spb.get_position() + 4 <= size:
					v = spb.get_u32()
			r.set(_names[j], v)
		_sink += r.a


func _build(n: int) -> PackedByteArray:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	for i: int in range(n):
		w.put_u32(i)
		w.put_u32(i)
	return w.data_array

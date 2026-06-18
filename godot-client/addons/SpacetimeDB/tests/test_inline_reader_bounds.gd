# Regression for the inlined fixed-width primitive readers. Each read_*_le now does
# its own bounds check (was a shared _check_read call); this locks the per-reader
# byte count: an exact-size buffer reads cleanly, one byte short sets NEEDS_MORE and
# returns the zero default. A wrong inlined count would slip through here.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_inline_reader_bounds.gd
#
# Exit code = number of failed checks (0 = all pass).
extends SceneTree

var _total: int = 0
var _needs_more: BSATNDeserializer.ParseStatus = BSATNDeserializer.ParseStatus.NEEDS_MORE


func _initialize() -> void:
	var fails: int = 0
	fails += _test_boundaries()
	fails += _test_values()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _deser() -> BSATNDeserializer:
	return BSATNDeserializer.new(null, false)


func _reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var r: StreamPeerBuffer = StreamPeerBuffer.new()
	r.data_array = bytes
	r.seek(0)
	return r


# Per reader: exact n bytes reads with no error; n-1 bytes sets NEEDS_MORE.
func _boundary(label: String, method: StringName, n: int) -> int:
	var f: int = 0
	var d: BSATNDeserializer = _deser()
	var call: Callable = Callable(d, method)

	var exact: PackedByteArray = PackedByteArray()
	exact.resize(n)
	call.call(_reader(exact))
	f += _check_b("%s exact %dB: no error" % [label, n], d.has_error(), false)

	d.clear_error()
	var short: PackedByteArray = PackedByteArray()
	short.resize(n - 1)
	call.call(_reader(short))
	f += _check_s("%s short %dB: NEEDS_MORE" % [label, n - 1], d._status, _needs_more)
	return f


func _test_boundaries() -> int:
	var f: int = 0
	f += _boundary("read_i8", &"read_i8", 1)
	f += _boundary("read_i16_le", &"read_i16_le", 2)
	f += _boundary("read_i32_le", &"read_i32_le", 4)
	f += _boundary("read_i64_le", &"read_i64_le", 8)
	f += _boundary("read_u8", &"read_u8", 1)
	f += _boundary("read_u16_le", &"read_u16_le", 2)
	f += _boundary("read_u32_le", &"read_u32_le", 4)
	f += _boundary("read_u64_le", &"read_u64_le", 8)
	f += _boundary("read_f32_le", &"read_f32_le", 4)
	f += _boundary("read_f64_le", &"read_f64_le", 8)
	return f


# Spot-check values still decode correctly after the inline (get_* untouched, but
# guard against a wrong put/get pairing): signed negative, large unsigned, fractional.
func _test_values() -> int:
	var f: int = 0

	var wi: StreamPeerBuffer = StreamPeerBuffer.new()
	wi.put_32(-12345)
	var di: BSATNDeserializer = _deser()
	f += _check_i("i32 negative round-trip", di.read_i32_le(_reader(wi.data_array)), -12345)

	var wu: StreamPeerBuffer = StreamPeerBuffer.new()
	wu.put_u32(4000000000)
	var du: BSATNDeserializer = _deser()
	f += _check_i("u32 large round-trip", du.read_u32_le(_reader(wu.data_array)), 4000000000)

	var wf: StreamPeerBuffer = StreamPeerBuffer.new()
	wf.put_float(1.5)
	var df: BSATNDeserializer = _deser()
	f += _check_b("f32 fractional round-trip", is_equal_approx(df.read_f32_le(_reader(wf.data_array)), 1.5), true)
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


func _check_s(label: String, got: BSATNDeserializer.ParseStatus, want: BSATNDeserializer.ParseStatus) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

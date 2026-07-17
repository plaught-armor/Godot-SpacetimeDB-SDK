# Regression: read_string_with_u32_len must NOT raise a fatal parse error on a
# string field whose UTF-8 bytes contain a leading or embedded NUL (U+0000).
# Godot's String is NUL-terminated, so get_string_from_utf8() truncates at the
# NUL — a representation limit, not a wire malformation. The old code treated the
# resulting empty/short decode as "malformed UTF-8" and set a fatal error, which
# the framing loop turns into an ENTIRE-packet drop (every batched message lost)
# over one NUL-containing string. This test pins: no error is raised, so the
# frame is not torn down.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_string_decode.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	# Normal ASCII string round-trips intact.
	fails += _case("plain", _u32le(5) + "hello".to_utf8_buffer(), "hello", false)
	# Empty string (len 0) — no bytes read, no error.
	fails += _case("empty", _u32le(0), "", false)
	# Leading NUL: len 1, single 0x00 byte. Valid on the wire; Godot truncates to
	# "". Must NOT error (the packet-drop regression).
	fails += _case("leading_nul", _u32le(1) + PackedByteArray([0x00]), "", false)
	# Embedded NUL "A\0B": len 3. Godot truncates to "A"; must NOT error.
	fails += _case("embedded_nul", _u32le(3) + PackedByteArray([0x41, 0x00, 0x42]), "A", false)

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _u32le(n: int) -> PackedByteArray:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(n)
	return spb.data_array


func _case(label: String, bytes: PackedByteArray, want: String, want_error: bool) -> int:
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	var got: String = d.read_string_with_u32_len(spb)

	var f: int = 0
	f += _check_b("%s: no fatal error" % label, d.has_error(), want_error)
	f += _check_s("%s: value" % label, got, want)
	return f


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print('PASS  %s = "%s"' % [label, got])
		return 0
	printerr('FAIL  %s: got "%s" want "%s"' % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

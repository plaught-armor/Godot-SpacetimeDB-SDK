# Regression test for write_u64_le on u64 values with the high bit set.
#
# GDScript int is i64, so a u64 >= 2^63 is carried as a negative i64 (it comes off
# the wire that way via get_u64). write_u64_le used to reject v < 0 and emit a zero,
# making large hashes / ids / u64 columns un-serializable. This checks the full u64
# range round-trips byte-identical.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_u64_roundtrip.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	# 0, 1, i64 max, then the two high-bit patterns: i64 min = u64 2^63, -1 = u64 2^64-1.
	for v: int in [0, 1, 9223372036854775807, -9223372036854775808, -1]:
		fails += _check_roundtrip(v)
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check_roundtrip(v: int) -> int:
	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	ser.write_u64_le(v)
	var f: int = 0
	f += _check_b("write_u64_le(%d) no error" % v, not ser.has_error(), true)
	f += _check_i("write_u64_le(%d) wrote 8 bytes" % v, ser._spb.get_position(), 8)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = ser._spb.data_array.slice(0, ser._spb.get_position())
	spb.seek(0)
	f += _check_i("u64 round-trip %d" % v, spb.get_u64(), v)
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

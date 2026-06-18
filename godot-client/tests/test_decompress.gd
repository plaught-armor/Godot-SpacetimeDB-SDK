# Correctness test for DataDecompressor.decompress_packet — round-trips payloads
# of several sizes through gzip and checks byte-exact recovery, plus the
# empty-input and garbage-input edges. Guards the chunk-size tune.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_decompress.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	# Round-trip across sizes that span the chunk boundary (65536).
	for size: int in [0, 1, 100, 65535, 65536, 65537, 262144, 1048576]:
		fails += _test_roundtrip(size)
	fails += _test_empty_input()
	fails += _test_garbage_input()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _make_payload(n: int) -> PackedByteArray:
	var p: PackedByteArray = PackedByteArray()
	p.resize(n)
	for i: int in n:
		p[i] = (i * 31 + (i >> 5)) & 0xFF
	return p


func _gzip(data: PackedByteArray) -> PackedByteArray:
	var s: StreamPeerGZIP = StreamPeerGZIP.new()
	s.start_compression()
	if not data.is_empty():
		s.put_data(data)
	s.finish()
	var out: PackedByteArray = PackedByteArray()
	while true:
		var r: Array = s.get_partial_data(65536)
		if r[0] != OK or (r[1] as PackedByteArray).is_empty():
			break
		out.append_array(r[1])
	return out


func _test_roundtrip(size: int) -> int:
	var payload: PackedByteArray = _make_payload(size)
	var compressed: PackedByteArray = _gzip(payload)
	var got: PackedByteArray = DataDecompressor.decompress_packet(compressed)
	return _check_b("roundtrip size=%d" % size, got == payload, true)


# Empty compressed input → empty output (guard clause).
func _test_empty_input() -> int:
	var got: PackedByteArray = DataDecompressor.decompress_packet(PackedByteArray())
	return _check_b("empty input → empty", got.is_empty(), true)


# Non-gzip garbage → empty output (error path, no crash).
func _test_garbage_input() -> int:
	var garbage: PackedByteArray = PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	var got: PackedByteArray = DataDecompressor.decompress_packet(garbage)
	return _check_b("garbage input → empty", got.is_empty(), true)


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

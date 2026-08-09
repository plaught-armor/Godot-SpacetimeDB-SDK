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
	# Round-trip across sizes that span the chunk boundary (65536). No 0: the one-shot
	# compressor answers empty input with zero bytes rather than an empty member, so
	# that case would only re-test decompress_packet's is_empty() guard, which
	# _test_empty_input already covers. An empty gzip MEMBER is therefore uncovered —
	# it cannot reach the decompressor anyway, the client drops sub-2-byte frames.
	for size: int in [1, 100, 65535, 65536, 65537, 262144, 1048576]:
		fails += _test_roundtrip(size)
	fails += _test_empty_input()
	fails += _test_garbage_input()
	fails += _test_truncated_member()
	fails += _test_leftover_input()

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


# One shot rather than a StreamPeerGZIP drain loop. The streaming form this replaces
# discarded put_data's Error and drained without pumping the stream, so it produced a
# TEN-BYTE stub — a header and nothing else — for any input that did not compress well:
# measured 10 bytes for 4096 random bytes, 65535 for 1 MiB of them. Every payload the
# tests happened to use is highly compressible, so it worked by luck of the corpus, and
# every assertion here that reads `.is_empty()` would have passed on a stub fixture for
# the wrong reason.
func _gzip(data: PackedByteArray) -> PackedByteArray:
	return data.compress(FileAccess.COMPRESSION_GZIP)


func _test_roundtrip(size: int) -> int:
	var payload: PackedByteArray = _make_payload(size)
	var compressed: PackedByteArray = _gzip(payload)
	var got: PackedByteArray = DataDecompressor.decompress_packet(compressed)
	return _check_b("roundtrip size=%d" % size, got == payload, true)


# Empty compressed input → empty output (guard clause).
func _test_empty_input() -> int:
	var got: PackedByteArray = DataDecompressor.decompress_packet(PackedByteArray())
	return _check_b("empty input → empty", got.is_empty(), true)


# A member cut short → empty output, NOT the prefix that inflated before the cut.
#
# StreamPeerGZIP reports nothing for a truncated member: it consumes every byte it was
# given and hands back what it managed to inflate, so this was the one supported path by
# which half a message could reach the BSATN reader looking whole. Measured on the old
# code, which returned the prefix with a push_warning: a 4000-byte payload gzipped to
# 321 bytes and cut to 160 came back as 142 bytes — enough to parse as a short packet
# and, before the framing fix, to wedge the receive path for the rest of the session.
func _test_truncated_member() -> int:
	var f: int = 0
	var payload: PackedByteArray = _make_payload(4000)
	var compressed: PackedByteArray = _gzip(payload)
	var cut: PackedByteArray = compressed.slice(0, compressed.size() / 2)
	var got: PackedByteArray = DataDecompressor.decompress_packet(cut)
	f += _check_b("truncated member → empty", got.is_empty(), true)
	# The whole member still round-trips, i.e. the trailer check refuses nothing valid.
	f += _check_b(
		"the intact member is unaffected",
		DataDecompressor.decompress_packet(compressed) == payload,
		true,
	)
	# The controls that matter now that a drain-heuristic miss DROPS a frame instead of
	# warning about it: the ratio a real snapshot reaches (row data compresses hard) and
	# a size that needs many chunk passes. A false refusal here would be silent data
	# loss on ordinary traffic.
	var sparse: PackedByteArray = []
	sparse.resize(8 * 1024 * 1024)
	f += _check_b(
		"a high-ratio 8 MiB payload still round-trips",
		DataDecompressor.decompress_packet(_gzip(sparse)) == sparse,
		true,
	)
	# The other axis, and the one the leftover-input refusal actually keys off: an
	# INCOMPRESSIBLE payload takes several input chunks, so `last_slice_position` has to
	# reach the end across many passes. Every other case here compresses to under 8 KiB
	# and feeds the decoder in one.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 0x5CA1AB1E
	var noisy: PackedByteArray = []
	noisy.resize(200000)
	for i: int in noisy.size():
		noisy[i] = rng.randi_range(0, 255)
	f += _check_b(
		"an incompressible payload round-trips across input chunks",
		DataDecompressor.decompress_packet(_gzip(noisy)) == noisy,
		true,
	)
	return f


# Everything after the first member's trailer is input the decoder never consumed, so
# what inflated is a prefix of what the sender meant. Measured before this was refused:
# a two-member stream (100 + 50 bytes) came back as 100 bytes reported as success, and
# a member with trailing garbage delivered its payload with only a push_warning.
func _test_leftover_input() -> int:
	var f: int = 0
	var head: PackedByteArray = _make_payload(100)
	var tail: PackedByteArray = _make_payload(50)
	# Positive control first: everything below asserts `.is_empty()`, and a fixture
	# generator that produced junk would satisfy that for the wrong reason.
	f += _check_b(
		"control: the first member alone round-trips",
		DataDecompressor.decompress_packet(_gzip(head)) == head,
		true,
	)
	var two_members: PackedByteArray = _gzip(head)
	two_members.append_array(_gzip(tail))
	f += _check_b(
		"multi-member stream → empty, not member one alone",
		DataDecompressor.decompress_packet(two_members).is_empty(),
		true,
	)

	var with_garbage: PackedByteArray = _gzip(head)
	var garbage: PackedByteArray = [0xDE, 0xAD, 0xBE, 0xEF]
	with_garbage.append_array(garbage)
	f += _check_b(
		"trailing garbage → empty",
		DataDecompressor.decompress_packet(with_garbage).is_empty(),
		true,
	)
	return f


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

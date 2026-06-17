# Test for DataDecompressor.decompress_brotli using Godot's built-in Brotli
# decoder. Decodes a fixed raw-Brotli fixture (produced by the `brotli` CLI) and
# asserts the recovered bytes match the original text. Guards that Godot 4.x
# exposes Brotli decode via PackedByteArray.decompress_dynamic + that the SDK
# wires it correctly.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_brotli_decompress.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0

# `brotli -c` of the EXPECTED string below, hex-encoded.
const FIXTURE_HEX: String = "a120020026ba314c75a1fa62118b2028a705196497a224a7b21253c3e1db5f794e76bf392016351c00"
const EXPECTED: String = "spacetimedb brotli roundtrip 12345 spacetimedb brotli roundtrip 12345"


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0

	var blob: PackedByteArray = _hex_to_bytes(FIXTURE_HEX)
	var out: PackedByteArray = DataDecompressor.decompress_brotli(blob)
	f += _check_b("decode non-empty", not out.is_empty(), true)
	f += _check_s("decoded text matches", out.get_string_from_utf8(), EXPECTED)

	# Empty input → empty output, no crash.
	f += _check_b("empty input → empty", DataDecompressor.decompress_brotli(PackedByteArray()).is_empty(), true)

	return f


func _hex_to_bytes(hex: String) -> PackedByteArray:
	var bytes: PackedByteArray = []
	for i: int in range(0, hex.length(), 2):
		bytes.append(hex.substr(i, 2).hex_to_int())
	return bytes


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s\n  got:  %s\n  want: %s" % [label, got, want])
	return 1

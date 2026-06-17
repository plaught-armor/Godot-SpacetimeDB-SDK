# Test for SpacetimeDBClient._decode_reducer_error — the BSATN decode of a reducer
# `err` outcome payload. A reducer returning Err carries a BSATN-encoded value of its
# error type; the common Result<_, String> case is a u32-length-prefixed UTF-8 string.
# Regression guard for the live-found bug where the raw payload (length prefix + nulls)
# was fed to get_string_from_utf8 and produced an empty/garbled message.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_reducer_error_decode.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var fails: int = 0

	# BSATN(String "intentional failure"): u32 length prefix + UTF-8.
	var msg: String = "intentional failure"
	var utf8: PackedByteArray = msg.to_utf8_buffer()
	var bsatn_str: PackedByteArray = PackedByteArray()
	bsatn_str.resize(4)
	bsatn_str.encode_u32(0, utf8.size())
	bsatn_str.append_array(utf8)
	fails += _check("bsatn string decodes", client._decode_reducer_error(bsatn_str), msg)

	# Empty payload → empty message.
	fails += _check("empty → empty", client._decode_reducer_error(PackedByteArray()), "")

	# Non-length-prefixed plain UTF-8 (length mismatch) → raw fallback.
	var plain: PackedByteArray = "oops".to_utf8_buffer()
	fails += _check("plain utf8 fallback", client._decode_reducer_error(plain), "oops")

	client.free()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1

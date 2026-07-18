# A BSATN_TYPES entry spelled "U32" must decode as a u32.
#
# The serializer lowercases at its BSATN_TYPES read and the deserializer did not,
# so an uppercase entry serialized correctly and then missed every lowercase-keyed
# primitive reader — falling through to the Variant.Type default, which reads an
# int as i64. That silently consumed 8 bytes where 4 were written, corrupting the
# value and every field after it in the row.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_bsatn_type_case.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_PATH: String = "res://tests/_uppercase_bsatn_row.gd"

var _total: int = 0


func _initialize() -> void:
	var fails: int = _test_uppercase_decodes_as_u32()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _test_uppercase_decodes_as_u32() -> int:
	# u32 LE 0xDEADBEEF, then a single bool byte. Reading the u32 as i64 would
	# swallow the bool and 3 bytes past the end.
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.big_endian = false
	spb.put_u32(0xDEADBEEF)
	spb.put_u8(1)

	var deserializer: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var script: GDScript = load(ROW_PATH)
	var row: Resource = script.new()
	spb.seek(0)
	if not deserializer._populate_resource_from_bytes(row, spb):
		row = null

	var f: int = _check_b("row decoded", row != null, true)
	if row == null:
		printerr("      deserializer error: %s" % deserializer.get_last_error())
		return f + 2
	f += _check_i("u32 field value", row.small, 0xDEADBEEF)
	f += _check_b("following field intact", row.flag, true)
	return f


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

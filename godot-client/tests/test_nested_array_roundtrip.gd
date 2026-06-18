# Round-trip correctness test for nested typed arrays (Vec<Vec<i32>>). Guards the
# codegen fix that emits Array[Array] instead of an untyped Array for two-level
# nesting: BSATNDeserializer._read_array needs a typed element hint, and an
# untyped Array hits the "needs a typed hint" error path — so without the fix,
# nested-array deserialization fails outright.
#
# Serializes a row with a nested-array field, deserializes the bytes back, and
# checks the nested structure survives intact.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_nested_array_roundtrip.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_TYPE_PATH: String = "res://tests/_test_row_nested.gd"

var _total: int = 0
var _row_script: GDScript = load(ROW_TYPE_PATH)


func _initialize() -> void:
	var fails: int = 0
	fails += _test_roundtrip([[1, 2, 3], [4, 5]])
	fails += _test_roundtrip([])
	fails += _test_roundtrip([[], [7], []])
	fails += _test_roundtrip([[2147483647, -2147483648, 0]]) # i32 bounds

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _serialize(grid: Array) -> PackedByteArray:
	var src: Object = _row_script.new()
	# The field is typed Array[Array]; an untyped literal must be coerced via
	# assign() (same as BSATNDeserializer does when populating the field).
	var typed_grid: Array[Array] = []
	typed_grid.assign(grid)
	src.grid = typed_grid
	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	var ok: bool = ser._serialize_resource_fields(src)
	if not ok or ser.has_error():
		return PackedByteArray()
	return ser._spb.data_array.slice(0, ser._spb.get_position())


func _test_roundtrip(grid: Array) -> int:
	var bytes: PackedByteArray = _serialize(grid)
	var f: int = 0
	f += _check_b("serialize(%s) produced bytes" % [grid], not bytes.is_empty() or grid.is_empty(), true)

	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	var dst: Object = _row_script.new()
	var ok: bool = d._populate_resource_from_bytes(dst, spb)

	f += _check_b("roundtrip(%s) ok" % [grid], ok and not d.has_error(), true)
	f += _check_grid("roundtrip(%s) grid" % [grid], dst.grid, grid)
	return f


# Deep equality for an Array of Arrays of ints.
func _check_grid(label: String, got: Variant, want: Array) -> int:
	_total += 1
	if not (got is Array) or got.size() != want.size():
		printerr("FAIL  %s: shape mismatch got %s want %s" % [label, got, want])
		return 1
	for i: int in want.size():
		var got_row: Variant = got[i]
		var want_row: Array = want[i]
		if not (got_row is Array) or got_row.size() != want_row.size():
			printerr("FAIL  %s: row %d mismatch got %s want %s" % [label, i, got_row, want_row])
			return 1
		for j: int in want_row.size():
			if int(got_row[j]) != int(want_row[j]):
				printerr("FAIL  %s: [%d][%d] got %s want %s" % [label, i, j, got_row[j], want_row[j]])
				return 1
	print("PASS  %s = %s" % [label, got])
	return 0


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

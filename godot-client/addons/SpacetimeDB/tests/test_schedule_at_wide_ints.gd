# Round-trip tests for the BSATN ScheduleAt sum type and the wide integer types
# (i128 / u256 / i256). Writes each value with the serializer, reads it back with
# the deserializer, and checks the result matches.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_schedule_at_wide_ints.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_schedule_at(ScheduleAt.Kind.INTERVAL, 1234567)
	fails += _test_schedule_at(ScheduleAt.Kind.TIME, -42)
	fails += _test_wide_int(16, &"i128") # i128
	fails += _test_wide_int(32, &"u256") # u256
	fails += _test_wide_int(32, &"i256") # i256

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _buffer(bytes: PackedByteArray) -> StreamPeerBuffer:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	return spb


func _test_schedule_at(kind: ScheduleAt.Kind, micros: int) -> int:
	var src: ScheduleAt = ScheduleAt.new()
	src.kind = kind
	src.micros = micros

	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	ser.write_scheduled_at(src)
	var bytes: PackedByteArray = ser._spb.data_array.slice(0, ser._spb.get_position())

	var f: int = 0
	f += _check_i("schedule_at bytes = 9 (u8 tag + i64)", bytes.size(), 9)

	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = _buffer(bytes)
	var got: ScheduleAt = d.read_scheduled_at(spb)
	f += _check_b("schedule_at(%d) no error" % kind, not d.has_error(), true)
	f += _check_i("schedule_at(%d) kind" % kind, got.kind, kind)
	f += _check_i("schedule_at(%d) micros" % kind, got.micros, micros)
	return f


func _test_wide_int(size: int, bsatn_type: StringName) -> int:
	var src: PackedByteArray = PackedByteArray()
	src.resize(size)
	for i: int in range(size):
		src[i] = (i * 7 + 3) & 0xFF

	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	var writer: Callable = ser._get_primitive_writer_from_bsatn_type(bsatn_type)
	f_assert_valid(writer, bsatn_type)
	writer.call(src)
	var bytes: PackedByteArray = ser._spb.data_array.slice(0, ser._spb.get_position())

	var f: int = 0
	f += _check_i("%s bytes = %d" % [bsatn_type, size], bytes.size(), size)

	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = _buffer(bytes)
	var reader: Callable = d._get_primitive_reader_from_bsatn_type(bsatn_type)
	var got: PackedByteArray = reader.call(spb)
	f += _check_b("%s no error" % bsatn_type, not d.has_error(), true)
	f += _check_b("%s roundtrip equal" % bsatn_type, got == src, true)
	return f


func f_assert_valid(c: Callable, label: StringName) -> void:
	if not c.is_valid():
		printerr("FAIL  no writer/reader for %s" % label)


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

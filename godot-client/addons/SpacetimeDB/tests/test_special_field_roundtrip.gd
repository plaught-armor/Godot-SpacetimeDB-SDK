# Full-row round-trip for the special/wide BSATN field types (u128, i128, u256,
# i256, Uuid-as-u128, ScheduleAt) through the serializer's resource-field plan and
# the deserializer's row-populate path — i.e. the exact dispatch a codegen-generated
# row hits at runtime, not just the bare reader/writer functions.
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_special_field_roundtrip.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const ROW_TYPE_PATH: String = "res://addons/SpacetimeDB/tests/_test_row_special.gd"

var _total: int = 0
var _row_script: GDScript = load(ROW_TYPE_PATH)


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _bytes_of(size: int, seed_offset: int) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(size)
	for i: int in range(size):
		b[i] = (i * 7 + seed_offset) & 0xFF # asymmetric → detects a dropped reverse
	return b


func _run() -> int:
	var src: Object = _row_script.new()
	src.v_u128 = _bytes_of(16, 1)
	src.v_i128 = _bytes_of(16, 9)
	src.v_u256 = _bytes_of(32, 3)
	src.v_i256 = _bytes_of(32, 5)
	src.v_uuid = _bytes_of(16, 11)
	src.v_sched = ScheduleAt.at_time(987654321)

	var ser: BSATNSerializer = BSATNSerializer.new(false)
	ser._spb.seek(0)
	var ok: bool = ser._serialize_resource_fields(src)
	var f: int = 0
	f += _check_b("serialize ok", ok and not ser.has_error(), true)
	var bytes: PackedByteArray = ser._spb.data_array.slice(0, ser._spb.get_position())

	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = bytes
	spb.seek(0)
	var dst: Object = _row_script.new()
	var ok2: bool = d._populate_resource_from_bytes(dst, spb)
	f += _check_b("deserialize ok", ok2 and not d.has_error(), true)

	f += _check_b("u128 roundtrip", dst.v_u128 == src.v_u128, true)
	f += _check_b("i128 roundtrip", dst.v_i128 == src.v_i128, true)
	f += _check_b("u256 roundtrip", dst.v_u256 == src.v_u256, true)
	f += _check_b("i256 roundtrip", dst.v_i256 == src.v_i256, true)
	f += _check_b("uuid (u128) roundtrip", dst.v_uuid == src.v_uuid, true)
	f += _check_b("scheduled_at is ScheduleAt", dst.v_sched is ScheduleAt, true)
	f += _check_i("scheduled_at kind", dst.v_sched.kind, ScheduleAt.Kind.TIME)
	f += _check_i("scheduled_at micros", dst.v_sched.micros, 987654321)
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

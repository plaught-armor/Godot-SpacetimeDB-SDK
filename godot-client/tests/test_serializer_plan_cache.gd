# Guards the serializer's plan cache against caching a *failed* plan build.
#
# A serialization plan is legitimately empty for a schema with no storage
# fields, so the cache distinguishes "missing" from "cached empty" with has().
# Storing [] on a build failure therefore made the first serialization of an
# unsupported schema fail loudly and every later one write zero bytes and
# report success — a nested reducer-argument struct silently became an empty
# product on the wire.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_serializer_plan_cache.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const BAD_TYPE_PATH: String = "res://tests/_test_unserializable_row_type.gd"
const FIELDLESS_TYPE_PATH: String = "res://tests/_test_fieldless_row_type.gd"
const GOOD_TYPE_PATH: String = "res://tests/_test_row_type.gd"

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_failed_plan_fails_every_time()
	fails += _test_fieldless_schema_still_succeeds()
	fails += _test_good_schema_survives_a_poisoned_neighbour()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# The whole point: attempt two must fail exactly like attempt one.
func _test_failed_plan_fails_every_time() -> int:
	var script: GDScript = load(BAD_TYPE_PATH)
	var row: Object = script.new()
	row.a = 7
	var ser: BSATNSerializer = BSATNSerializer.new(false)

	var ok_first: bool = ser._serialize_resource_fields(row)
	var f: int = 0
	f += _check_b("first attempt reports failure", ok_first, false)
	f += _check_b("first attempt sets the error flag", ser.has_error(), true)

	# Mimic a caller that read the error and retried (or serialized another
	# message carrying the same nested type).
	ser.get_last_error()
	ser._spb.data_array = PackedByteArray()
	ser._spb.seek(0)

	var ok_second: bool = ser._serialize_resource_fields(row)
	f += _check_b("second attempt reports failure too", ok_second, false)
	f += _check_b("second attempt sets the error flag", ser.has_error(), true)
	f += _check_i("second attempt wrote no bytes", ser._spb.get_position(), 0)
	return f


# A schema with no storage fields has an empty plan by right — the fix must not
# turn that into a rebuild-and-fail on every call.
func _test_fieldless_schema_still_succeeds() -> int:
	var script: GDScript = load(FIELDLESS_TYPE_PATH)
	var row: Object = script.new()
	var ser: BSATNSerializer = BSATNSerializer.new(false)

	var f: int = 0
	f += _check_b("fieldless first attempt succeeds", ser._serialize_resource_fields(row), true)
	f += _check_b("fieldless second attempt succeeds", ser._serialize_resource_fields(row), true)
	f += _check_b("fieldless attempts set no error", ser.has_error(), false)
	f += _check_i("fieldless attempts wrote no bytes", ser._spb.get_position(), 0)
	return f


# One unsupported schema must not disturb a supported one on the same serializer.
func _test_good_schema_survives_a_poisoned_neighbour() -> int:
	var bad_script: GDScript = load(BAD_TYPE_PATH)
	var good_script: GDScript = load(GOOD_TYPE_PATH)
	var ser: BSATNSerializer = BSATNSerializer.new(false)

	ser._serialize_resource_fields(bad_script.new())
	ser.get_last_error()
	ser._spb.data_array = PackedByteArray()
	ser._spb.seek(0)

	var good: Object = good_script.new()
	good.a = 1
	good.b = 2
	var f: int = 0
	f += _check_b("good schema still serializes", ser._serialize_resource_fields(good), true)
	f += _check_i("good schema wrote both u32 fields", ser._spb.get_position(), 8)
	return f


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %s, want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		return 0
	printerr("FAIL %s: got %d, want %d" % [label, got, want])
	return 1

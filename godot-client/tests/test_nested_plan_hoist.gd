# Regression test for the nested-plan hoist (BSATNDeserializer._read_nested_hoisted).
# Uses a REAL schema so the hoist branch actually engages — earlier nested tests
# build BSATNDeserializer.new(null, ...), which makes _hoistable_nested_script bail
# and silently masks hoist bugs.
#
# Locks two invariants:
#   A) Genuine nested product Resource (BlackholioEntity.position : BlackholioDbVector2)
#      IS hoisted and parses correctly.
#   B) A schema type with a CUSTOM reader (ScheduleAt: sum u8-tag + i64 via
#      read_scheduled_at) is NOT hoisted — hoisting it would parse the 9-byte sum as a
#      product and desync the buffer, corrupting trailing fields. Verified by value AND
#      by white-box inspection of the plan step's nested_script.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_nested_plan_hoist.gd
#
# Exit code = number of failed checks (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_nested_product_is_hoisted()
	fails += _test_schedule_at_not_hoisted()
	fails += _test_plan_step_flags()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _deser() -> BSATNDeserializer:
	return BSATNDeserializer.new(SpacetimeDBSchema.new("blackholio"), false)


func _reader(w: StreamPeerBuffer) -> StreamPeerBuffer:
	var r: StreamPeerBuffer = StreamPeerBuffer.new()
	r.data_array = w.data_array
	r.seek(0)
	return r


# A) BlackholioEntity: entity_id i32, position BlackholioDbVector2{x,y f32}, mass i32.
func _test_nested_product_is_hoisted() -> int:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_32(5)
	w.put_float(1.5)
	w.put_float(-2.5)
	w.put_32(99)

	var d: BSATNDeserializer = _deser()
	var e: BlackholioEntity = BlackholioEntity.new()
	d._populate_resource_from_bytes(e, _reader(w))

	var f: int = 0
	f += _check_b("entity: no error", d.has_error(), false)
	f += _check_i("entity: entity_id", e.entity_id, 5)
	f += _check_b("entity: position non-null", e.position != null, true)
	if e.position != null:
		f += _check_b("entity: position.x", is_equal_approx(e.position.x, 1.5), true)
		f += _check_b("entity: position.y", is_equal_approx(e.position.y, -2.5), true)
	f += _check_i("entity: mass (no desync after nested)", e.mass, 99)
	return f


# B) BlackholioConsumeEntityTimer: scheduled_id u64, scheduled_at ScheduleAt
#    (u8 tag + i64), consumed_entity_id i32, consumer_entity_id i32.
#    The trailing i32s prove the buffer is not desynced by a mis-hoisted sum.
func _test_schedule_at_not_hoisted() -> int:
	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.put_u64(42)
	w.put_u8(ScheduleAt.Kind.TIME)
	w.put_64(1700000000000000)
	w.put_32(7)
	w.put_32(9)

	var d: BSATNDeserializer = _deser()
	var row: BlackholioConsumeEntityTimer = BlackholioConsumeEntityTimer.new()
	d._populate_resource_from_bytes(row, _reader(w))

	var f: int = 0
	f += _check_b("timer: no error", d.has_error(), false)
	f += _check_i("timer: scheduled_id", row.scheduled_id, 42)
	f += _check_b("timer: scheduled_at non-null", row.scheduled_at != null, true)
	if row.scheduled_at != null:
		f += _check_i("timer: scheduled_at.kind", row.scheduled_at.kind, ScheduleAt.Kind.TIME)
		f += _check_i("timer: scheduled_at.micros", row.scheduled_at.micros, 1700000000000000)
	f += _check_i("timer: consumed_entity_id (desync canary)", row.consumed_entity_id, 7)
	f += _check_i("timer: consumer_entity_id (desync canary)", row.consumer_entity_id, 9)
	return f


# White-box: the plan must hoist the nested product but never the custom-reader sum.
func _test_plan_step_flags() -> int:
	var d: BSATNDeserializer = _deser()
	var f: int = 0
	f += _check_b("plan: entity.position hoisted", _has_hoisted_field(d, BlackholioEntity, &"position"), true)
	f += _check_b("plan: timer.scheduled_at NOT hoisted", _has_hoisted_field(d, BlackholioConsumeEntityTimer, &"scheduled_at"), false)
	return f


func _has_hoisted_field(d: BSATNDeserializer, script: GDScript, field: StringName) -> bool:
	var plan: Array = d._get_or_build_plan(script)
	for step: Variant in plan:
		if step.prop_name == field:
			return step.nested_script != null
	return false


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

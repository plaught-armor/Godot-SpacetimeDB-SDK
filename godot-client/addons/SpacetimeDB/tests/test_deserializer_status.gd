# Standalone headless test for BSATNDeserializer's ParseStatus state machine
# (OK / ERROR / NEEDS_MORE) — the flag-cluster refactor that replaced the
# _has_error + _needs_more_data bools. No test framework — run directly:
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_deserializer_status.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

func _make_buffer(size: int) -> StreamPeerBuffer:
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(size)
	spb.data_array = bytes
	spb.seek(0)
	return spb


func _initialize() -> void:
	var fails: int = 0
	var OK: BSATNDeserializer.ParseStatus = BSATNDeserializer.ParseStatus.OK
	var ERROR: BSATNDeserializer.ParseStatus = BSATNDeserializer.ParseStatus.ERROR
	var NEEDS_MORE: BSATNDeserializer.ParseStatus = BSATNDeserializer.ParseStatus.NEEDS_MORE

	# Fresh deserializer starts clean.
	var d: BSATNDeserializer = BSATNDeserializer.new(null, false)
	fails += _check_b("fresh has_error false", d.has_error(), false)
	fails += _check_s("fresh status OK", d._status, OK)

	# Enough bytes available → read passes, stays OK.
	var spb: StreamPeerBuffer = _make_buffer(4)
	fails += _check_b("check_read within bounds true", d._check_read(spb, 2), true)
	fails += _check_s("within bounds stays OK", d._status, OK)

	# Past end of buffer → NEEDS_MORE (recoverable), has_error true.
	spb.seek(0)
	fails += _check_b("check_read past end false", d._check_read(spb, 5), false)
	fails += _check_s("past end → NEEDS_MORE", d._status, NEEDS_MORE)
	fails += _check_b("NEEDS_MORE counts as has_error", d.has_error(), true)

	# Keep-first guard: a plain _set_error must NOT downgrade NEEDS_MORE to ERROR.
	d._set_error("late malformed error")
	fails += _check_s("NEEDS_MORE preserved over later error", d._status, NEEDS_MORE)

	# clear_error resets to OK.
	d.clear_error()
	fails += _check_s("clear_error → OK", d._status, OK)
	fails += _check_b("clear_error → has_error false", d.has_error(), false)

	# Fresh malformed error → ERROR.
	d._set_error("malformed")
	fails += _check_s("set_error → ERROR", d._status, ERROR)
	fails += _check_b("ERROR has_error true", d.has_error(), true)

	# get_last_error returns the message and resets status to OK.
	var msg: String = d.get_last_error()
	fails += _check_b("get_last_error returns message", msg.contains("malformed"), true)
	fails += _check_s("get_last_error → OK", d._status, OK)

	# Keep-first guard again: second error does not overwrite the first message.
	d._set_error("first")
	d._set_error("second")
	fails += _check_b("keep-first error message", d.get_last_error().contains("first"), true)

	# Property-read wrap pattern: a NEEDS_MORE inner failure is captured before
	# get_last_error() resets status, then re-passed to _set_error — must stay
	# NEEDS_MORE so the framing loop keeps the incomplete tail (MEDIUM fix).
	d.clear_error()
	var spb2: StreamPeerBuffer = _make_buffer(2)
	d._check_read(spb2, 9)
	var captured: BSATNDeserializer.ParseStatus = d._status
	var _wrapped_cause: String = d.get_last_error()
	d._set_error("Failed reading property 'x'. Cause: ...", 0, captured)
	fails += _check_s("wrap preserves NEEDS_MORE", d._status, NEEDS_MORE)

	if fails == 0:
		print("ALL PASS (16/16)")
	else:
		printerr("%d FAIL" % fails)
	quit(fails)


func _check_b(label: String, got: bool, want: bool) -> int:
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_s(label: String, got: int, want: int) -> int:
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

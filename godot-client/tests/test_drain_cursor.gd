# Integration test for the cross-frame cursor drain in
# SpacetimeDBClient._process_results_asynchronously. Drives a real client node
# (no SceneTree attach, no threading) frame-by-frame and asserts the held batch
# advances via its cursor, is retained while partially drained, released when
# done, and that messages parsed mid-burst wait their turn (arrival order).
#
# Base SpacetimeDBServerMessage instances hit the "Unhandled message type" else
# branch in _handle_parsed_message (a no-op with debug_mode off), so the cursor
# sequence alone proves each message was visited once, in order.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_drain_cursor.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_empty_queue_noop()
	fails += _test_cursor_advances_and_releases()
	fails += _test_midburst_preserves_arrival_order()
	fails += _test_reconnect_drops_inflight_batch()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


# Ceiling-capped, time budget effectively infinite, no auto-tune → each frame
# drains exactly _max_msgs_per_frame, deterministically.
func _make_client(ceiling: int) -> SpacetimeDBClient:
	var c: SpacetimeDBClient = SpacetimeDBClient.new()
	c.use_threading = false
	c.debug_mode = false
	c._auto_tune_budget_enabled = false
	c._frame_budget_us = 1000000000
	c._max_msgs_per_frame = ceiling
	return c


func _fill(c: SpacetimeDBClient, n: int) -> void:
	for _i: int in n:
		c._result_queue.append(SpacetimeDBServerMessage.new())


# Empty queue → early return, no state change, no crash.
func _test_empty_queue_noop() -> int:
	var c: SpacetimeDBClient = _make_client(3)
	c._process_results_asynchronously()
	var f: int = 0
	f += _check_i("empty: cursor stays 0", c._drain_cursor, 0)
	f += _check_i("empty: batch stays 0", c._drain_batch.size(), 0)
	c.free()
	return f


# 10 messages, ceiling 3 → frames advance cursor 3,6,9,10 then release to 0.
func _test_cursor_advances_and_releases() -> int:
	var c: SpacetimeDBClient = _make_client(3)
	_fill(c, 10)
	var f: int = 0

	c._process_results_asynchronously() # frame 1: refill + drain 3
	f += _check_i("f1 cursor", c._drain_cursor, 3)
	f += _check_i("f1 batch held (10)", c._drain_batch.size(), 10)
	f += _check_i("f1 queue drained", c._result_queue.size(), 0)

	c._process_results_asynchronously() # frame 2: no refill, drain 3
	f += _check_i("f2 cursor", c._drain_cursor, 6)
	c._process_results_asynchronously() # frame 3: drain 3
	f += _check_i("f3 cursor", c._drain_cursor, 9)

	c._process_results_asynchronously() # frame 4: drain last 1, release
	f += _check_i("f4 cursor reset", c._drain_cursor, 0)
	f += _check_i("f4 batch released", c._drain_batch.size(), 0)
	c.free()
	return f


# Messages parsed mid-burst stay in _result_queue until the in-flight batch is
# fully drained — proves arrival order across the cursor handoff.
func _test_midburst_preserves_arrival_order() -> int:
	# 7 msgs, ceiling 3 → batch spans 3 frames (3,6,7), so retention across the
	# mid-burst append is unambiguous.
	var c: SpacetimeDBClient = _make_client(3)
	_fill(c, 7)
	var f: int = 0

	c._process_results_asynchronously() # frame 1: batch=7, cursor=3
	f += _check_i("mb f1 cursor", c._drain_cursor, 3)

	# Parser appends 4 NEW messages while the batch is still in flight.
	_fill(c, 4)
	c._process_results_asynchronously() # frame 2: drains held batch, NOT the new ones
	f += _check_i("mb f2 cursor", c._drain_cursor, 6)
	f += _check_i("mb f2 batch still held", c._drain_batch.size(), 7)
	f += _check_i("mb f2 new msgs untouched", c._result_queue.size(), 4)

	c._process_results_asynchronously() # frame 3: last msg of batch → released
	f += _check_i("mb f3 batch released", c._drain_batch.size(), 0)
	f += _check_i("mb f3 cursor reset", c._drain_cursor, 0)
	f += _check_i("mb f3 new msgs still queued", c._result_queue.size(), 4)

	c._process_results_asynchronously() # frame 4: only now refill from the 4 new ones
	f += _check_i("mb f4 picks up new batch", c._drain_batch.size(), 4)
	f += _check_i("mb f4 cursor", c._drain_cursor, 3)
	c.free()
	return f


# An in-flight batch from the old session must be dropped on reconnect prep so
# its stale messages aren't applied to the fresh database.
func _test_reconnect_drops_inflight_batch() -> int:
	var c: SpacetimeDBClient = _make_client(3)
	_fill(c, 10)
	c._process_results_asynchronously() # leaves a partially-drained batch
	var f: int = 0
	f += _check_i("pre-reconnect batch held", c._drain_batch.size(), 10)
	c._prepare_for_reconnect()
	f += _check_i("reconnect clears batch", c._drain_batch.size(), 0)
	f += _check_i("reconnect resets cursor", c._drain_cursor, 0)
	c.free()
	return f


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

# Unit test for SpacetimeDBStats — the per-request latency tracker. Drives
# record_send / record_response directly (no network) and asserts:
#   - a matched send/response increments count and decrements in_flight,
#   - latency folds into min/max/total (avg) sanely (latency >= 0),
#   - categories are isolated,
#   - record_response on an unknown id is a no-op,
#   - reset() clears everything,
#   - pending sends are capped at MAX_PENDING and eviction keeps in_flight honest.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_stats.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	fails += _test_basic_roundtrip()
	fails += _test_category_isolation()
	fails += _test_unknown_response_noop()
	fails += _test_reset()
	fails += _test_pending_cap_eviction()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _test_basic_roundtrip() -> int:
	var s: SpacetimeDBStats = SpacetimeDBStats.new()
	var red: int = SpacetimeDBStats.Category.REDUCER
	var f: int = 0

	s.record_send(1, red)
	s.record_send(2, red)
	var t: SpacetimeDBStats.Tracker = s.get_tracker(red)
	f += _check_i("in_flight after 2 sends", t.in_flight, 2)
	f += _check_i("count before any response", t.count, 0)

	s.record_response(1)
	f += _check_i("count after 1 response", t.count, 1)
	f += _check_i("in_flight after 1 response", t.in_flight, 1)
	f += _check_b("latency min >= 0", t.min_usec >= 0, true)
	f += _check_b("latency max >= min", t.max_usec >= t.min_usec, true)

	s.record_response(2)
	f += _check_i("count after 2 responses", t.count, 2)
	f += _check_i("in_flight drained", t.in_flight, 0)
	f += _check_b("avg within [min,max]", t.avg_usec() >= t.min_usec and t.avg_usec() <= t.max_usec, true)
	return f


func _test_category_isolation() -> int:
	var s: SpacetimeDBStats = SpacetimeDBStats.new()
	var f: int = 0
	s.record_send(10, SpacetimeDBStats.Category.REDUCER)
	s.record_send(11, SpacetimeDBStats.Category.PROCEDURE)
	s.record_send(12, SpacetimeDBStats.Category.SUBSCRIBE)
	s.record_response(11)
	f += _check_i("reducer count untouched", s.get_tracker(SpacetimeDBStats.Category.REDUCER).count, 0)
	f += _check_i("procedure count incremented", s.get_tracker(SpacetimeDBStats.Category.PROCEDURE).count, 1)
	f += _check_i("subscribe still in flight", s.get_tracker(SpacetimeDBStats.Category.SUBSCRIBE).in_flight, 1)
	f += _check_i("one_off untouched", s.get_tracker(SpacetimeDBStats.Category.ONE_OFF).count, 0)
	return f


func _test_unknown_response_noop() -> int:
	var s: SpacetimeDBStats = SpacetimeDBStats.new()
	var f: int = 0
	s.record_response(999) # never sent
	f += _check_i("unknown response adds no count", s.get_tracker(SpacetimeDBStats.Category.REDUCER).count, 0)
	return f


func _test_reset() -> int:
	var s: SpacetimeDBStats = SpacetimeDBStats.new()
	var red: int = SpacetimeDBStats.Category.REDUCER
	var f: int = 0
	s.record_send(1, red)
	s.record_response(1)
	s.record_send(2, red)
	s.reset()
	var t: SpacetimeDBStats.Tracker = s.get_tracker(red)
	f += _check_i("count cleared", t.count, 0)
	f += _check_i("in_flight cleared", t.in_flight, 0)
	# A previously-pending id must not resolve after reset.
	s.record_response(2)
	f += _check_i("stale pending dropped by reset", t.count, 0)
	return f


func _test_pending_cap_eviction() -> int:
	var s: SpacetimeDBStats = SpacetimeDBStats.new()
	var red: int = SpacetimeDBStats.Category.REDUCER
	var f: int = 0
	var cap: int = SpacetimeDBStats.MAX_PENDING
	# One past the cap; the oldest (id 0) is evicted.
	for i: int in range(cap + 1):
		s.record_send(i, red)
	var t: SpacetimeDBStats.Tracker = s.get_tracker(red)
	f += _check_i("in_flight capped at MAX_PENDING", t.in_flight, cap)
	# id 0 was evicted → its response is a no-op; id cap is still pending → resolves.
	s.record_response(0)
	f += _check_i("evicted id response no-op", t.count, 0)
	s.record_response(cap)
	f += _check_i("live id response counts", t.count, 1)
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

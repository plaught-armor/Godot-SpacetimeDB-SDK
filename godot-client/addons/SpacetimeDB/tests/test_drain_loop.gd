# Standalone headless test for the per-frame drain loop's pure pieces —
# SpacetimeDBClient._should_stop_drain (bounded-loop + at-least-one-progress
# stop rule) and _build_overflow_queue (cross-frame re-queue ordering). The
# real loop in _process_results_asynchronously calls both directly, so this
# tests the exact code paths without a live connection. No test framework:
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_drain_loop.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0

	# --- _should_stop_drain stop-rule cases ---
	# Empty batch → stop immediately, nothing processed.
	fails += _check_b("empty batch stops", _stop(0, 0, 256, 0, 4000), true)
	# First message always proceeds, even if elapsed already blew the budget —
	# guarantees >=1 progress for a single oversized message.
	fails += _check_b("first msg always proceeds", _stop(0, 5, 256, 999999, 100), false)
	# Hard ceiling honored once at least one processed.
	fails += _check_b("ceiling stops", _stop(256, 300, 256, 0, 4000), true)
	# Under ceiling, budget remaining → keep going.
	fails += _check_b("under ceiling continues", _stop(5, 300, 256, 1000, 4000), false)
	# Budget spent (>= boundary) → stop.
	fails += _check_b("budget spent stops", _stop(5, 300, 256, 4000, 4000), true)
	fails += _check_b("budget over stops", _stop(5, 300, 256, 4001, 4000), true)
	# Batch exhausted before ceiling → stop.
	fails += _check_b("batch exhausted stops", _stop(10, 10, 256, 0, 4000), true)

	# --- Full-drain simulation: loop using the real predicate ---
	# Single message costlier than the whole budget → exactly 1 processed.
	fails += _check_i("oversized single msg → 1", _simulate(1, 256, 100, 5000), 1)
	# Per-msg cost 0 with huge batch → ceiling caps it.
	fails += _check_i("zero-cost drain hits ceiling", _simulate(1000, 256, 0, 4000), 256)
	# Budget caps before ceiling: budget 4000, cost 1000 → ~4 messages then >=budget.
	fails += _check_i("budget caps drain", _simulate(100, 256, 1000, 4000), 4)
	# Small batch fully drained, no cap hit.
	fails += _check_i("small batch fully drained", _simulate(3, 256, 100, 4000), 3)

	# --- _build_overflow_queue ordering ---
	fails += _check_order()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _stop(processed: int, batch: int, max_msgs: int, elapsed: int, budget: int) -> bool:
	return SpacetimeDBClient._should_stop_drain(processed, batch, max_msgs, elapsed, budget)


# Mirrors the real loop: drive the real stop predicate with a constant per-message
# cost as the simulated elapsed clock. Returns the processed count.
func _simulate(batch_size: int, max_msgs: int, cost_us: int, budget_us: int) -> int:
	var processed: int = 0
	var elapsed: int = 0
	# Bounded by batch_size+1 — the predicate guarantees termination, this is a
	# runaway backstop (NASA rule 2).
	for _i: int in batch_size + 1:
		if SpacetimeDBClient._should_stop_drain(processed, batch_size, max_msgs, elapsed, budget_us):
			break
		processed += 1
		elapsed += cost_us
	return processed


# Re-queued leftover must drain first next frame (wire order preserved): the
# unprocessed tail of this frame's batch goes ahead of the already-queued msgs.
func _check_order() -> int:
	var m: Array[SpacetimeDBServerMessage] = []
	for _i: int in 5:
		m.append(SpacetimeDBServerMessage.new())
	# Simulate: batch had 5, processed first 2, leftover = [m2, m3, m4].
	var leftover: Array[SpacetimeDBServerMessage] = m.slice(2)
	var existing: Array[SpacetimeDBServerMessage] = [m[0]] # already-queued from a prior frame
	var result: Array[SpacetimeDBServerMessage] = SpacetimeDBClient._build_overflow_queue(leftover, existing)
	var want: Array[SpacetimeDBServerMessage] = [m[2], m[3], m[4], m[0]]
	_total += 1
	if result == want:
		print("PASS  overflow order = leftover ++ existing")
		return 0
	printerr("FAIL  overflow order mismatch")
	return 1


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

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
	# Ceiling of 1: first msg proceeds (processed==0), then processed==1>=1 stops.
	fails += _check_b("ceiling 1 proceeds at 0", _stop(0, 5, 1, 0, 4000), false)
	fails += _check_b("ceiling 1 stops at 1", _stop(1, 5, 1, 0, 4000), true)
	# processed==0 overrides even a 0 ceiling / 0 budget (>=1 progress is absolute).
	fails += _check_b("zero ceiling still proceeds first", _stop(0, 5, 0, 0, 0), false)
	# Budget just under boundary → continue (guards >= vs > on the budget check).
	fails += _check_b("budget one-under continues", _stop(5, 300, 256, 3999, 4000), false)

	# --- Full-drain simulation: loop using the real predicate ---
	# Single message costlier than the whole budget → exactly 1 processed.
	fails += _check_i("oversized single msg → 1", _simulate(1, 256, 100, 5000), 1)
	# Per-msg cost 0 with huge batch → ceiling caps it.
	fails += _check_i("zero-cost drain hits ceiling", _simulate(1000, 256, 0, 4000), 256)
	# Budget caps before ceiling: budget 4000, cost 1000 → ~4 messages then >=budget.
	fails += _check_i("budget caps drain", _simulate(100, 256, 1000, 4000), 4)
	# Small batch fully drained, no cap hit.
	fails += _check_i("small batch fully drained", _simulate(3, 256, 100, 4000), 3)
	# Ceiling of 1 caps a huge zero-cost batch at exactly 1.
	fails += _check_i("ceiling 1 caps drain", _simulate(1000, 1, 0, 4000), 1)
	# Budget at the floor (100us) with a per-msg cost far over it → exactly 1.
	fails += _check_i("floor budget oversized msg → 1", _simulate(100, 256, 5000, 100), 1)
	# Cost exactly == budget → first msg runs, elapsed hits budget, stop at 1.
	fails += _check_i("cost equals budget → 1", _simulate(100, 256, 4000, 4000), 1)

	# --- _build_overflow_queue ordering ---
	fails += _check_order()
	# Empty existing queue (the common overflow case) → result is just leftover.
	fails += _check_empty_existing()
	# Hardened contract: inputs are not mutated; result is a fresh array.
	fails += _check_no_aliasing()

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


# Overflow with nothing already queued (typical first-backlog frame).
func _check_empty_existing() -> int:
	var a: SpacetimeDBServerMessage = SpacetimeDBServerMessage.new()
	var b: SpacetimeDBServerMessage = SpacetimeDBServerMessage.new()
	var leftover: Array[SpacetimeDBServerMessage] = [a, b]
	var existing: Array[SpacetimeDBServerMessage] = []
	var result: Array[SpacetimeDBServerMessage] = SpacetimeDBClient._build_overflow_queue(leftover, existing)
	_total += 1
	if result == [a, b]:
		print("PASS  empty existing → leftover unchanged order")
		return 0
	printerr("FAIL  empty existing overflow mismatch")
	return 1


# Hardened no-aliasing contract: neither input is mutated in place. If the fn
# regressed to mutating `leftover` (the old behavior), its size would grow to 2
# and this catches it. Result content correctness checked alongside.
func _check_no_aliasing() -> int:
	var a: SpacetimeDBServerMessage = SpacetimeDBServerMessage.new()
	var b: SpacetimeDBServerMessage = SpacetimeDBServerMessage.new()
	var leftover: Array[SpacetimeDBServerMessage] = [a]
	var existing: Array[SpacetimeDBServerMessage] = [b]
	var result: Array[SpacetimeDBServerMessage] = SpacetimeDBClient._build_overflow_queue(leftover, existing)
	var fails: int = 0
	fails += _check_i("no-alias: leftover not mutated", leftover.size(), 1)
	fails += _check_i("no-alias: existing not mutated", existing.size(), 1)
	_total += 1
	if result == [a, b]:
		print("PASS  no-alias: result is combined leftover++existing")
	else:
		printerr("FAIL  no-alias: wrong result contents")
		fails += 1
	return fails


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

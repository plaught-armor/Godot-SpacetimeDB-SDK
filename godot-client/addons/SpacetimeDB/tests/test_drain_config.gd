# Standalone headless test for SpacetimeDBClient._resolve_drain_config — the
# pure resolve+clamp of per-frame drain limits from raw connection options.
# No test framework — run directly:
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_drain_config.gd
#
# Result layout: [max_msgs, min_us, max_us, budget_us, target_fps].
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var fails: int = 0

	# Defaults pass through untouched.
	fails += _check(
		"defaults pass through",
		SpacetimeDBClient._resolve_drain_config(256, 1000, 8000, 4000, 0),
		PackedInt32Array([256, 1000, 8000, 4000, 0]),
	)

	# max_msgs clamps [1, 8192]: 0 → 1 (loop must progress), huge → 8192.
	fails += _check(
		"max_msgs floor 1",
		SpacetimeDBClient._resolve_drain_config(0, 1000, 8000, 4000, 0),
		PackedInt32Array([1, 1000, 8000, 4000, 0]),
	)
	fails += _check(
		"max_msgs ceiling 8192",
		SpacetimeDBClient._resolve_drain_config(999999, 1000, 8000, 4000, 0),
		PackedInt32Array([8192, 1000, 8000, 4000, 0]),
	)

	# min_us floored at 100 — the 0-budget starvation guard (reviewer MEDIUM).
	fails += _check(
		"min_us floor 100",
		SpacetimeDBClient._resolve_drain_config(256, 0, 8000, 4000, 0),
		PackedInt32Array([256, 100, 8000, 4000, 0]),
	)

	# max_us floored at the resolved min so the range never inverts; budget then
	# re-clamps down into [100, 100].
	fails += _check(
		"max_us floored to min, budget follows",
		SpacetimeDBClient._resolve_drain_config(256, 5000, 1000, 4000, 0),
		PackedInt32Array([256, 5000, 5000, 5000, 0]),
	)

	# budget clamps up to min when configured below it.
	fails += _check(
		"budget clamps up to min",
		SpacetimeDBClient._resolve_drain_config(256, 2000, 8000, 500, 0),
		PackedInt32Array([256, 2000, 8000, 2000, 0]),
	)
	# budget clamps down to max when configured above it.
	fails += _check(
		"budget clamps down to max",
		SpacetimeDBClient._resolve_drain_config(256, 1000, 6000, 99999, 0),
		PackedInt32Array([256, 1000, 6000, 6000, 0]),
	)
	# negative budget floored to 0 then clamped to min.
	fails += _check(
		"negative budget → min",
		SpacetimeDBClient._resolve_drain_config(256, 1000, 8000, -50, 0),
		PackedInt32Array([256, 1000, 8000, 1000, 0]),
	)

	# target_fps floored at 0; positive passes through.
	fails += _check(
		"target_fps negative → 0",
		SpacetimeDBClient._resolve_drain_config(256, 1000, 8000, 4000, -10),
		PackedInt32Array([256, 1000, 8000, 4000, 0]),
	)
	fails += _check(
		"target_fps positive passes",
		SpacetimeDBClient._resolve_drain_config(256, 1000, 8000, 4000, 144),
		PackedInt32Array([256, 1000, 8000, 4000, 144]),
	)

	# --- Adversarial boundary-equality + extremes ---
	# max_msgs exactly on each clamp bound passes untouched (not off-by-one).
	fails += _check(
		"max_msgs exactly 1",
		SpacetimeDBClient._resolve_drain_config(1, 1000, 8000, 4000, 0),
		PackedInt32Array([1, 1000, 8000, 4000, 0]),
	)
	fails += _check(
		"max_msgs exactly 8192",
		SpacetimeDBClient._resolve_drain_config(8192, 1000, 8000, 4000, 0),
		PackedInt32Array([8192, 1000, 8000, 4000, 0]),
	)
	# Negative max_msgs floored to 1 (loop must still progress).
	fails += _check(
		"negative max_msgs → 1",
		SpacetimeDBClient._resolve_drain_config(-5, 1000, 8000, 4000, 0),
		PackedInt32Array([1, 1000, 8000, 4000, 0]),
	)
	# min_us exactly 100 passes untouched (boundary, not floored further).
	fails += _check(
		"min_us exactly 100",
		SpacetimeDBClient._resolve_drain_config(256, 100, 8000, 4000, 0),
		PackedInt32Array([256, 100, 8000, 4000, 0]),
	)
	# budget exactly == min and == max stay put (clamp is inclusive).
	fails += _check(
		"budget exactly == min",
		SpacetimeDBClient._resolve_drain_config(256, 2000, 8000, 2000, 0),
		PackedInt32Array([256, 2000, 8000, 2000, 0]),
	)
	fails += _check(
		"budget exactly == max",
		SpacetimeDBClient._resolve_drain_config(256, 1000, 6000, 6000, 0),
		PackedInt32Array([256, 1000, 6000, 6000, 0]),
	)
	# All-zeros: every floor/clamp fires at once → [1, 100, 100, 100, 0].
	fails += _check(
		"all zeros → all floors",
		SpacetimeDBClient._resolve_drain_config(0, 0, 0, 0, 0),
		PackedInt32Array([1, 100, 100, 100, 0]),
	)
	# min above max: max floored up to min, budget then pinned to that single point.
	fails += _check(
		"min above max collapses range",
		SpacetimeDBClient._resolve_drain_config(256, 9000, 8000, 5000, 0),
		PackedInt32Array([256, 9000, 9000, 9000, 0]),
	)

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check(label: String, got: PackedInt32Array, want: PackedInt32Array) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

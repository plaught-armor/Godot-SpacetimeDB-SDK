# Standalone headless test for SpacetimeDBClient._compute_tuned_budget (AIMD
# drain-budget controller). No test framework — run directly:
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_budget_tuner.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

func _initialize() -> void:
	var fails: int = 0
	# fps below 95% of target → multiplicative back off (4000 * 0.8).
	fails += _check(
		"shrink below target",
		SpacetimeDBClient._compute_tuned_budget(4000, 30.0, 60, 100, 1000, 8000),
		3200,
	)
	# Back off clamps to min (1100 * 0.8 = 880 → clamped 1000).
	fails += _check(
		"shrink clamps min",
		SpacetimeDBClient._compute_tuned_budget(1100, 10.0, 60, 100, 1000, 8000),
		1000,
	)
	# fps healthy + pending work → additive ramp (+500).
	fails += _check(
		"ramp healthy+pending",
		SpacetimeDBClient._compute_tuned_budget(4000, 60.0, 60, 5, 1000, 8000),
		4500,
	)
	# Ramp clamps to max (7800 + 500 = 8300 → clamped 8000).
	fails += _check(
		"ramp clamps max",
		SpacetimeDBClient._compute_tuned_budget(7800, 60.0, 60, 5, 1000, 8000),
		8000,
	)
	# Healthy fps but no backlog → hold (don't grow when nothing to drain).
	fails += _check(
		"no pending holds",
		SpacetimeDBClient._compute_tuned_budget(4000, 60.0, 60, 0, 1000, 8000),
		4000,
	)
	# Cold start (no frame measured) → hold, never shrink on noise.
	fails += _check(
		"cold start holds",
		SpacetimeDBClient._compute_tuned_budget(4000, 0.0, 60, 100, 1000, 8000),
		4000,
	)
	# Disabled target → hold.
	fails += _check(
		"zero target holds",
		SpacetimeDBClient._compute_tuned_budget(4000, 30.0, 0, 100, 1000, 8000),
		4000,
	)
	# Hysteresis dead band (95%–99%, e.g. 58/60) → hold.
	fails += _check(
		"hysteresis band holds",
		SpacetimeDBClient._compute_tuned_budget(4000, 58.0, 60, 100, 1000, 8000),
		4000,
	)

	if fails == 0:
		print("ALL PASS (8/8)")
	else:
		printerr("%d FAIL" % fails)
	quit(fails)


func _check(label: String, got: int, want: int) -> int:
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

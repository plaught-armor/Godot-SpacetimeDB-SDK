# Standalone headless test for SpacetimeDBClient._compute_tuned_budget (AIMD
# drain-budget controller) and resolve_target_fps, the rate it defends. No test
# framework — run directly:
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_budget_tuner.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## Counted rather than written down, so a case added below cannot leave the summary
## reporting a stale total.
var _total: int = 0


func _initialize() -> void:
	var fails: int = 0
	# --- resolve_target_fps: the tuner reads a RENDERED frame rate, so its target has
	# to be one too. It used to fall back to the physics tick rate, so a game capped at
	# 30 fps with the default 60 Hz physics read as permanently below target and drove
	# the budget to its floor while nothing was actually struggling.
	fails += _check("cap is the target", SpacetimeDBClient.resolve_target_fps(0, 30, 60, 30.0), 30)
	fails += _check(
		"an explicit target wins over the cap",
		SpacetimeDBClient.resolve_target_fps(72, 30, 60, 30.0),
		72,
	)
	fails += _check(
		"uncapped falls back to the physics rate",
		SpacetimeDBClient.resolve_target_fps(0, 0, 60, 30.0),
		60,
	)
	# A cap is what the game PERMITS, not what it achieves. Capping above what the
	# hardware delivers is a common idiom, and adopting that cap would compare 60
	# against 240 and pin the budget at the floor — the original bug, mirrored.
	fails += _check(
		"a cap the game never reaches is not the target",
		SpacetimeDBClient.resolve_target_fps(0, 240, 60, 60.0),
		60,
	)
	fails += _check(
		"a cap the game very nearly reaches is",
		SpacetimeDBClient.resolve_target_fps(0, 30, 60, 28.0),
		30,
	)
	# Cold start: no frame measured yet, so no cap is adopted. The controller holds on a
	# 0 fps reading anyway, so the first real frame arms the target a tick later.
	fails += _check(
		"cold start does not adopt the cap",
		SpacetimeDBClient.resolve_target_fps(0, 30, 60, 0.0),
		60,
	)
	# End to end for the mirrored case: a 240 cap on 60 fps hardware must ramp, not
	# collapse.
	var over_capped: int = 4000
	for _i: int in 12:
		over_capped = SpacetimeDBClient._compute_tuned_budget(
			over_capped,
			60.0,
			SpacetimeDBClient.resolve_target_fps(0, 240, 60, 60.0),
			50,
			1000,
			8000,
		)
	fails += _check("an unreachable cap still ramps", over_capped, 8000)
	# The whole point, end to end: a capped game holds its configured budget instead of
	# collapsing to the floor.
	var capped: int = 4000
	var uncapped: int = 4000
	for _i: int in 12:
		capped = SpacetimeDBClient._compute_tuned_budget(
			capped,
			30.0,
			SpacetimeDBClient.resolve_target_fps(0, 30, 60, 30.0),
			50,
			1000,
			8000,
		)
		uncapped = SpacetimeDBClient._compute_tuned_budget(
			uncapped,
			30.0,
			SpacetimeDBClient.resolve_target_fps(0, 0, 60, 30.0),
			50,
			1000,
			8000,
		)
	fails += _check("a 30 fps cap ramps the budget", capped, 8000)
	fails += _check("30 fps with no cap still backs off", uncapped, 1000)

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
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

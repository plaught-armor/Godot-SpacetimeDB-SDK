# Standalone headless test for SpacetimeDBSubscription's State machine
# (PENDING / ACTIVE / ENDED) — the flag-cluster refactor that replaced the
# _active/_ended bool pair, plus the mark_ended() no-signal path. No test
# framework — run directly:
#
#   cd godot-client && <godot> --headless --path . \
#       --script addons/SpacetimeDB/tests/test_subscription_state.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const PENDING: SpacetimeDBSubscription.State = SpacetimeDBSubscription.State.PENDING
const ACTIVE: SpacetimeDBSubscription.State = SpacetimeDBSubscription.State.ACTIVE
const ENDED: SpacetimeDBSubscription.State = SpacetimeDBSubscription.State.ENDED

var _total: int = 0
var _end_emit_count: int = 0


func _initialize() -> void:
	var fails: int = 0

	# fail() builds a pre-ended handle for an immediate client-side error.
	var f: SpacetimeDBSubscription = SpacetimeDBSubscription.fail(ERR_CONNECTION_ERROR)
	fails += _check_i("fail() → ENDED", f._state, ENDED)
	fails += _check_b("fail() ended true", f.ended, true)
	fails += _check_b("fail() active false", f.active, false)
	fails += _check_i("fail() keeps error", f.error, ERR_CONNECTION_ERROR)

	# Fresh handle starts PENDING — neither active nor ended.
	var s: SpacetimeDBSubscription = SpacetimeDBSubscription.create(null, 1, PackedStringArray())
	fails += _check_i("fresh → PENDING", s._state, PENDING)
	fails += _check_b("fresh active false", s.active, false)
	fails += _check_b("fresh ended false", s.ended, false)

	# mark_ended() on PENDING → ENDED, and must NOT emit `end` (no awaiter unblock).
	var m: SpacetimeDBSubscription = SpacetimeDBSubscription.create(null, 2, PackedStringArray())
	_end_emit_count = 0
	m.end.connect(_on_end_counter)
	m.mark_ended()
	fails += _check_i("mark_ended() PENDING → ENDED", m._state, ENDED)
	fails += _check_b("mark_ended() ended true", m.ended, true)
	fails += _check_i("mark_ended() does not emit end", _end_emit_count, 0)

	# mark_ended() is a no-op once ACTIVE — a confirmed sub must end via _on_end.
	var a: SpacetimeDBSubscription = SpacetimeDBSubscription.create(null, 3, PackedStringArray())
	a.applied.emit()
	fails += _check_i("applied → ACTIVE", a._state, ACTIVE)
	fails += _check_b("ACTIVE active true", a.active, true)
	fails += _check_b("ACTIVE ended false", a.ended, false)
	a.mark_ended()
	fails += _check_i("mark_ended() no-op on ACTIVE", a._state, ACTIVE)

	# mark_ended() is idempotent on an already-ENDED handle.
	var e: SpacetimeDBSubscription = SpacetimeDBSubscription.create(null, 4, PackedStringArray())
	e.mark_ended()
	e.mark_ended()
	fails += _check_i("mark_ended() idempotent on ENDED", e._state, ENDED)

	# The `end` signal drives _on_end → ENDED (the path that unblocks awaiters).
	var d: SpacetimeDBSubscription = SpacetimeDBSubscription.create(null, 5, PackedStringArray())
	d.end.emit()
	fails += _check_i("end signal → ENDED", d._state, ENDED)
	fails += _check_b("end signal ended true", d.ended, true)
	fails += _check_b("end signal active false", d.active, false)

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _on_end_counter() -> void:
	_end_emit_count += 1


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

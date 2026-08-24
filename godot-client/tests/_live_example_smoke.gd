# Smoke-checks the Blackholio EXAMPLE against a live server.
#
# The SDK has eleven live harnesses; the example had none, and it carried a real defect
# for several releases because of it: `_subscribe_all()` ran from `_on_connected`, and
# `connected` fires again on every reconnect — so each drop added a duplicate query set
# server-side, on top of the one the SDK restores by itself. Nothing exercised the
# example end to end, so nothing noticed.
#
# This runs main.tscn as a player would, then drops the socket underneath it. The
# subscription count before and after the reconnect is the assertion that would have
# caught that bug, and every other check here exists to make that one meaningful — a
# client that never subscribed also has "not two" subscriptions.
#
# It asserts the example's OWN behaviour, not the SDK's (tests/_live_reconnect_check.gd
# owns that). Underscore-prefixed so run_tests.sh skips it; it needs a server.
#
#   spacetime start ... && cd blackholio-server && ./publish.sh
#   cd godot-client && <godot> --headless --path . res://tests/_live_example_smoke.tscn > smoke.log 2>&1
#   echo $?   # number of failed checks
#
# The example persists its auth token (one_time_token = false), so a run leaves
# user://spacetimedb_token.dat behind and a later run resumes that identity — which is
# the example's rejoin path, and why the name check below accepts either branch.
extends Node

const MAIN_SCENE: String = "res://main.tscn"
## The example's own connect + subscribe round trip, plus room for a slow first import.
const READY_TIMEOUT: float = 30.0
## Reconnect is paced by the example's options, not ours — it uses the SDK defaults.
const RECOVERY_TIMEOUT: float = 30.0
const PLAYER_NAME: String = "SmokeCheck"

var _total: int = 0
var _fails: int = 0
var _reconnected: int = 0
var _main: Node = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	if scene == null:
		printerr("could not load %s" % MAIN_SCENE)
		_finish()
		return
	_main = scene.instantiate()
	add_child(_main)
	SpacetimeDB.Blackholio.reconnected.connect(_on_reconnected)

	# 1. The example connects and fills its mirror on its own.
	_check("the example connected", await _wait_until(_is_connected, READY_TIMEOUT), true)
	_check("its subscription applied", await _wait_until(_has_rows, READY_TIMEOUT), true)
	_check("holding exactly one query set", SpacetimeDB.Blackholio.current_subscriptions.size(), 1)

	# 2. It can actually play. enter_game is the path the username screen drives; calling
	# it directly is what a headless run has instead of a keyboard.
	if not _main.game_started:
		_main.on_enter_game(PLAYER_NAME)
	_check(
		"a player row arrived for this identity",
		await _wait_until(_has_own_player, READY_TIMEOUT),
		true,
	)
	_check("and the example considers itself in-game", _main.game_started, true)

	# 3. The regression. Drop the socket underneath it, exactly as the SDK's own harness
	# does, and let the example's `connected` handler run again on the way back.
	var before: int = SpacetimeDB.Blackholio.current_subscriptions.size()
	SpacetimeDB.Blackholio._connection._websocket.close(1000, "smoke drop")
	_check("it reconnected", await _wait_until(_has_reconnected, RECOVERY_TIMEOUT), true)
	# The SDK restores what the example already held. An example that subscribes again
	# from its `connected` handler ends up with two query sets for one game.
	_check(
		"still exactly one query set after the reconnect",
		SpacetimeDB.Blackholio.current_subscriptions.size(),
		before,
	)
	_check("and its rows came back", _has_rows(), true)

	_finish()

# --- conditions ---


func _is_connected() -> bool:
	return SpacetimeDB.Blackholio.is_connected_db()


func _has_rows() -> bool:
	return SpacetimeDB.Blackholio.db != null and SpacetimeDB.Blackholio.db.config.count() > 0


func _has_own_player() -> bool:
	if SpacetimeDB.Blackholio.db == null:
		return false
	var identity: PackedByteArray = SpacetimeDB.Blackholio.get_local_identity()
	if identity.is_empty():
		return false
	return SpacetimeDB.Blackholio.db.player.identity.find(identity) != null


func _has_reconnected() -> bool:
	return _reconnected > 0


func _on_reconnected() -> void:
	_reconnected += 1

# --- harness ---


## Polls [param condition] each frame until it holds or [param timeout] elapses.
func _wait_until(condition: Callable, timeout: float) -> bool:
	var deadline: SceneTreeTimer = get_tree().create_timer(timeout, true, false, true)
	while deadline.time_left > 0.0:
		if condition.call():
			return true
		await get_tree().process_frame
	return condition.call()


func _finish() -> void:
	if _main != null and is_instance_valid(_main):
		SpacetimeDB.Blackholio.disconnect_db()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	get_tree().quit(_fails)


func _check(label: String, got: Variant, want: Variant) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1

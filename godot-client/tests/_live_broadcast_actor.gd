# The second client in the broadcast check: connects under its own identity, calls
# one reducer, and leaves. Everything asserted about it happens in the observer
# (_live_broadcast_check.gd) — this process only has to exist and make a change.
#
# Launched by _live_broadcast.sh; not useful on its own.
extends Node

## Name the actor gives itself, so the observer can recognise the row.
const ACTOR_NAME: String = "Bystander"


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	# A fresh token means a fresh identity: this must not reuse the observer's.
	options.one_time_token = true
	options.save_token = false
	SpacetimeDB.Blackholio.connected.connect(_on_connected, CONNECT_ONE_SHOT)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	# enter_game needs the player row the module's connect lifecycle reducer makes,
	# so give the server a moment to run it before calling.
	await get_tree().create_timer(1.0).timeout

	var call: SpacetimeDBReducerCall = SpacetimeDB.Blackholio.reducers.enter_game(ACTOR_NAME)
	var _settled: SpacetimeDBReducerCall = await call.wait_for_response(10.0)
	if call.outcome != SpacetimeDBReducerCall.Outcome.OK:
		printerr("[actor] enter_game failed: outcome %d %s" % [call.outcome, call.error_message])
		get_tree().quit(1)
		return

	print("[actor] entered the game as %s" % ACTOR_NAME)
	# Stay connected briefly: disconnecting immediately makes the module delete the
	# player row again, and the observer would race the delete.
	await get_tree().create_timer(3.0).timeout
	get_tree().quit(0)

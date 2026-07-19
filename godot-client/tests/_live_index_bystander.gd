# A second player, so the btree index holds more than one key while the index
# check runs.
#
# With only one client in the world, circle.player_id has a single bucket and every
# range accessor returns either that bucket or nothing — the sorted-key bsearch
# window is never exercised. This client enters the game under its own identity and
# then does nothing until it is killed, which is enough to put a second key in the
# cache of the client under test.
#
# Launched by _live_index.sh; not useful on its own.
extends Node

## Name this client enters the game under.
const BYSTANDER_NAME: String = "IndexBystander"
## Printed once its row exists, so the driver knows the check can start.
const CUE: String = "[bystander] IN_THE_GAME"
## Backstop so an abandoned process cannot outlive the run forever.
const MAX_LIFETIME: float = 180.0


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	# A fresh token means a fresh identity: this must not reuse the checker's.
	options.one_time_token = true
	options.save_token = false
	SpacetimeDB.Blackholio.connected.connect(_on_connected, CONNECT_ONE_SHOT)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	# enter_game needs the player row the module's connect lifecycle reducer makes.
	await get_tree().create_timer(1.0).timeout

	var call: SpacetimeDBReducerCall = SpacetimeDB.Blackholio.reducers.enter_game(BYSTANDER_NAME)
	var settled: SpacetimeDBReducerCall = await call.wait_for_response(10.0)
	if settled.outcome != SpacetimeDBReducerCall.Outcome.OK:
		printerr(
			"[bystander] enter_game failed: outcome %d %s"
			% [settled.outcome, settled.error_message]
		)
		get_tree().quit(1)
		return

	# The driver waits on this line before starting the client under test.
	print(CUE)
	# Staying connected keeps the row alive: the module deletes it on disconnect.
	await get_tree().create_timer(MAX_LIFETIME).timeout
	get_tree().quit(0)

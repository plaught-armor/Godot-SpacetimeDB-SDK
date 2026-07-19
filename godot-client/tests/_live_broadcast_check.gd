# Checks that this client sees ANOTHER client's transaction.
#
# Every transaction fixture so far was produced by the caller's own reducer call,
# where the row changes arrive nested inside the reducer response. A broadcast is a
# different shape — a standalone TransactionUpdate, sent because someone else
# changed a row this client subscribes to — and nothing had ever exercised it
# against a real server.
#
# Getting one requires a second client with its own identity, so this is the
# observer half of a pair. _live_broadcast.sh runs both:
#
#   GODOT=/path/to/godot tests/_live_broadcast.sh
#   echo $?   # number of failed checks
#
# Also writes tests/fixtures/wire_broadcast_txn.bin, so the offline suite keeps a
# replayable copy of a transaction this client did not cause.
extends Node

const FIXTURE_PATH: String = "res://tests/fixtures/wire_broadcast_txn.bin"
## Printed once subscribed, so the driver knows when to start the second client.
const CUE: String = "[observer] START_THE_ACTOR_NOW"
## Must match _live_broadcast_actor.gd.
const ACTOR_NAME: String = "Bystander"
## Covers the actor's own startup (connect, token, lifecycle reducer) plus slack.
const BROADCAST_TIMEOUT: float = 60.0

# C1: never const a Packed*Array.
var _queries: PackedStringArray = ["SELECT * FROM player"]
var _fails: int = 0
var _total: int = 0
var _broadcasts: int = 0
var _actor_row_seen: bool = false
var _file: FileAccess


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	options.save_token = false
	SpacetimeDB.Blackholio.transaction_update_received.connect(_on_transaction_update)
	SpacetimeDB.Blackholio.connected.connect(_run, CONNECT_ONE_SHOT)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


# This client never calls a reducer, so every transaction that arrives here was
# caused by someone else — which is the whole point of the fixture.
func _on_transaction_update(update: TransactionUpdateMessage) -> void:
	_broadcasts += 1
	for query_set: DatabaseUpdateData in update.query_sets:
		for table: TableUpdateData in query_set.tables:
			if String(table.table_name) != "player":
				continue
			for row: Resource in table.inserts:
				if String(row.get("name")) == ACTOR_NAME:
					_actor_row_seen = true


func _run(_identity: PackedByteArray, _token: String) -> void:
	var sub: SpacetimeDBSubscription = SpacetimeDB.Blackholio.subscribe(_queries)
	_check("subscribed to player", await sub.wait_for_applied(10.0) == OK, true)

	_file = FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	SpacetimeDB.Blackholio._connection.message_received.connect(_on_packet)

	# The driver is waiting on this line before it starts the second client.
	print(CUE)

	var arrived: bool = await _wait_for_actor_row()
	_check("saw the other client's row within %.0fs" % BROADCAST_TIMEOUT, arrived, true)
	_check("received a standalone transaction update", _broadcasts >= 1, true)
	# The cache is the thing a game actually reads, so check the row landed there
	# and not merely in a signal payload.
	_check("the other player is in the local cache", _actor_in_cache(), true)
	_finish()


func _actor_in_cache() -> bool:
	for row: Resource in SpacetimeDB.Blackholio.db.player.iter():
		if String(row.get("name")) == ACTOR_NAME:
			return true
	return false


## Resolves true once the actor's row has been observed, false on timeout.
func _wait_for_actor_row() -> bool:
	var deadline: SceneTreeTimer = get_tree().create_timer(BROADCAST_TIMEOUT)
	while not _actor_row_seen and deadline.time_left > 0.0:
		await get_tree().process_frame
	return _actor_row_seen


func _finish() -> void:
	if _file != null:
		_file.close()
		_file = null
		# A failed run captured something other than what the fixture claims to be —
		# most likely a window where the broadcast never arrived. Delete it rather
		# than leave a plausible-looking artifact for someone to commit.
		if _fails > 0:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_PATH))
			print("[observer] discarded %s (run failed)" % FIXTURE_PATH)
		else:
			print("[observer] wrote %s" % FIXTURE_PATH)
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	get_tree().quit(_fails)


func _on_packet(bytes: PackedByteArray) -> void:
	if _file == null:
		return
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)


func _check(label: String, got: Variant, want: Variant) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1

# Regenerates the wire fixtures that test_wire_fixture_decode.gd replays: real
# inbound frames from a live Blackholio module, not bytes we authored. Needs a
# running server with the module published. Underscore-prefixed so run_tests.sh
# skips it, and a scene rather than --script because it needs the generated
# autoload.
#
#   spacetime start ... && cd blackholio-server && ./publish.sh
#   cd godot-client && <godot> --headless --path . res://tests/_capture_wire_fixture.tscn
#
# Writes two fixtures, both length-prefixed raw frames (compression NONE) that
# still carry the leading compression tag byte the client strips at parse time:
#
#   wire_snapshot.bin — the subscription snapshot (SubscribeApplied + rows)
#   wire_txn.bin      — a transaction update carrying a reducer event, produced by
#                       calling enter_game while subscribed
extends Node

const SNAPSHOT_PATH: String = "res://tests/fixtures/wire_snapshot.bin"
const TXN_PATH: String = "res://tests/fixtures/wire_txn.bin"

var _file: FileAccess
var _count: int = 0


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	# NONE so the fixture is raw BSATN framing, replayable without a decompress step.
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	SpacetimeDB.Blackholio.connected.connect(_on_connected)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	SpacetimeDB.Blackholio._connection.message_received.connect(_on_packet)

	# 1. Subscription snapshot. Narrow queries so the fixture stays small; the
	#    entity filter still yields a row with a real nested DbVector2.
	_open(SNAPSHOT_PATH)
	var sub: SpacetimeDBSubscription = SpacetimeDB \
			.Blackholio \
			.subscribe([
				"SELECT * FROM config",
				"SELECT * FROM player",
				"SELECT * FROM entity WHERE entity_id = 1",
			])
	await sub.wait_for_applied(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("snapshot")

	# 2. Transaction update + reducer event, from our own reducer call.
	_open(TXN_PATH)
	var call: SpacetimeDBReducerCall = SpacetimeDB.Blackholio.reducers.enter_game("WireFixture")
	await call.wait_for_response(10.0)
	await get_tree().create_timer(3.0).timeout
	_close("txn")

	get_tree().quit()


func _open(path: String) -> void:
	_file = FileAccess.open(path, FileAccess.WRITE)
	_count = 0


func _close(label: String) -> void:
	var path: String = _file.get_path()
	_file.close()
	_file = null
	print(
		"[capture] %s: packets=%d bytes=%d"
		% [label, _count, FileAccess.get_file_as_bytes(path).size()]
	)


func _on_packet(bytes: PackedByteArray) -> void:
	if _file == null:
		return
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)
	_count += 1

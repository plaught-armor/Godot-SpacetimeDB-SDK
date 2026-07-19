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
#   wire_procedure.bin     — a value-returning procedure response (probe_vector3)
#   wire_procedure_err.bin — the err arm of the same Result type (probe_error)
#   wire_one_off_query.bin — a query_sql / OneOffQueryResponse result
extends Node

const SNAPSHOT_PATH: String = "res://tests/fixtures/wire_snapshot.bin"
const TXN_PATH: String = "res://tests/fixtures/wire_txn.bin"
const PROC_PATH: String = "res://tests/fixtures/wire_procedure.bin"
const PROC_ERR_PATH: String = "res://tests/fixtures/wire_procedure_err.bin"
const SQL_PATH: String = "res://tests/fixtures/wire_one_off_query.bin"

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

	# publish.sh republishes with --delete-data, so give the module's scheduled
	# food spawner a moment to seed entities before snapshotting one.
	await get_tree().create_timer(3.0).timeout

	# 1. Subscription snapshot. Narrow queries so the fixture stays small; the
	#    entity filter still yields a row with a real nested DbVector2.
	_open(SNAPSHOT_PATH)
	var sub: SpacetimeDBSubscription = SpacetimeDB \
			.Blackholio \
			.subscribe(
		[
			"SELECT * FROM config",
			"SELECT * FROM player",
			"SELECT * FROM entity WHERE entity_id = 1",
		]
	)
	await sub.wait_for_applied(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("snapshot")

	# 2. Transaction update + reducer event, from our own reducer call.
	_open(TXN_PATH)
	var call: SpacetimeDBReducerCall = SpacetimeDB.Blackholio.reducers.enter_game("WireFixture")
	await call.wait_for_response(10.0)
	await get_tree().create_timer(3.0).timeout
	_close("txn")

	# 3. Procedure return. The shape that shipped broken: a value-returning
	#    procedure, whose Result<T, E> the decoder could not resolve at all.
	_open(PROC_PATH)
	var proc: SpacetimeDBProcedureCall = SpacetimeDB.Blackholio.procedures.probe_vector_3()
	await proc.wait_for_response(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("procedure")

	# 4. The err arm of the same Result type. Only the ok arm was ever captured,
	#    and nothing in the suite asserted an err payload at all.
	_open(PROC_ERR_PATH)
	var failing: SpacetimeDBProcedureCall = SpacetimeDB.Blackholio.procedures.probe_error()
	await failing.wait_for_response(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("procedure_err")

	# 5. One-off query response. query_sql had no test of any kind, and its
	#    awaiter dropped every result on a signal-arity mismatch.
	_open(SQL_PATH)
	var _rows: Array[TableUpdateData] = await SpacetimeDB \
			.Blackholio \
			.query_sql("SELECT * FROM config")
	await get_tree().create_timer(0.5).timeout
	_close("one_off_query")

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

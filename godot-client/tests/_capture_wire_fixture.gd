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
#   wire_unsubscribe.bin   — an UnsubscribeApplied response
#   wire_subscription_error.bin — a SubscriptionError for an uncompilable query
#   wire_procedure_params.bin   — a procedure response computed from its arguments
#   wire_identity_token.bin     — the handshake IdentityToken, captured by hooking
#                                 the socket before the connection completes. Its
#                                 JWT is scrubbed in place (see _scrub_token).
extends Node

const IDENTITY_PATH: String = "res://tests/fixtures/wire_identity_token.bin"
const SNAPSHOT_PATH: String = "res://tests/fixtures/wire_snapshot.bin"
const TXN_PATH: String = "res://tests/fixtures/wire_txn.bin"
const PROC_PATH: String = "res://tests/fixtures/wire_procedure.bin"
const PROC_ERR_PATH: String = "res://tests/fixtures/wire_procedure_err.bin"
const SQL_PATH: String = "res://tests/fixtures/wire_one_off_query.bin"
const UNSUB_PATH: String = "res://tests/fixtures/wire_unsubscribe.bin"
const SUB_ERR_PATH: String = "res://tests/fixtures/wire_subscription_error.bin"
const PROC_PARAMS_PATH: String = "res://tests/fixtures/wire_procedure_params.bin"

# Where the IdentityToken's token string starts inside the captured file:
# u32 frame length, compression tag, ServerMessage variant tag, 32-byte identity,
# 16-byte connection id — then the u32 string length the scrub actually reads.
const TOKEN_LENGTH_OFFSET: int = 4 + 1 + 1 + 32 + 16
const DOT: int = 0x2E
const FILLER: int = 0x78 # 'x'
# A dev-server JWT is several hundred bytes; anything shorter means the offsets
# above no longer describe the message, and the scrub must not pass quietly.
const MIN_TOKEN_BYTES: int = 100

var _file: FileAccess
var _count: int = 0


func _ready() -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	# NONE so the fixture is raw BSATN framing, replayable without a decompress step.
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	SpacetimeDB.Blackholio.connected.connect(_on_connected)
	SpacetimeDB.Blackholio.connect_db("http://127.0.0.1:3000", "blackholio", options)

	# 0. IdentityToken arrives during the handshake, before `connected` fires — so
	#    the hook has to be attached here. connect_db() builds the connection
	#    synchronously and only then goes async for the token, so the socket is
	#    live-but-silent at this point and no frame is missed.
	_open(IDENTITY_PATH)
	SpacetimeDB.Blackholio._connection.message_received.connect(_on_packet)


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	# publish.sh republishes with --delete-data, so give the module's scheduled
	# food spawner a moment to seed entities before snapshotting one.
	await get_tree().create_timer(3.0).timeout

	# The handshake is the only traffic so far — nothing is subscribed yet — so
	# this file holds the IdentityToken and nothing else. Closed here rather than
	# inside the `connected` handler so it cannot race the frame that emitted it.
	_close("identity_token")
	_scrub_token(IDENTITY_PATH)

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

	# 6. Unsubscribe. Works today; captured so it keeps working.
	var temp: SpacetimeDBSubscription = SpacetimeDB.Blackholio.subscribe(["SELECT * FROM player"])
	await temp.wait_for_applied(10.0)
	_open(UNSUB_PATH)
	temp.unsubscribe()
	await temp.wait_for_end(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("unsubscribe")

	# 7. Subscription error, from a query the server cannot compile.
	_open(SUB_ERR_PATH)
	var bad: SpacetimeDBSubscription = SpacetimeDB \
			.Blackholio \
			.subscribe(["SELECT * FROM does_not_exist"])
	await bad.wait_for_applied(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("subscription_error")

	# 8. Procedure PARAMETERS. The module echoes a value computed from its
	#    arguments, so the response proves they crossed the wire intact.
	_open(PROC_PARAMS_PATH)
	var echoed: SpacetimeDBProcedureCall = SpacetimeDB \
			.Blackholio \
			.procedures \
			.probe_params(Vector3(1.0, 2.0, 3.0), 3, "hello")
	await echoed.wait_for_response(10.0)
	await get_tree().create_timer(0.5).timeout
	_close("procedure_params")

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


# The IdentityToken carries a live JWT for the session's identity, minted with no
# expiry by the local dev server's signing key — a credential, and this fixture is
# committed. Overwrite the JWT in place with same-length filler so every BSATN
# length prefix around it stays valid and the frame still decodes byte-for-byte the
# way the server framed it. Only the token's *characters* stop being real.
func _scrub_token(path: String) -> void:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.size() < TOKEN_LENGTH_OFFSET + 4:
		printerr("[capture] %s is too short to hold an IdentityToken — not scrubbed" % path)
		return

	# Read the token's own length rather than hunting for where the JWT looks like
	# it ends: a search would blank whatever random bytes downstream happened to be
	# base64-shaped, and would silently blank nothing if it locked onto the wrong
	# start. The length prefix is the message's own answer.
	var length: int = bytes.decode_u32(TOKEN_LENGTH_OFFSET)
	var start: int = TOKEN_LENGTH_OFFSET + 4
	if length < MIN_TOKEN_BYTES or start + length > bytes.size():
		printerr(
			"[capture] %s: token length %d is implausible — the message layout changed. "
			% [path, length]
			+ "NOT scrubbed; do not commit this fixture until the offsets are fixed."
		)
		return

	# Blank every character but the two dots, so the value still reads as a
	# three-part JWT. One byte in, one byte out: every BSATN length prefix around it
	# stays valid and the frame decodes exactly as the server framed it.
	for i: int in range(start, start + length):
		if bytes[i] != DOT:
			bytes[i] = FILLER

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("[capture] cannot rewrite %s — the live token is still on disk" % path)
		return
	file.store_buffer(bytes)
	file.close()
	print("[capture] identity_token: scrubbed %d token bytes" % length)


func _on_packet(bytes: PackedByteArray) -> void:
	if _file == null:
		return
	_file.store_32(bytes.size())
	_file.store_buffer(bytes)
	_count += 1

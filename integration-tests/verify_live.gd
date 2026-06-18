# Live end-to-end verification of the experimental serialization types against a
# running SpacetimeDB server with the official `sdk-test` module published as `sdktest`.
#
# For each type: call the insert reducer with a known value (tests SERIALIZE), let the
# subscription deliver the row back, read it from the cache (tests DESERIALIZE), and
# assert the round-trip is byte-exact. This is the full client -> server -> client path.
#
#   spacetime publish -p <repo>/modules/sdk-test -s http://127.0.0.1:3000 sdktest --yes
#   cd godot-client && <godot> --headless --path . --script verify_live.gd
extends SceneTree

var _client: VtypesModuleClient
var _sched_micros: int = 3_600_000_000
var _total: int = 0
var _fails: int = 0


func _initialize() -> void:
	_run()


func _mk(size: int, seed_offset: int) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(size)
	for i: int in range(size):
		b[i] = (i * 7 + seed_offset) & 0xFF
	return b


func _run() -> void:
	_client = VtypesModuleClient.new()
	root.add_child(_client)
	await process_frame # let the client + its HTTPRequest enter the tree before connecting

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	options.save_token = false
	_client.connect_db("http://127.0.0.1:3000", "vtypes", options)

	await _client.connected
	print("connected")

	var sub: SpacetimeDBSubscription = _client.subscribe(
		[
			"SELECT * FROM one_u128",
			"SELECT * FROM one_u256",
			"SELECT * FROM one_i128",
			"SELECT * FROM one_i256",
			"SELECT * FROM one_uuid",
			"SELECT * FROM my_schedule",
		],
	)
	await sub.applied
	print("subscribed")

	var v_u128: PackedByteArray = _mk(16, 1)
	var v_u256: PackedByteArray = _mk(32, 3)
	var v_i128: PackedByteArray = _mk(16, 9)
	var v_i256: PackedByteArray = _mk(32, 5)
	var v_uuid: PackedByteArray = _mk(16, 11)

	await _case_bytes("u128", _client.reducers.insert_one_u_128(v_u128), _client.db.one_u_128, &"n", v_u128)
	await _case_bytes("u256", _client.reducers.insert_one_u_256(v_u256), _client.db.one_u_256, &"n", v_u256)
	await _case_bytes("i128", _client.reducers.insert_one_i_128(v_i128), _client.db.one_i_128, &"n", v_i128)
	await _case_bytes("i256", _client.reducers.insert_one_i_256(v_i256), _client.db.one_i_256, &"n", v_i256)
	await _case_bytes("uuid", _client.reducers.insert_one_uuid(v_uuid), _client.db.one_uuid, &"u", v_uuid)
	await _case_schedule()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	_client.disconnect_db()
	quit(_fails)


func _case_bytes(label: String, call: SpacetimeDBReducerCall, table: _ModuleTable, field: StringName, expected: PackedByteArray) -> void:
	await call.wait_for_response(5.0)
	_total += 1
	if not call.is_ok():
		printerr("FAIL  %s: reducer outcome %d (%s)" % [label, call.outcome, call.error_message])
		_fails += 1
		return
	var rows: Array = table.iter()
	if rows.is_empty():
		printerr("FAIL  %s: no row in cache after insert" % label)
		_fails += 1
		return
	var got: PackedByteArray = rows[0].get(field)
	if got == expected:
		print("PASS  %s round-trip byte-exact (%d bytes)" % [label, got.size()])
	else:
		printerr("FAIL  %s: got %s want %s" % [label, got.hex_encode(), expected.hex_encode()])
		_fails += 1


# ScheduleAt: add_schedule(micros) inserts an Interval row; read it back and check
# the variant tag (INTERVAL) and the microsecond payload survived the round-trip.
func _case_schedule() -> void:
	var call: SpacetimeDBReducerCall = _client.reducers.add_schedule(_sched_micros)
	await call.wait_for_response(5.0)
	_total += 1
	if not call.is_ok():
		printerr("FAIL  schedule: reducer outcome %d (%s)" % [call.outcome, call.error_message])
		_fails += 1
		return
	var rows: Array = _client.db.my_schedule.iter()
	if rows.is_empty():
		printerr("FAIL  schedule: no row in cache after insert")
		_fails += 1
		return
	var sched: ScheduleAt = rows[0].get(&"scheduled_at")
	if sched == null or not (sched is ScheduleAt):
		printerr("FAIL  schedule: scheduled_at not a ScheduleAt")
		_fails += 1
		return
	if sched.kind == ScheduleAt.Kind.INTERVAL and sched.micros == _sched_micros:
		print("PASS  ScheduleAt round-trip (Interval, %d micros)" % sched.micros)
	else:
		printerr("FAIL  schedule: kind=%d micros=%d (want INTERVAL/%d)" % [sched.kind, sched.micros, _sched_micros])
		_fails += 1

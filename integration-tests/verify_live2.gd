# Live end-to-end verification of behaviors we changed/deferred, against a running
# SpacetimeDB server with the `vtypes2` module (integration-tests/verify_types_module2).
#
#   G1 refcount      — a row shared by two overlapping subscriptions fires on_insert ONCE.
#   G2 unsubscribe    — unsubscribing one of two overlapping subs keeps the shared row.
#   G3 event table    — event-table rows fire on_insert but are never stored (count==0).
#   TimeDuration      — a TimeDuration column round-trips as int micros.
#   default_values    — an auto_inc pk table (default_values dropped) still deserializes.
#   fallible reducer  — a reducer returning Err surfaces as Outcome.ERROR + message.
extends SceneTree

var _client: Vtypes2ModuleClient
var _total: int = 0
var _fails: int = 0

var _thing_inserts: int = 0
var _thing_deletes: int = 0
var _event_inserts: int = 0


func _initialize() -> void:
	_run()


func _on_thing_insert(_row: _ModuleTableType) -> void:
	_thing_inserts += 1


func _on_thing_delete(_row: _ModuleTableType) -> void:
	_thing_deletes += 1


func _on_event_insert(_row: _ModuleTableType) -> void:
	_event_inserts += 1


func _check(label: String, cond: bool) -> void:
	_total += 1
	if cond:
		print("PASS  %s" % label)
	else:
		printerr("FAIL  %s" % label)
		_fails += 1


func _run() -> void:
	_client = Vtypes2ModuleClient.new()
	root.add_child(_client)
	await process_frame

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE
	options.one_time_token = true
	options.save_token = false
	_client.connect_db("http://127.0.0.1:3000", "vtypes2", options)
	await _client.connected
	print("connected")

	_client.db.thing.on_insert(_on_thing_insert)
	_client.db.thing.on_delete(_on_thing_delete)
	_client.db.event_log.on_insert(_on_event_insert)

	# --- G1 + G2: two overlapping (identical) subscriptions share the same row ---
	var sub_a: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM thing"])
	await sub_a.applied
	var sub_b: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM thing"])
	await sub_b.applied

	await _client.reducers.add_thing(1, "x").wait_for_response(5.0)
	_check("G1: shared-row insert fires on_insert once (got %d)" % _thing_inserts, _thing_inserts == 1)
	_check("G1: row cached", _client.db.thing.count() == 1)

	sub_a.unsubscribe()
	await sub_a.end
	_check("G2: shared row survives first unsubscribe", _client.db.thing.count() == 1)
	_check("G2: no on_delete on first unsubscribe (got %d)" % _thing_deletes, _thing_deletes == 0)

	sub_b.unsubscribe()
	await sub_b.end
	_check("G2: row evicted after last unsubscribe", _client.db.thing.count() == 0)
	_check("G2: on_delete fired once on last unsubscribe (got %d)" % _thing_deletes, _thing_deletes == 1)

	# --- G3: event table fires on_insert but stores nothing ---
	var sub_e: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM event_log"])
	await sub_e.applied
	await _client.reducers.log_event("hello").wait_for_response(5.0)
	_check("G3: event-table insert fired (got %d)" % _event_inserts, _event_inserts == 1)
	_check("G3: event-table row not stored", _client.db.event_log.count() == 0)

	# --- TimeDuration column round-trips as int micros ---
	var sub_d: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM dur_row"])
	await sub_d.applied
	await _client.reducers.add_dur(1, 123456).wait_for_response(5.0)
	var dur_rows: Array = _client.db.dur_row.iter()
	_check("TimeDuration: row present", not dur_rows.is_empty())
	if not dur_rows.is_empty():
		_check("TimeDuration: micros round-trip (got %d)" % dur_rows[0].get(&"d"), dur_rows[0].get(&"d") == 123456)

	# --- default_values: auto_inc pk table still deserializes ---
	var sub_s: SpacetimeDBSubscription = _client.subscribe(["SELECT * FROM seq_row"])
	await sub_s.applied
	await _client.reducers.add_seq(7).wait_for_response(5.0)
	var seq_rows: Array = _client.db.seq_row.iter()
	_check("default_values: auto_inc row present", not seq_rows.is_empty())
	if not seq_rows.is_empty():
		_check("default_values: value intact (got %d)" % seq_rows[0].get(&"v"), seq_rows[0].get(&"v") == 7)
		_check("default_values: auto_inc pk assigned (>0)", seq_rows[0].get(&"id") > 0)

	# --- fallible reducer: Err surfaces as Outcome.ERROR + message ---
	var fc: SpacetimeDBReducerCall = _client.reducers.fail_reducer()
	await fc.wait_for_response(5.0)
	_check("fallible: outcome ERROR (got %d)" % fc.outcome, fc.outcome == SpacetimeDBReducerCall.Outcome.ERROR)
	_check("fallible: message carries error (%s)" % fc.error_message, fc.error_message.contains("intentional failure"))

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	_client.disconnect_db()
	quit(_fails)

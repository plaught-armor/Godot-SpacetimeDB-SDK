# The reconnect's SubscribeBatch and its answer, driven through the client.
#
# On a reconnect the client restores every saved handle with ONE SubscribeBatch and, when
# the SubscribeBatchApplied comes back, reconciles the mirror against it as one message,
# then emits `applied` per handle, ends the sets that failed, and emits `reconnected`.
# This file pins:
#   - the answer is checked against the request before anything is applied: a wrong
#     request id, a result count that differs from the sets sent, or a set id that was
#     not sent or repeats is a protocol violation and drops the socket;
#   - with nothing saved, the reconcile still runs and drops the old session's rows;
#   - a failed set ends its handle while the others apply;
#   - the watchdog completes the reconnect without the answer, and a late answer still
#     applies its rows without a second `reconnected`;
#   - game code run by the reconcile may subscribe, unsubscribe, disconnect or wipe the
#     mirror, and the reconcile neither breaks nor strands a handle.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_reconnect_reconcile.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const _A: int = 7
const _B: int = 8

var _total: int = 0
var _fails: int = 0
## Client and row events in order: "applied:<old qid>", "end:<old qid>", "reconnected",
## "ins:<id>", "upd:<id>", "del:<id>".
var _events: PackedStringArray = []
## Run once from the first delete callback, then cleared.
var _on_delete_hook: Callable = Callable()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_a_matching_answer_reconciles()
	_test_wrong_request_id_is_a_violation()
	_test_result_count_mismatch_is_a_violation()
	_test_unknown_set_is_a_violation()
	_test_repeated_set_is_a_violation()
	_test_an_answer_after_the_cycle_is_a_violation()
	_test_nothing_saved_still_reconciles()
	_test_a_failed_set_ends_only_its_handle()
	_test_watchdog_completes_and_a_late_answer_applies()
	_test_a_callback_can_subscribe()
	_test_an_applied_handler_can_unsubscribe_a_sibling()
	_test_a_callback_can_disconnect()
	_test_a_callback_can_wipe_the_mirror()
	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _test_a_matching_answer_reconciles() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	_answer(client, { _A: [_mk_row(1, 10), _mk_row(3, 30)] })
	_check_s(
		"match: only the change fires, then the handle, then reconnected",
		", ".join(_events),
		"ins:3, del:2, applied:7, reconnected",
	)
	_check_i("match: one batch sent", _conn(client).sent, 1)
	_check_i("match: handle is current again", client.current_subscriptions.size(), 1)
	_check_i("match: nothing pending", client.pending_subscriptions.size(), 0)
	_check_s("match: no violation", _conn(client).violation, "")
	_teardown(client)


func _test_wrong_request_id_is_a_violation() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	var message: SubscribeBatchAppliedMessage = _batch_answer(client, { _A: [] })
	message.request_id += 1
	client._handle_parsed_message(message)
	_check_violation("wrong id", client, "for request")
	_teardown(client)


func _test_result_count_mismatch_is_a_violation() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A, _B])
	var message: SubscribeBatchAppliedMessage = _batch_answer(client, { _A: [], _B: [] })
	message.results.pop_back()
	client._handle_parsed_message(message)
	_check_violation("count", client, "carries 1 results for 2 sets")
	_teardown(client)


func _test_unknown_set_is_a_violation() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	var message: SubscribeBatchAppliedMessage = _batch_answer(client, { _A: [] })
	message.results[0].query_set_id = 999
	client._handle_parsed_message(message)
	_check_violation("unknown set", client, "names query set 999")
	_teardown(client)


func _test_repeated_set_is_a_violation() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A, _B])
	var message: SubscribeBatchAppliedMessage = _batch_answer(client, { _A: [], _B: [] })
	message.results[1].query_set_id = message.results[0].query_set_id
	client._handle_parsed_message(message)
	_check_violation("repeat", client, "which was not sent or repeats")
	_teardown(client)


# The request is cleared once answered, so a second answer to it names no request.
func _test_an_answer_after_the_cycle_is_a_violation() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	var message: SubscribeBatchAppliedMessage = _batch_answer(client, { _A: [] })
	client._handle_parsed_message(message)
	_events.clear()
	client._handle_parsed_message(message)
	_check_b(
		"second answer: dropped",
		_conn(client).violation.contains("outstanding request is -1"),
		true,
	)
	_check_s("second answer: nothing fired", ", ".join(_events), "")
	_teardown(client)


func _test_nothing_saved_still_reconciles() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([])
	_check_i("nothing saved: nothing sent", _conn(client).sent, 0)
	_check_s(
		"nothing saved: old rows dropped, then reconnected",
		", ".join(_events),
		"del:1, del:2, reconnected",
	)
	_teardown(client)


func _test_a_failed_set_ends_only_its_handle() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A, _B])
	var b: SpacetimeDBSubscription = client._saved_subscriptions[1]
	_answer(client, { _A: [_mk_row(1, 10), _mk_row(2, 20)] }, { _B: "no such table" })
	_check_s(
		"failed set: A applies, B ends, then reconnected",
		", ".join(_events),
		"applied:7, end:8, reconnected",
	)
	_check_s("failed set: B carries the server's error", b.error_message, "no such table")
	_check_b("failed set: B ended", b.ended, true)
	_check_i("failed set: only A is current", client.current_subscriptions.size(), 1)
	_teardown(client)


func _test_watchdog_completes_and_a_late_answer_applies() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	var message: SubscribeBatchAppliedMessage = _batch_answer(client, { _A: [_mk_row(1, 10)] })
	client._on_resubscribe_watchdog(client._resubscribe_epoch)
	_check_s(
		"watchdog: rows dropped, reconnected without the answer",
		", ".join(_events),
		"del:1, del:2, reconnected",
	)
	_check_i("watchdog: handle still waiting", client.pending_subscriptions.size(), 1)
	_events.clear()
	client._handle_parsed_message(message)
	_check_s(
		"late answer: rows and handle, no second reconnected",
		", ".join(_events),
		"ins:1, applied:7",
	)
	_check_s("late answer: accepted", _conn(client).violation, "")
	_teardown(client)


func _test_a_callback_can_subscribe() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	var fresh: Array[SpacetimeDBSubscription] = []
	_on_delete_hook = func() -> void:
		fresh.append(client.subscribe(PackedStringArray(["SELECT * FROM tbl"])))
	_answer(client, { _A: [_mk_row(1, 10)] })
	_check_s(
		"subscribe in delete: cycle completes",
		", ".join(_events),
		"del:2, applied:7, reconnected",
	)
	_check_i("subscribe in delete: its Subscribe went out", _conn(client).sent, 2)
	_check_b(
		"subscribe in delete: new handle pending",
		fresh.size() == 1 and client.pending_subscriptions.values().has(fresh[0]),
		true,
	)
	_teardown(client)


# Unsubscribing a sibling still pending when the first `applied` runs: it is not reported
# applied afterwards, and its Unsubscribe goes out for a set the server did take.
func _test_an_applied_handler_can_unsubscribe_a_sibling() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A, _B])
	var a: SpacetimeDBSubscription = client._saved_subscriptions[0]
	var b: SpacetimeDBSubscription = client._saved_subscriptions[1]
	var result: PackedInt64Array = [-1]
	a.applied.connect(
		func() -> void:
			result[0] = b.unsubscribe(),
		CONNECT_ONE_SHOT,
	)
	_answer(client, { _A: [_mk_row(1, 10), _mk_row(2, 20)], _B: [] })
	_check_i("unsubscribe sibling: accepted", result[0], OK)
	_check_i("unsubscribe sibling: its Unsubscribe went out", _conn(client).sent, 2)
	_check_b("unsubscribe sibling: reconnected still fires", _events.has("reconnected"), true)
	_check_i("unsubscribe sibling: applied once each at most", _events.count("applied:8"), 1)
	_teardown(client)


# disconnect_db from a row callback ends the session: no handle is reported applied and
# no `reconnected` goes out on top of it.
func _test_a_callback_can_disconnect() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	_on_delete_hook = func() -> void:
		client.disconnect_db()
	_answer(client, { _A: [_mk_row(1, 10)] })
	_check_b("disconnect in delete: no applied", _events.has("applied:7"), false)
	_check_b("disconnect in delete: no reconnected", _events.has("reconnected"), false)
	_teardown(client)


# A game that wipes its mirror from a row callback has not ended the session: the sets
# are live on the server, so the handles settle and `reconnected` fires.
func _test_a_callback_can_wipe_the_mirror() -> void:
	var client: SpacetimeDBClient = _reconnecting_client([_A])
	_on_delete_hook = func() -> void:
		client._local_db.clear_local_db()
	_answer(client, { _A: [_mk_row(1, 10)] })
	_check_s(
		"wipe in delete: row 1 reported by the wipe",
		", ".join(_events),
		"del:2, del:1, applied:7, reconnected",
	)
	_check_i("wipe in delete: nothing stranded pending", client.pending_subscriptions.size(), 0)
	_teardown(client)


# A client mid-reconnect, past the new socket's IdentityToken: rows 1 and 2 cached under
# the dead session, one live handle per entry of [param query_ids], and the SubscribeBatch
# sent (none when the list is empty). Events recorded from here on.
func _reconnecting_client(query_ids: PackedInt64Array) -> SpacetimeDBClient:
	_events.clear()
	_on_delete_hook = Callable()
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	client.debug_mode = false
	client.use_threading = false
	root.add_child(client)
	client._is_initialized = true
	client._serializer = BSATNSerializer.new(false)
	client._connection = _FakeConn.new()
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = true
	options.reconnect_initial_delay = 600.0
	options.reconnect_max_delay = 600.0
	options.reconnect_jitter_fraction = 0.0
	client.connection_options = options
	client._local_db = _mk_db()
	client._local_db.apply_table_update(_mk_update([_mk_row(1, 10), _mk_row(2, 20)]), 0)
	client._received_initial_subscription = true
	_events.clear()
	for query_id: int in query_ids:
		var sub: SpacetimeDBSubscription = SpacetimeDBSubscription.create(
			client,
			query_id,
			PackedStringArray(["SELECT * FROM tbl WHERE id = %d" % query_id]),
		)
		client.current_subscriptions[query_id] = sub
		client._next_query_id = maxi(client._next_query_id, query_id + 1)
		sub.applied.emit()
		sub.applied.connect(
			func() -> void:
				_events.append("applied:%d" % query_id),
		)
		sub.end.connect(
			func() -> void:
				_events.append("end:%d" % query_id),
		)
	client.reconnected.connect(
		func() -> void:
			_events.append("reconnected"),
	)
	client._start_reconnection()
	client._prepare_for_reconnect()
	# What the IdentityToken handler does once the new socket is up.
	client._reconnect_state = SpacetimeDBClient._ReconnectState.IDLE
	client._reconnect_attempt = 0
	client._resubscribe_saved_queries()
	return client


# The server's answer to the outstanding batch. [param rows] and [param errors] are keyed
# by the handle's query id from before the drop; each saved handle appears in one of them.
func _batch_answer(
	client: SpacetimeDBClient,
	rows: Dictionary,
	errors: Dictionary = { },
) -> SubscribeBatchAppliedMessage:
	var message: SubscribeBatchAppliedMessage = SubscribeBatchAppliedMessage.new()
	message.request_id = client._resubscribe_request_id
	var old_ids: Array = rows.keys() + errors.keys()
	old_ids.sort()
	var new_ids: Array = client._resubscribe_sets.keys()
	new_ids.sort()
	for k: int in mini(old_ids.size(), new_ids.size()):
		var result: SubscribeSetResultData = SubscribeSetResultData.new()
		result.query_set_id = new_ids[k]
		if errors.has(old_ids[k]):
			result.is_error = true
			result.error_message = errors[old_ids[k]]
		else:
			result.tables.append(_mk_update(rows[old_ids[k]]))
		message.results.append(result)
	return message


func _answer(client: SpacetimeDBClient, rows: Dictionary, errors: Dictionary = { }) -> void:
	client._handle_parsed_message(_batch_answer(client, rows, errors))


func _check_violation(label: String, client: SpacetimeDBClient, fragment: String) -> void:
	var violation: String = _conn(client).violation
	_check_b(
		"%s: socket dropped as a protocol violation" % label,
		violation.contains(fragment),
		true,
	)
	_check_s("%s: nothing applied or reported" % label, ", ".join(_events), "")
	_check_i("%s: rows untouched" % label, client._local_db._tables[&"tbl"].size(), 2)


func _conn(client: SpacetimeDBClient) -> _FakeConn:
	return client._connection as _FakeConn


func _teardown(client: SpacetimeDBClient) -> void:
	var db: LocalDatabase = client._local_db
	var conn: _FakeConn = _conn(client)
	root.remove_child(client)
	client.free()
	db.free()
	conn.free()


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"tbl"]
	schema.types[&"tbl"] = _PkRow
	schema.tables[&"tbl"] = _PkRow
	var db: LocalDatabase = LocalDatabase.new(schema)
	db.subscribe_to_inserts(
		&"tbl",
		func(row: _ModuleTableType) -> void:
			_events.append("ins:%d" % row.id),
	)
	db.subscribe_to_updates(
		&"tbl",
		func(_old: _ModuleTableType, row: _ModuleTableType) -> void:
			_events.append("upd:%d" % row.id),
	)
	db.subscribe_to_deletes(&"tbl", _on_delete)
	return db


func _on_delete(row: _ModuleTableType) -> void:
	_events.append("del:%d" % row.id)
	if _on_delete_hook.is_valid():
		var hook: Callable = _on_delete_hook
		_on_delete_hook = Callable()
		hook.call()


func _mk_row(id_val: int, v: int) -> _PkRow:
	var r: _PkRow = _PkRow.new()
	r.id = id_val
	r.val = v
	return r


func _mk_update(inserts: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = &"tbl"
	u.inserts.assign(inserts)
	u.is_event = false
	return u


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got %d want %d" % [label, got, want])


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got %s want %s" % [label, got, want])


func _check_s(label: String, got: String, want: String) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return
	_fails += 1
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])


# Exported columns, as a generated row has them: the mirror compares rows by their
# storage properties.
class _PkRow:
	extends _ModuleTableType

	const PRIMARY_KEY: StringName = &"id"

	@export var id: int = 0
	@export var val: int = 0


# Reports a live socket, counts sends, and records a protocol-violation drop instead of
# resetting a peer it does not have. Skips the parent _init.
class _FakeConn:
	extends SpacetimeDBConnection

	var sent: int = 0
	var violation: String = ""
	var live: bool = true


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return live


	func is_websocket_active() -> bool:
		return live


	func send_bytes(_bytes: PackedByteArray) -> Error:
		sent += 1
		return OK


	func set_token(_token: String) -> void:
		pass


	func disconnect_from_server(_code: int = 1000, _reason: String = "") -> void:
		live = false


	func abort_protocol_violation(reason: String) -> void:
		violation = reason
		live = false

# Regression test for what a second session inherits from the first one.
#
# The auto-reconnect path clears the mirror in _prepare_for_reconnect() and reports every
# cached row as deleted, because the resubscribe only re-delivers what still exists. The
# manual cycle — disconnect_db() now, connect_db() later on the same client — did none of
# that, so the next session started on top of the last one's rows:
#
#   - every re-delivered row came back at refcount 2, so unsubscribing that session's
#     query dropped it to 1 instead of evicting it,
#   - a row deleted server-side while the client was away stayed cached for good, with no
#     on_delete to tell anyone,
#   - _received_initial_subscription was still true, so `database_initialized` never fired
#     for the second session and anything awaiting it waited forever.
#
# disconnect_db() still leaves the rows alone — reading last-known state while offline is
# the reason it does — so the reset belongs at the start of the next session, not the end
# of the last one. connect_db() on a client that is still connected is a reconfigure, not
# a new session, and must not wipe anything.
#
# The client is built with SpacetimeDBClient.new() and never added to the tree; the
# connection is a stub, so connect_db() runs end to end without a socket.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_manual_reconnect_session.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const PkRow: GDScript = preload("res://tests/_test_pk_row.gd")

var _total: int = 0
var _deleted_ids: PackedInt64Array = []


func _initialize() -> void:
	var fails: int = 0
	fails += _test_new_session_starts_clean()
	fails += _test_reconfigure_while_connected_keeps_the_mirror()
	fails += _test_listener_disconnect_during_the_wipe_wins()
	fails += _test_listener_connect_during_the_wipe_wins()
	fails += _test_wipe_is_a_no_op_mid_handshake()
	fails += _test_new_session_drops_the_old_session_traffic()

	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _test_new_session_starts_clean() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client(false)
	var db: LocalDatabase = client._local_db
	db.subscribe_to_deletes(&"tbl", _on_delete)

	# Session one: query 0 delivers two rows, and the first SubscribeApplied has already
	# announced the database.
	db.apply_table_update(_mk_update(&"tbl", [_row(1), _row(2)], []), 0)
	client._received_initial_subscription = true
	f += _check_i("setup: rows cached", db._tables[&"tbl"].size(), 2)

	client.disconnect_db()
	f += _check_i("disconnect_db keeps the mirror readable", db._tables[&"tbl"].size(), 2)
	f += _check_i("nothing reported deleted yet", _deleted_ids.size(), 0)

	client.connect_db("http://localhost:3000", "test_mod", _mk_options())
	f += _check_i("new session wipes the mirror", db._tables[&"tbl"].size(), 0)
	f += _check_i("both rows reported deleted", _deleted_ids.size(), 2)
	f += _check_i("refcounts dropped", db._ref_counts.get(&"tbl", { }).size(), 0)
	f += _check_b(
		"database_initialized can fire again",
		client._received_initial_subscription,
		false,
	)

	# Session two re-delivers only row 1 (row 2 was deleted server-side while away). It
	# must come back at refcount 1, so this session's own unsubscribe can evict it.
	db.apply_table_update(_mk_update(&"tbl", [_row(1)], []), 1)
	f += _check_i("re-delivered row is held once", db._ref_counts[&"tbl"].get(1, 0), 1)
	db.prune_query(1)
	f += _check_i("its query's unsubscribe evicts it", db._tables[&"tbl"].size(), 0)

	client.free()
	db.free()
	return f


# connect_db() on a live connection is how options get replaced mid-session; it is not a
# session boundary and must leave the cache and the initialized flag alone.
func _test_reconfigure_while_connected_keeps_the_mirror() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client(true)
	var db: LocalDatabase = client._local_db

	db.apply_table_update(_mk_update(&"tbl", [_row(1), _row(2)], []), 0)
	client._received_initial_subscription = true

	client.connect_db("http://localhost:3000", "test_mod", _mk_options())
	f += _check_i("connected reconfigure keeps the rows", db._tables[&"tbl"].size(), 2)
	f += _check_b(
		"and does not re-arm database_initialized",
		client._received_initial_subscription,
		true,
	)

	client.free()
	db.free()
	return f


# The wipe reports every row as deleted, which is game code. A listener that calls
# disconnect_db() from there has countermanded the connect: it must not open a socket.
func _test_listener_disconnect_during_the_wipe_wins() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client(false)
	var db: LocalDatabase = client._local_db
	var conn: _FakeConn = client._connection
	db.apply_table_update(_mk_update(&"tbl", [_row(1)], []), 0)
	db.subscribe_to_deletes(
		&"tbl",
		func(_row_arg: _ModuleTableType) -> void:
			client.disconnect_db(),
	)

	client.connect_db("http://localhost:3000", "test_mod", _mk_options())
	f += _check_i("no socket opened against the listener's disconnect", conn.connect_calls, 0)
	f += _check_i("the wipe still happened", db._tables[&"tbl"].size(), 0)

	client.free()
	db.free()
	return f


# Same shape, but the listener starts its own session. The newer call's host must survive:
# the outer call has been superseded and must not write its own over it.
func _test_listener_connect_during_the_wipe_wins() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client(false)
	var db: LocalDatabase = client._local_db
	var conn: _FakeConn = client._connection
	db.apply_table_update(_mk_update(&"tbl", [_row(1)], []), 0)
	# One shot: the nested call wipes too, and an unguarded listener would recurse.
	var fired: Array[bool] = [false] # gdlint: ignore[S6]
	db.subscribe_to_deletes(
		&"tbl",
		func(_row_arg: _ModuleTableType) -> void:
			if fired[0]:
				return
			fired[0] = true
			client.connect_db("http://inner:3000", "inner_mod", _mk_options()),
	)

	client.connect_db("http://outer:3000", "outer_mod", _mk_options())
	f += _check_i("only the inner call connected", conn.connect_calls, 1)
	f += _check_s("inner host kept", client.base_url, "http://inner:3000")
	f += _check_s("inner database kept", client.database_name, "inner_mod")

	client.free()
	db.free()
	return f


# Mid-handshake there is nothing cached yet (no server data has arrived), so the wipe is a
# no-op rather than something that has to be suppressed.
func _test_wipe_is_a_no_op_mid_handshake() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client(false)
	var db: LocalDatabase = client._local_db
	var conn: _FakeConn = client._connection
	conn.handshaking = true # socket alive, not yet OPEN
	client.connect_db("http://localhost:3000", "test_mod", _mk_options())
	f += _check_i("mid-handshake connect still proceeds", conn.connect_calls, 1)
	f += _check_i("nothing to report deleted", _deleted_ids.size(), 0)

	client.free()
	db.free()
	return f


# Wiping the rows is only half the boundary. Messages the dying session already parsed,
# the batch a frame was midway through draining, and the half-message left in the framing
# buffer all belong to the old session too — drained or parsed after the wipe, they would
# land in the mirror the new session is about to fill. The auto-reconnect path has always
# dropped them; the manual one has to as well.
func _test_new_session_drops_the_old_session_traffic() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client(false)
	var db: LocalDatabase = client._local_db
	client.use_threading = false
	client._deserializer = BSATNDeserializer.new(null, false)

	# Half a message: a tag byte the parser recognises with fewer bytes behind it than the
	# message needs, which is what a socket dying mid-frame leaves behind.
	var truncated: PackedByteArray = [SpacetimeDBServerMessage.Type.INITIAL_CONNECTION, 0x01]
	client._deserializer.process_bytes_and_extract_messages(truncated)
	client._deserializer.clear_error()
	client._result_queue.append(SubscribeAppliedMessage.new())
	client._drain_batch = [SubscribeAppliedMessage.new()]
	client._drain_cursor = 0
	f += _check_b(
		"setup: parser holds a prefix",
		not client._deserializer._pending_data.is_empty(),
		true,
	)

	client.disconnect_db()
	client.connect_db("http://localhost:3000", "test_mod", _mk_options())

	f += _check_i("parsed-but-undrained results dropped", client._result_queue.size(), 0)
	f += _check_i("in-flight drain batch dropped", client._drain_batch.size(), 0)
	f += _check_i("drain cursor reset", client._drain_cursor, 0)
	f += _check_b("framing buffer reset", client._deserializer._pending_data.is_empty(), true)

	client.free()
	db.free()
	return f


func _on_delete(row: _ModuleTableType) -> void:
	_deleted_ids.append(row.get(&"id"))


# An initialized client whose socket is a stub. [param connected] decides which branch of
# connect_db is taken: a live session (reconfigure) or a closed one (new session).
func _mk_client(connected: bool) -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var conn: _FakeConn = _FakeConn.new()
	conn.is_live = connected
	client._connection = conn
	client._rest_api = _FakeRest.new()
	client._local_db = _mk_db()
	client._is_initialized = true
	client._token = "header.payload.signature" # non-empty, so no REST token request
	client.save_token = false # nothing written to disk
	_deleted_ids.clear()
	return client


func _mk_db() -> LocalDatabase:
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	schema.raw_table_names = [&"tbl"]
	schema.types[&"tbl"] = PkRow
	schema.tables[&"tbl"] = PkRow
	return LocalDatabase.new(schema)


func _mk_options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.save_token = false
	options.threading = false
	options.auto_reconnect = false
	return options


func _row(id: int) -> Resource:
	var r: Resource = PkRow.new()
	r.set(&"id", id)
	return r


func _mk_update(table_name: StringName, inserts: Array, deletes: Array) -> TableUpdateData:
	var u: TableUpdateData = TableUpdateData.new()
	u.table_name = table_name
	var ins: Array[Resource] = []
	ins.assign(inserts)
	var del: Array[Resource] = []
	del.assign(deletes)
	u.inserts = ins
	u.deletes = del
	return u


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


# Reports whichever socket state the case needs and swallows the connect attempt. Skips
# the parent _init, which wants options and a database name this test never uses.
class _FakeConn:
	extends SpacetimeDBConnection

	var is_live: bool = false
	## Socket alive but not yet OPEN — is_connected_db() is false, is_websocket_active() true.
	var handshaking: bool = false
	var connect_calls: int = 0


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return is_live


	func is_websocket_active() -> bool:
		return is_live or handshaking


	func set_token(_token: String) -> void:
		pass


	func apply_options(_options: SpacetimeDBConnectionOptions) -> void:
		pass


	func disconnect_from_server(_code: int = 1000, _reason: String = "") -> void:
		is_live = false


	func connect_to_database(_url: String, _db_name: String, _conn_id: String) -> void:
		connect_calls += 1


# The REST client only has its token handed to it here; nothing is requested.
class _FakeRest:
	extends SpacetimeDBRestAPI

	func _init() -> void:
		pass


	func set_token(_token: String) -> void:
		pass

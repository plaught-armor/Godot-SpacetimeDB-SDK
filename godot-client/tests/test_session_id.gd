# Unit test for the client's logical session id (SpacetimeDB 2.10.2+ `session_id` query
# parameter). The server keys a session on (database, identity, session id) and refuses
# a second live socket for the same key with close code 4000, so a reconnect cannot
# overlap the connection it replaces. The id has to follow the official SDKs' rules:
#
#   - drawn per connect_db(): a fresh session gets a fresh id;
#   - drawn too by an initialize_and_connect() that connect_db did not call (auto_connect
#     from _ready, or a direct call), so that path is resumable as well;
#   - ended by disconnect_db(), so the next session cannot reuse it whichever way it
#     starts;
#   - kept across that session's automatic reconnects (while the per-attempt
#     connection id still changes on every socket);
#   - 128 bits as 32 hex characters, the only spelling the server parses;
#   - sent only while auto_reconnect is on (TS db_connection_impl.ts:667).
#
# The connection is a stub that records what each socket open was given, so connect_db
# and _attempt_reconnect run end to end without a socket. The client is never added to
# the tree, so _ready never runs.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_session_id.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_session_id_lifecycle()
	f += _test_no_session_id_without_auto_reconnect()
	f += _test_direct_initialize_draws_session_id()
	f += _test_disconnect_ends_session_id()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_session_id_lifecycle() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = _mk_client()
	var conn: _RecordingConn = client._connection

	client.connect_db("http://localhost:3000", "test_mod", _mk_options(true))
	f += _check_i("first connect opened one socket", conn.session_ids.size(), 1)
	if conn.session_ids.is_empty():
		client.free()
		return f
	var first: String = conn.session_ids[0]
	f += _check_i("32 characters", first.length(), 32)
	f += _check_b("hex only", first.is_valid_hex_number(false), true)

	# An automatic reconnect of the same session.
	client._reconnect_state = SpacetimeDBClient._ReconnectState.RECONNECTING
	client._attempt_reconnect()
	f += _check_i("reconnect opened a second socket", conn.session_ids.size(), 2)
	if conn.session_ids.size() == 2:
		f += _check_s("reconnect keeps the session id", conn.session_ids[1], first)
		f += _check_b(
			"reconnect still draws a new connection id",
			conn.connection_ids[1] != conn.connection_ids[0],
			true,
		)

	# The game ends the session and starts another on the same client object.
	client._reconnect_state = SpacetimeDBClient._ReconnectState.IDLE
	client.disconnect_db()
	client._token = "header.payload.signature" # disconnect_db drops the token
	client.connect_db("http://localhost:3000", "test_mod", _mk_options(true))
	f += _check_i("fresh connect_db opened a third socket", conn.session_ids.size(), 3)
	if conn.session_ids.size() == 3:
		f += _check_b("fresh connect_db draws a new id", conn.session_ids[2] != first, true)
		f += _check_i("new id is 32 characters too", conn.session_ids[2].length(), 32)

	client.free()
	return f


# A client that never reconnects never claims a server session, so the parameter is
# left off and the server behaves as it does for any pre-2.10.2 client.
func _test_no_session_id_without_auto_reconnect() -> int:
	var client: SpacetimeDBClient = _mk_client()
	var conn: _RecordingConn = client._connection
	client.connect_db("http://localhost:3000", "test_mod", _mk_options(false))
	var f: int = _check_i("connect opened one socket", conn.session_ids.size(), 1)
	if not conn.session_ids.is_empty():
		f += _check_s("no session id sent", conn.session_ids[0], "")
	client.free()
	return f


# auto_connect and a direct initialize_and_connect() never pass through connect_db, which is
# where the id used to be drawn. The token load is stubbed out, so nothing connects until the
# test swaps in the recording connection and runs a reconnect attempt.
func _test_direct_initialize_draws_session_id() -> int:
	var client: _DirectClient = _DirectClient.new()
	client.module_name = "test_mod"
	client.schema_path = "res://__no_schema__"
	client.database_name = "test_mod"
	client.save_token = false
	client.use_threading = false # no worker to join before the free
	client.connection_options = _mk_options(true)
	client.initialize_and_connect()
	var drawn: String = client._session_id
	var f: int = _check_i("direct initialize draws a 32-character id", drawn.length(), 32)
	f += _check_s("and the socket is given it", client._socket_session_id(), drawn)

	var real_conn: SpacetimeDBConnection = client._connection
	client.remove_child(real_conn)
	real_conn.free()
	var conn: _RecordingConn = _RecordingConn.new()
	client._connection = conn
	client._token = "header.payload.signature"
	client._reconnect_state = SpacetimeDBClient._ReconnectState.RECONNECTING
	client._attempt_reconnect()
	f += _check_i("the reconnect opened a socket", conn.session_ids.size(), 1)
	if not conn.session_ids.is_empty():
		f += _check_s("the reconnect keeps the id", conn.session_ids[0], drawn)
	client.free()
	conn.free()
	return f


# disconnect_db ends the session the id names. A direct initialize_and_connect() only draws
# an id when it has none, so an id left behind would be claimed again by the next session:
# the server would treat it as a resume of the one the game just ended. The leftover id
# here stands in for a first initialize that drew its id and then failed before finishing.
func _test_disconnect_ends_session_id() -> int:
	var client: _DirectClient = _DirectClient.new()
	client.module_name = "test_mod"
	client.schema_path = "res://__no_schema__"
	client.database_name = "test_mod"
	client.save_token = false
	client.use_threading = false # no worker to join before the free
	client.connection_options = _mk_options(true)
	var leftover: String = "0123456789abcdef0123456789abcdef"
	client._session_id = leftover
	client.disconnect_db()
	var f: int = _check_s("disconnect_db clears the id", client._session_id, "")
	client.initialize_and_connect()
	f += _check_b("the next session draws a new id", client._session_id != leftover, true)
	f += _check_i("and it is 32 characters", client._session_id.length(), 32)
	client.free()
	return f


func _mk_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client._connection = _RecordingConn.new()
	client._rest_api = _FakeRest.new()
	var schema: SpacetimeDBSchema = SpacetimeDBSchema.new("test_mod", "res://__no_schema__", false)
	client._local_db = LocalDatabase.new(schema)
	client._is_initialized = true
	client._token = "header.payload.signature" # non-empty, so no REST token request
	client.save_token = false
	return client


func _mk_options(auto_reconnect: bool) -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.save_token = false
	options.threading = false
	options.auto_reconnect = auto_reconnect
	return options


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
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


# Never live, so every connect_db is a new session; records each socket open's ids.
# Skips the parent _init, which wants options and a database name this test never uses.
class _RecordingConn:
	extends SpacetimeDBConnection

	var session_ids: PackedStringArray = []
	var connection_ids: PackedStringArray = []


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return false


	func is_websocket_active() -> bool:
		return false


	func set_token(_token: String) -> void:
		pass


	func apply_options(_options: SpacetimeDBConnectionOptions) -> void:
		pass


	func disconnect_from_server(_code: int = 1000, _reason: String = "") -> void:
		pass


	func connect_to_database(
		_url: String,
		_db_name: String,
		connection_id: String,
		session_id: String = "",
	) -> void:
		connection_ids.append(connection_id)
		session_ids.append(session_id)


# The REST client only has its token handed to it here; nothing is requested.
class _FakeRest:
	extends SpacetimeDBRestAPI

	func _init() -> void:
		pass


	func set_token(_token: String) -> void:
		pass


# A client whose token load does nothing, so initialize_and_connect builds everything and
# opens no socket.
class _DirectClient:
	extends SpacetimeDBClient

	func _load_token_or_request() -> void:
		pass

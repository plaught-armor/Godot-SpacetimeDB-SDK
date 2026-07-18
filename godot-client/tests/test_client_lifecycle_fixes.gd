# Regression tests for four Section-2 client/connection fixes. All run tree-less
# (SpacetimeDBClient.new() without add_child, so _ready / threads / real sockets
# never start) by driving the handlers directly and inspecting state + signals.
#
#   1. HIGH — _on_connection_disconnected must advance the reconnect machine when a
#      graceful server close lands during a reconnect attempt (state RECONNECTING),
#      instead of _start_reconnection() early-returning and wedging forever.
#   2. HIGH — disconnect_db() must close a socket that is live but not yet OPEN
#      (mid-handshake): is_connected_db() misses STATE_CONNECTING, so the old code
#      left the handshake running. Must call disconnect_from_server + emit
#      disconnected once + clear the intentional flag.
#   3. HIGH — SpacetimeDBReducerCall/ProcedureCall.decode() must use the client's
#      main-thread _decode_deserializer, NOT the worker's _deserializer (thread race).
#   4. MEDIUM — SpacetimeDBRestAPI must set a finite HTTPRequest.timeout (default 0
#      = infinite hang on a silent server).
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_client_lifecycle_fixes.gd
extends SceneTree

var _total: int = 0
var _disconnected_count: int = 0
var _reconnect_failed_count: int = 0
var _connected_count: int = 0
var _token_failed_count: int = 0


# A SpacetimeDBConnection stand-in that reports a live (mid-handshake) socket
# without opening one. Skips the parent _init (needs options/db_name we don't use).
class _FakeConn:
	extends SpacetimeDBConnection
	var closed: bool = false
	var _active: bool = true


	func _init() -> void:
		pass


	func is_websocket_active() -> bool:
		return _active


	func is_connected_db() -> bool:
		return false # not yet OPEN — the STATE_CONNECTING case


	func disconnect_from_server(_code: int = 1000, _reason: String = "") -> void:
		closed = true
		_active = false


func _initialize() -> void:
	var f: int = 0
	f += _test_reconnect_disconnect_advances()
	f += _test_disconnect_db_closes_handshake_socket()
	f += _test_late_identity_token_does_not_restore_wiped_token()
	f += _test_decode_uses_separate_deserializer()
	f += _test_rest_api_sets_timeout()
	f += _test_rest_timeout_routes_to_failure()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


# HIGH 1: graceful close during a reconnect attempt advances the machine. Drive
# the exhausted branch (attempt == max) so the assertion needs no SceneTreeTimer:
# the fix routes to _schedule_next_reconnect_attempt → IDLE + reconnect_failed +
# disconnected. The pre-fix bug routed to _start_reconnection → early-return →
# state stuck RECONNECTING, no signals.
func _test_reconnect_disconnect_advances() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.connection_options = SpacetimeDBConnectionOptions.new()
	client.connection_options.auto_reconnect = true
	client.connection_options.max_reconnect_attempts = 1
	client._reconnect_state = SpacetimeDBClient._ReconnectState.RECONNECTING
	client._reconnect_attempt = 1 # already at max → exhausted path, no timer armed
	_reconnect_failed_count = 0
	_disconnected_count = 0
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.disconnected.connect(_on_disconnected)

	client._on_connection_disconnected() # unintentional (flag stays false)
	f += _check_b(
		"reconnect-close: state left RECONNECTING",
		client._reconnect_state == SpacetimeDBClient._ReconnectState.IDLE,
		true,
	)
	f += _check_i("reconnect-close: reconnect_failed once", _reconnect_failed_count, 1)
	f += _check_i("reconnect-close: disconnected once", _disconnected_count, 1)

	client.reconnect_failed.disconnect(_on_reconnect_failed)
	client.disconnected.disconnect(_on_disconnected)
	client.free()
	return f


# HIGH 2: disconnect_db() closes a mid-handshake socket + emits disconnected once.
func _test_disconnect_db_closes_handshake_socket() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var conn: _FakeConn = _FakeConn.new()
	client._connection = conn
	_disconnected_count = 0
	client.disconnected.connect(_on_disconnected)

	client.disconnect_db()

	f += _check_b("disconnect mid-handshake: socket closed", conn.closed, true)
	f += _check_i("disconnect mid-handshake: disconnected once", _disconnected_count, 1)
	f += _check_b(
		"disconnect mid-handshake: intentional flag cleared",
		client._intentional_disconnect,
		false,
	)

	client.disconnected.disconnect(_on_disconnected)
	client.free()
	conn.free()
	return f


# HIGH 2b: a late IdentityToken for a torn-down handshake must be a full no-op —
# in particular it must NOT restore the _token that disconnect_db wiped, and must
# not emit connected. Guard is hoisted above the mutations for exactly this.
func _test_late_identity_token_does_not_restore_wiped_token() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	var conn: _FakeConn = _FakeConn.new()
	conn._active = false # torn down; is_connected_db() returns false
	client._connection = conn
	client._token = "" # disconnect_db() wiped it to force a fresh token next connect
	_connected_count = 0
	client.connected.connect(_on_connected)

	var msg: IdentityTokenMessage = IdentityTokenMessage.new()
	msg.token = "stale-token"
	msg.identity = PackedByteArray([1, 2, 3])
	msg.connection_id = PackedByteArray([4, 5, 6])
	client._handle_parsed_message(msg)

	f += _check_b("late token: _token NOT restored", client._token.is_empty(), true)
	f += _check_i("late token: connected NOT emitted", _connected_count, 0)

	client.connected.disconnect(_on_connected)
	client.free()
	conn.free()
	return f


# HIGH 3: decode() must go through _decode_deserializer. Null out the worker's
# _deserializer — if decode() still touched it the call would crash.
func _test_decode_uses_separate_deserializer() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client._decode_deserializer = BSATNDeserializer.new(null, false)
	client._deserializer = null # prove decode() never touches the worker instance

	var w: StreamPeerBuffer = StreamPeerBuffer.new()
	w.big_endian = false
	w.put_u32(42)

	var call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(client, 1, &"u32")
	call.ret_value = w.data_array
	var decoded: Variant = call.decode()
	f += _check_i("decode uses _decode_deserializer (u32=42)", int(decoded), 42)

	client.free()
	return f


# MEDIUM: REST client sets a finite request timeout.
func _test_rest_api_sets_timeout() -> int:
	var f: int = 0
	var api: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:3000", false)
	f += _check_b(
		"rest api timeout is finite and > 0",
		api._http_request.timeout == SpacetimeDBRestAPI.REQUEST_TIMEOUT_SECONDS
		and api._http_request.timeout > 0.0,
		true,
	)
	api.free()
	return f


# MEDIUM: a RESULT_TIMEOUT completion must route through token_request_failed and
# reset _pending_request_type so later requests aren't wedged.
func _test_rest_timeout_routes_to_failure() -> int:
	var f: int = 0
	var api: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:3000", false)
	api._pending_request_type = SpacetimeDBRestAPI.RequestType.TOKEN # simulate in-flight token fetch
	_token_failed_count = 0
	api.token_request_failed.connect(_on_token_failed)

	api._on_request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())

	f += _check_i("rest timeout: token_request_failed fired", _token_failed_count, 1)
	f += _check_b(
		"rest timeout: pending type reset",
		api._pending_request_type == SpacetimeDBRestAPI.RequestType.NONE,
		true,
	)

	api.token_request_failed.disconnect(_on_token_failed)
	api.free()
	return f


func _on_connected(_identity: PackedByteArray, _token: String) -> void:
	_connected_count += 1


func _on_token_failed(_error_code: int, _response_body: String) -> void:
	_token_failed_count += 1


func _on_disconnected() -> void:
	_disconnected_count += 1


func _on_reconnect_failed() -> void:
	_reconnect_failed_count += 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1

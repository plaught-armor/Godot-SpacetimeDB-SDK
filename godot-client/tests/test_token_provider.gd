# Unit test for SpacetimeDBConnectionOptions.token_provider.
#
# 1. token_claims decodes a JWT's payload, and answers empty for anything that is not one.
# 2. token_needs_refresh: refresh when exp is less than max(30 s, 5% of exp - iat) away, is
#    past, or is missing.
# 3. A reconnect attempt whose token is near expiry asks the provider (awaited, so it may be
#    a coroutine) and connects with what it returns; a token far from expiry is used as is.
# 4. A provider that returns an empty token, a non-String, or whose object was freed ends
#    the cycle: connection_error (ERR_UNAUTHORIZED), reconnect_failed, disconnected, and no
#    connect.
# 5. No provider: the attempt connects with the token it has, expired or not.
# 6. A cycle cancelled while the provider is still working does not connect.
# 7. A result that arrives after its attempt was superseded is dropped: a disconnect_db made
#    during the await keeps the token wiped (in memory and on disk) and hears no error, and
#    a connect_db made during it keeps the newer session's token.
#
# Driven through the real reconnect path with a stub connection. The client is in the tree
# because the reconnect scheduler needs get_tree(); its delays are long enough that no
# timer fires before the test ends, so each attempt is run by calling _attempt_reconnect.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_token_provider.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const _DELAY: float = 600.0
const _FRESH_TOKEN: String = "fresh.token.value"
const _HOUR: float = 3600.0
const _ACCOUNT_B: String = "account.b.token"

var _total: int = 0
var _provider_calls: int = 0
var _provider_result: Variant = _FRESH_TOKEN
var _provider_gate: bool = false
var _errors: PackedInt32Array = []
var _reconnect_failed_count: int = 0
var _disconnected_count: int = 0

signal _gate_opened


func _initialize() -> void:
	var f: int = 0
	f += _test_claims_decode()
	f += _test_margin_rule()
	f += await _test_provider_called()
	f += await _test_provider_fails()
	f += await _test_no_provider()
	f += await _test_cancelled_during_provider()
	f += await _test_stale_result_dropped()
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_claims_decode() -> int:
	var f: int = 0
	var claims: Dictionary = SpacetimeDBClient.token_claims(
		_jwt({ "exp": 1700000000, "iat": 1699996400 })
	)
	f += _check_b("exp decoded", float(claims.get("exp", 0)) == 1700000000.0, true)
	f += _check_b("iat decoded", float(claims.get("iat", 0)) == 1699996400.0, true)
	# Six '~' bytes hold an aligned 0x7E7E7E, which base64 writes as "fn5+" and base64url as
	# "fn5-": the payload cannot decode unless the URL alphabet is mapped back.
	var url_token: String = _jwt({ "sub": "~~~~~~" })
	f += _check_b("the payload uses the URL alphabet", url_token.contains("-"), true)
	f += _check_b(
		"base64url payload decoded",
		SpacetimeDBClient.token_claims(url_token).get("sub", "") == "~~~~~~",
		true,
	)
	f += _check_i("not a JWT", SpacetimeDBClient.token_claims("opaque-token").size(), 0)
	f += _check_i("bad base64", SpacetimeDBClient.token_claims("a.b*c.d").size(), 0)
	f += _check_i("empty payload", SpacetimeDBClient.token_claims("a..d").size(), 0)
	var not_json: String = "h.%s.s" % _b64url("not json".to_utf8_buffer())
	f += _check_i("payload not JSON", SpacetimeDBClient.token_claims(not_json).size(), 0)
	var array: String = "h.%s.s" % _b64url("[1, 2]".to_utf8_buffer())
	f += _check_i("payload not an object", SpacetimeDBClient.token_claims(array).size(), 0)
	return f


func _test_margin_rule() -> int:
	var f: int = 0
	var now: float = 1_000_000.0
	# One hour of life: 5% is 180 s, more than the 30 s floor.
	var long_lived: String = _jwt({ "iat": now - _HOUR + 181.0, "exp": now + 181.0 })
	f += _check_b("181 s left of an hour: kept", _needs(long_lived, now), false)
	long_lived = _jwt({ "iat": now - _HOUR + 179.0, "exp": now + 179.0 })
	f += _check_b("179 s left of an hour: refreshed", _needs(long_lived, now), true)
	# 100 s of life: 5% is 5 s, so the 30 s floor applies.
	var short_lived: String = _jwt({ "iat": now - 69.0, "exp": now + 31.0 })
	f += _check_b("31 s left of 100: kept", _needs(short_lived, now), false)
	short_lived = _jwt({ "iat": now - 71.0, "exp": now + 29.0 })
	f += _check_b("29 s left of 100: refreshed", _needs(short_lived, now), true)
	f += _check_b("no iat, 31 s left: kept", _needs(_jwt({ "exp": now + 31.0 }), now), false)
	f += _check_b("no iat, 29 s left: refreshed", _needs(_jwt({ "exp": now + 29.0 }), now), true)
	f += _check_b("expired: refreshed", _needs(_jwt({ "exp": now - 1.0 }), now), true)
	f += _check_b("no exp: refreshed", _needs(_jwt({ "sub": "x" }), now), true)
	f += _check_b("not a JWT: refreshed", _needs("opaque-token", now), true)
	return f


func _test_provider_called() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	var conn: _StubConn = client._connection
	client._token = _jwt({ "exp": Time.get_unix_time_from_system() - 10.0 })
	client._start_reconnection()
	await client._attempt_reconnect()
	f += _check_i("near expiry: the provider is asked", _provider_calls, 1)
	f += _check_b("its token is kept", client._token == _FRESH_TOKEN, true)
	f += _check_i("and connected with", conn.connects, 1)
	f += _check_b("on the socket", conn.last_token == _FRESH_TOKEN, true)
	f += _check_i("no error", _errors.size(), 0)
	_free_client(client)

	var far: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	var far_conn: _StubConn = far._connection
	var far_token: String = _jwt({ "exp": Time.get_unix_time_from_system() + _HOUR })
	far._token = far_token
	far._start_reconnection()
	await far._attempt_reconnect()
	f += _check_i("far from expiry: the provider is not asked", _provider_calls, 0)
	f += _check_b("the token is used as is", far_conn.last_token == far_token, true)
	f += _check_i("and connected with", far_conn.connects, 1)
	_free_client(far)
	return f


func _test_provider_fails() -> int:
	var f: int = 0
	var failures: Array = ["", 42, null]
	for result: Variant in failures:
		var label: String = "provider returns %s" % var_to_str(result)
		var client: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
		_provider_result = result
		f += await _check_terminal(label, client)

	# A provider whose object was freed.
	var holder: _Holder = _Holder.new()
	var gone: Callable = Callable(holder, "provide")
	holder.free()
	var orphaned: SpacetimeDBClient = await _make_client(gone)
	f += await _check_terminal("provider object freed", orphaned)
	return f


func _test_no_provider() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client(Callable())
	var conn: _StubConn = client._connection
	var expired: String = _jwt({ "exp": Time.get_unix_time_from_system() - 10.0 })
	client._token = expired
	client._start_reconnection()
	await client._attempt_reconnect()
	f += _check_i("no provider: connected", conn.connects, 1)
	f += _check_b("with the token it had", conn.last_token == expired, true)
	f += _check_i("no error", _errors.size(), 0)
	_free_client(client)
	return f


func _test_cancelled_during_provider() -> int:
	var f: int = 0
	var client: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	var conn: _StubConn = client._connection
	client._token = ""
	_provider_gate = true
	client._start_reconnection()
	client._attempt_reconnect() # parks on the gate
	await process_frame
	f += _check_i("the provider is working", _provider_calls, 1)
	client.disconnect_db()
	_gate_opened.emit()
	await process_frame
	f += _check_i("cancelled mid-provider: no connect", conn.connects, 0)
	f += _check_i("and no reconnect_failed", _reconnect_failed_count, 0)
	_free_client(client)

	# Superseded rather than cancelled: while the provider works, the cycle is cancelled and
	# a new one scheduled, so the state reads RECONNECTING again. The parked attempt is the
	# old cycle's and must not connect; the new one connects when its own timer fires.
	var renewed: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	var renewed_conn: _StubConn = renewed._connection
	renewed._token = ""
	_provider_gate = true
	renewed._start_reconnection()
	renewed._attempt_reconnect() # parks on the gate
	await process_frame
	renewed._cancel_reconnection()
	renewed._start_reconnection()
	_gate_opened.emit()
	await process_frame
	f += _check_i("superseded mid-provider: no connect", renewed_conn.connects, 0)
	f += _check_i(
		"the new cycle is still pending",
		renewed._reconnect_state,
		SpacetimeDBClient._ReconnectState.RECONNECTING,
	)
	_free_client(renewed)

	# Left the tree while the provider worked: the cycle is suspended, and re-entry
	# schedules a fresh attempt, so the parked one must not connect.
	var moved: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	var moved_conn: _StubConn = moved._connection
	moved._token = ""
	_provider_gate = true
	moved._start_reconnection()
	moved._attempt_reconnect() # parks on the gate
	await process_frame
	root.remove_child(moved)
	_gate_opened.emit()
	await process_frame
	f += _check_i("left the tree mid-provider: no connect", moved_conn.connects, 0)
	root.add_child(moved)
	_free_client(moved)
	return f


func _test_stale_result_dropped() -> int:
	var f: int = 0
	var path: String = "user://test_token_provider_stale.json"
	DirAccess.remove_absolute(path)

	# disconnect_db while the provider works, which then succeeds.
	var client: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	client.token_save_path = path
	client.save_token = true
	client._token = ""
	_provider_result = _FRESH_TOKEN
	_provider_gate = true
	_errors.clear()
	client._start_reconnection()
	client._attempt_reconnect() # parks on the gate
	await process_frame
	client.disconnect_db()
	_gate_opened.emit()
	await process_frame
	f += _check_b("logout mid-provider: token stays wiped", client._token.is_empty(), true)
	f += _check_b("logout mid-provider: nothing saved", FileAccess.file_exists(path), false)
	f += _check_i("logout mid-provider: no error", _errors.size(), 0)
	_free_client(client)

	# disconnect_db while the provider works, which then fails.
	var failing: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	failing._token = ""
	_provider_result = ""
	_provider_gate = true
	_errors.clear()
	failing._start_reconnection()
	failing._attempt_reconnect()
	await process_frame
	failing.disconnect_db()
	_gate_opened.emit()
	await process_frame
	f += _check_i("logout mid-provider, provider fails: no error", _errors.size(), 0)
	_free_client(failing)

	# connect_db with another account's token while the provider works.
	var switched: SpacetimeDBClient = await _make_client(Callable(self, "_provide"))
	var switched_conn: _StubConn = switched._connection
	switched._token = ""
	_provider_result = _FRESH_TOKEN
	_provider_gate = true
	switched._start_reconnection()
	switched._attempt_reconnect()
	await process_frame
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.save_token = false
	options.threading = false
	options.auto_reconnect = false
	options.token = _ACCOUNT_B
	switched.connect_db("http://localhost:3000", "test_mod", options)
	_gate_opened.emit()
	await process_frame
	f += _check_s("account switch mid-provider: B's token kept", switched._token, _ACCOUNT_B)
	f += _check_s("and B's token connected", switched_conn.last_token, _ACCOUNT_B)
	_free_client(switched)

	_provider_result = _FRESH_TOKEN
	_provider_gate = false
	DirAccess.remove_absolute(path)
	return f


func _check_terminal(label: String, client: SpacetimeDBClient) -> int:
	var f: int = 0
	var conn: _StubConn = client._connection
	# Near expiry but present, so a failure that fell through would connect with it.
	client._token = _jwt({ "exp": Time.get_unix_time_from_system() - 10.0 })
	client._start_reconnection()
	await client._attempt_reconnect()
	f += _check_i("%s: no connect" % label, conn.connects, 0)
	f += _check_i("%s: one error" % label, _errors.size(), 1)
	if _errors.size() == 1:
		f += _check_i("%s: ERR_UNAUTHORIZED" % label, _errors[0], ERR_UNAUTHORIZED)
	f += _check_i("%s: reconnect_failed" % label, _reconnect_failed_count, 1)
	f += _check_i("%s: disconnected" % label, _disconnected_count, 1)
	f += _check_i(
		"%s: idle" % label,
		client._reconnect_state,
		SpacetimeDBClient._ReconnectState.IDLE,
	)
	_free_client(client)
	return f


func _provide() -> Variant:
	_provider_calls += 1
	if _provider_gate:
		await _gate_opened
	else:
		await process_frame
	return _provider_result


func _needs(token: String, now: float) -> bool:
	return SpacetimeDBClient.token_needs_refresh(token, now)


func _jwt(claims: Dictionary) -> String:
	var header: String = _b64url('{"alg":"none"}'.to_utf8_buffer())
	return "%s.%s.sig" % [header, _b64url(JSON.stringify(claims).to_utf8_buffer())]


func _b64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


func _make_client(provider: Callable) -> SpacetimeDBClient:
	_provider_calls = 0
	_provider_result = _FRESH_TOKEN
	_provider_gate = false
	_errors.clear()
	_reconnect_failed_count = 0
	_disconnected_count = 0
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	client.debug_mode = false
	client.use_threading = false
	client.save_token = false
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = true
	options.reconnect_initial_delay = _DELAY
	options.reconnect_max_delay = _DELAY
	options.reconnect_jitter_fraction = 0.0
	options.token_provider = provider
	client.connection_options = options
	root.add_child(client)
	# Inside the tree only on the next frame; the scheduler needs get_tree().
	await process_frame
	client._is_initialized = true
	client._connection = _StubConn.new()
	client.connection_error.connect(_on_connection_error)
	client.reconnect_failed.connect(_on_reconnect_failed)
	client.disconnected.connect(_on_disconnected)
	return client


func _free_client(client: SpacetimeDBClient) -> void:
	var conn: _StubConn = client._connection
	client._cancel_reconnection()
	root.remove_child(client)
	client.free()
	conn.free()


func _on_connection_error(code: int, _reason: String) -> void:
	_errors.append(code)


func _on_reconnect_failed() -> void:
	_reconnect_failed_count += 1


func _on_disconnected() -> void:
	_disconnected_count += 1


func _check_i(label: String, actual: int, expected: int) -> int:
	_total += 1
	if actual == expected:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s: expected %d, got %d" % [label, expected, actual])
	return 1


func _check_s(label: String, actual: String, expected: String) -> int:
	_total += 1
	if actual == expected:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s: expected %s, got %s" % [label, expected, actual])
	return 1


func _check_b(label: String, actual: bool, expected: bool) -> int:
	_total += 1
	if actual == expected:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s: expected %s, got %s" % [label, expected, actual])
	return 1


# Records the connects and the token they carried; opens nothing. Skips the parent _init.
class _StubConn:
	extends SpacetimeDBConnection

	var connects: int = 0
	var last_token: String = ""


	func _init() -> void:
		pass


	func is_connected_db() -> bool:
		return false


	func is_websocket_active() -> bool:
		return false


	func set_token(token: String) -> void:
		last_token = token


	func apply_options(_options: SpacetimeDBConnectionOptions) -> void:
		pass


	func connect_to_database(
		_base_url: String,
		_database_name: String,
		_connection_id: String,
		_session_id: String = "",
	) -> void:
		connects += 1


	func disconnect_from_server(
		_code: int = 1000,
		_reason: String = "Client initiated disconnect",
	) -> void:
		pass


# A provider on an object the test frees, to stand for one whose owner is gone.
class _Holder:
	extends Object

	func provide() -> String:
		return "unused"

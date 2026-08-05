# Regression test for two ways a credential-carrying request could be sent
# somewhere it should not, or never finish at all.
#
#   1. A 3xx from the endpoint. HTTPRequest re-sends the request BODY to the host
#      named by Location — it rewrites an unsafe method to GET and strips the
#      content headers, but not the body, and a `Location: http://…` is followed
#      with TLS off. A SpacetimeAuth exchange body carries the provider
#      credential and a REST reducer call carries the reducer's arguments, so
#      following a redirect can only leak them: the rewritten GET is not a token
#      request nor a reducer call and cannot succeed. max_redirects = 0 turns the
#      3xx into a reported error instead. Covered for both SpacetimeAuth and
#      SpacetimeDBRestAPI, which had the same exposure.
#   2. request_timeout_seconds <= 0 on SpacetimeAuth. HTTPRequest reads 0 as "no
#      timeout", so a host that accepts the connection and never answers suspends
#      the exchange for the process's lifetime — no result, no signal, and the
#      in-flight guard left set, which refuses every later exchange on that node.
#
# All of it is driven against real loopback servers. Without the fixes, case 1
# sees SECRET_TICKET arrive at the redirect target (on both paths) and case 2
# never completes. Note that the bearer token on the REST call is NOT part of
# what leaks — Godot strips the Authorization header when it rewrites the method
# — so that assertion holds either way; the arguments are the ones at risk.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_auth_request_hardening.gd
extends SceneTree

const POLL_FRAME_BUDGET: int = 600 # ~10s @ 60fps — bounds every wait loop (NASA r2)
## Long enough that a completion inside it means the node ended the exchange
## itself, not that a timeout we did not set happened to fire.
const WEDGE_FRAME_BUDGET: int = 240
const CREDENTIAL: String = "SECRET_TICKET"

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += await _case_redirect_not_followed(38311, 38312, 302)
	f += await _case_redirect_not_followed(38313, 38314, 301)
	f += await _case_rest_redirect_not_followed()
	f += await _case_timeout_zero_refused()
	f += await _case_timeout_negative_refused()
	f += await _case_valid_timeout_still_works()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)

# --- cases ---------------------------------------------------------------


# The token endpoint answers with a redirect to a second host. Nothing of the
# request may reach that host, and the caller must be told about the 3xx.
func _case_redirect_not_followed(port_a: int, port_b: int, code: int) -> int:
	var label: String = str(code)
	var endpoint: TCPServer = TCPServer.new()
	var listen_a: Error = endpoint.listen(port_a, "127.0.0.1")
	var target: TCPServer = TCPServer.new()
	var listen_b: Error = target.listen(port_b, "127.0.0.1")

	var auth: SpacetimeAuth = _make_auth(port_a)
	auth.max_attempts = 1
	root.add_child(auth)
	await process_frame

	var out: Array = [null]
	auth.exchange_completed.connect(
		func(r: SpacetimeAuthResult) -> void:
			out[0] = r,
	)
	var fields: Dictionary[String, Variant] = { "steam_ticket": CREDENTIAL }
	@warning_ignore("redundant_await")
	auth.exchange("urn:spacetimeauth:steam-ticket", fields, "cid")

	var redirect: String = (
		"HTTP/1.1 %d Moved\r\nLocation: http://127.0.0.1:%d/\r\nContent-Length: 0\r\n\r\n"
		% [code, port_b]
	)
	# Only what the REDIRECT TARGET received is read back — the endpoint's own
	# connection carries the legitimate request, credential and all.
	var conns: Array[StreamPeerTCP] = []
	var target_conns: Array[StreamPeerTCP] = []
	var target_saw: String = ""
	var target_connected: bool = false
	var guard: int = 0
	# Keep pumping a few frames past completion: the redirected request would be
	# sent after the exchange resolves only if it were followed at all, and this
	# leaves room to observe it either way.
	while guard < POLL_FRAME_BUDGET and (out[0] == null or guard < 30):
		guard += 1
		if endpoint.is_connection_available():
			var from_endpoint: StreamPeerTCP = endpoint.take_connection()
			conns.append(from_endpoint)
			from_endpoint.put_data(redirect.to_utf8_buffer())
		if target.is_connection_available():
			target_connected = true
			target_conns.append(target.take_connection())
		for peer: StreamPeerTCP in target_conns:
			peer.poll()
			var available: int = peer.get_available_bytes()
			if available > 0:
				target_saw += (peer.get_data(available)[1] as PackedByteArray).get_string_from_utf8()
		await process_frame

	var result: SpacetimeAuthResult = out[0]
	var f: int = 0
	f += _check("%s listeners up" % label, [listen_a, listen_b], [OK, OK])
	f += _check("%s exchange completed" % label, result != null, true)
	if result != null:
		f += _check("%s reported as a failure" % label, result.is_successful(), false)
		f += _check("%s error names the status" % label, result.error.contains("HTTP %s" % label), true)
		f += _check("%s issued no token" % label, result.id_token.is_empty(), true)
	f += _check("%s redirect target never contacted" % label, target_connected, false)
	f += _check("%s credential not forwarded" % label, target_saw.contains(CREDENTIAL), false)

	endpoint.stop()
	target.stop()
	auth.queue_free()
	return f


# SpacetimeDBRestAPI's requests are POSTs too, and its reducer call carries both
# a bearer token and the reducer's arguments. Same refusal, same reason — this
# case is what stops the one-liner there from being deleted unnoticed.
func _case_rest_redirect_not_followed() -> int:
	var port_a: int = 38318
	var port_b: int = 38319
	var endpoint: TCPServer = TCPServer.new()
	var listen_a: Error = endpoint.listen(port_a, "127.0.0.1")
	var target: TCPServer = TCPServer.new()
	var listen_b: Error = target.listen(port_b, "127.0.0.1")

	var rest: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:%d" % port_a, false)
	root.add_child(rest)
	await process_frame
	rest.set_token("a-token")

	var failed: Array = [false]
	rest.reducer_call_failed.connect(
		func(_code: int, _body: String) -> void:
			failed[0] = true,
	)
	var args: Dictionary = { "secret": CREDENTIAL }
	rest.call_reducer("testdb", "do_thing", args)

	var redirect: String = (
		"HTTP/1.1 302 Moved\r\nLocation: http://127.0.0.1:%d/\r\nContent-Length: 0\r\n\r\n" % port_b
	)
	var conns: Array[StreamPeerTCP] = []
	var target_conns: Array[StreamPeerTCP] = []
	var target_saw: String = ""
	var target_connected: bool = false
	var guard: int = 0
	while guard < POLL_FRAME_BUDGET and (not failed[0] or guard < 30):
		guard += 1
		if endpoint.is_connection_available():
			var from_endpoint: StreamPeerTCP = endpoint.take_connection()
			conns.append(from_endpoint)
			from_endpoint.put_data(redirect.to_utf8_buffer())
		if target.is_connection_available():
			target_connected = true
			target_conns.append(target.take_connection())
		for peer: StreamPeerTCP in target_conns:
			peer.poll()
			var available: int = peer.get_available_bytes()
			if available > 0:
				target_saw += (peer.get_data(available)[1] as PackedByteArray).get_string_from_utf8()
		await process_frame

	var f: int = 0
	f += _check("rest listeners up", [listen_a, listen_b], [OK, OK])
	f += _check("rest reducer call reported the failure", failed[0], true)
	f += _check("rest redirect target never contacted", target_connected, false)
	f += _check("rest arguments not forwarded", target_saw.contains(CREDENTIAL), false)
	f += _check("rest token not forwarded", target_saw.contains("a-token"), false)

	endpoint.stop()
	target.stop()
	rest.queue_free()
	return f


func _case_timeout_zero_refused() -> int:
	return await _case_bad_timeout(38315, 0.0, "timeout=0")


func _case_timeout_negative_refused() -> int:
	return await _case_bad_timeout(38316, -1.0, "timeout<0")


# A non-positive timeout must be refused before any request goes out, and must
# leave the node usable — the wedge it replaces was permanent.
func _case_bad_timeout(port: int, timeout: float, label: String) -> int:
	# The server accepts and never answers: with the refusal missing, the
	# exchange has nothing to end it.
	var server: TCPServer = TCPServer.new()
	var listen_err: Error = server.listen(port, "127.0.0.1")
	var auth: SpacetimeAuth = _make_auth(port)
	auth.request_timeout_seconds = timeout
	auth.max_attempts = 2
	root.add_child(auth)
	await process_frame

	var out: Array = [null]
	auth.exchange_completed.connect(
		func(r: SpacetimeAuthResult) -> void:
			out[0] = r,
	)
	var runner: Callable = (func() -> void:
		out[0] = await auth.exchange("steam", { }, "cid")
	)
	runner.call()

	var conns: Array[StreamPeerTCP] = []
	var guard: int = 0
	while out[0] == null and guard < WEDGE_FRAME_BUDGET:
		guard += 1
		if server.is_connection_available():
			conns.append(server.take_connection())
		await process_frame

	var result: SpacetimeAuthResult = out[0]
	var f: int = 0
	f += _check("%s listener up" % label, listen_err, OK)
	f += _check("%s exchange completed" % label, result != null, true)
	if result != null:
		f += _check("%s reported as a failure" % label, result.is_successful(), false)
		f += _check("%s error names the setting" % label, result.error.contains(
				"request_timeout_seconds"
			), true)
	f += _check("%s sent no request" % label, conns.is_empty(), true)

	# The in-flight guard must have cleared, or the node is wedged just the same.
	auth.request_timeout_seconds = 5.0
	var after: SpacetimeAuthResult = await auth.exchange("steam", { }, "")
	f += _check("%s node still usable afterwards" % label, after.error.contains("client_id empty"), true)

	server.stop()
	auth.queue_free()
	return f


# The guard must not have moved the ordinary path: a positive timeout against a
# server that answers still produces a token.
func _case_valid_timeout_still_works() -> int:
	var port: int = 38317
	var server: TCPServer = TCPServer.new()
	server.listen(port, "127.0.0.1")
	var auth: SpacetimeAuth = _make_auth(port)
	root.add_child(auth)
	await process_frame

	var out: Array = [null]
	auth.exchange_completed.connect(
		func(r: SpacetimeAuthResult) -> void:
			out[0] = r,
	)
	@warning_ignore("redundant_await")
	auth.exchange("steam", { }, "cid")

	var body: String = '{"id_token": "OK_TOKEN", "expires_in": 60}'
	var response: String = (
		"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s"
		% [body.to_utf8_buffer().size(), body]
	)
	var conns: Array[StreamPeerTCP] = []
	var guard: int = 0
	while out[0] == null and guard < POLL_FRAME_BUDGET:
		guard += 1
		if server.is_connection_available():
			var conn: StreamPeerTCP = server.take_connection()
			conns.append(conn)
			conn.put_data(response.to_utf8_buffer())
		await process_frame

	var result: SpacetimeAuthResult = out[0]
	var f: int = 0
	f += _check("happy path completed", result != null, true)
	if result != null:
		f += _check("happy path succeeded", result.is_successful(), true)
		f += _check("happy path token", result.id_token, "OK_TOKEN")

	server.stop()
	auth.queue_free()
	return f

# --- harness -------------------------------------------------------------


func _make_auth(port: int) -> SpacetimeAuth:
	var auth: SpacetimeAuth = SpacetimeAuth.new()
	auth.token_url = "http://127.0.0.1:%d/" % port
	auth.max_attempts = 4
	auth.base_retry_delay_seconds = 0.0
	auth.max_retry_delay_seconds = 0.0
	auth.request_timeout_seconds = 5.0
	return auth


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, str(got), str(want)])
	return 1

# Probe: the SpacetimeAuth OIDC node's lifecycle, driven against real loopback
# HTTP servers. Everything here is about the node's glue (concurrency, timeout,
# redirects) rather than the pure classification the protocol tests already
# cover.
#
# Scenarios:
#   1. a second exchange() while one is in flight
#   2. a server that accepts and never answers (request timeout bounds it)
#   3. a 302 redirect — what the redirect target receives
#   4. a 307 redirect on a POST — Godot refuses to follow unsafe methods
#   5. request_timeout_seconds = 0 against a silent server (wedge check)
#
# Scenarios 3 and 5 each found a defect; both are fixed, and
# tests/test_auth_request_hardening.gd is the regression test that pins them.
# Scenarios 1, 2 and 4 were clean as found: the in-flight guard refuses an
# overlapping exchange and clears afterwards, a positive request timeout bounds a
# server that never answers (and the retry budget is still spent), and Godot does
# not follow a 307 for a POST.
#
# What this probe does NOT reach: TLS. The scheme downgrade a redirect can cause
# (an https endpoint answering `Location: http://…`, which HTTPRequest follows
# with use_tls cleared) is read out of Godot's _parse_url, not measured here —
# a loopback https server would need a certificate.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_auth_lifecycle.gd
extends SceneTree

const POLL_FRAME_BUDGET: int = 900 # ~15s @ 60fps — bounds every wait loop (NASA r2)

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += await _case_concurrent_exchange()
	f += await _case_silent_server_times_out()
	f += await _case_redirect_302()
	f += await _case_redirect_307()
	f += await _case_timeout_disabled()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)

# --- cases ---------------------------------------------------------------


# Two exchanges overlapping on one node. The second must be refused cleanly
# (the node owns a single HTTPRequest child), the first must still finish, and
# the node must be usable again afterwards.
func _case_concurrent_exchange() -> int:
	var port: int = 38301
	var server: TCPServer = TCPServer.new()
	server.listen(port, "127.0.0.1")
	var auth: SpacetimeAuth = _make_auth(port)
	root.add_child(auth)
	await process_frame

	var results: Array[SpacetimeAuthResult] = []
	auth.exchange_completed.connect(
		func(r: SpacetimeAuthResult) -> void:
			results.append(r),
	)

	var first: Array = [null]
	_run_exchange(auth, first)
	# Same frame, before the first has had any chance to complete.
	var second: SpacetimeAuthResult = await auth.exchange("steam", { }, "cid")

	var conns: Array[StreamPeerTCP] = []
	var body: String = '{"id_token": "FIRST"}'
	await _pump_until(
		func() -> bool:
			return first[0] != null,
		server,
		conns,
		[_http(200, "OK", body)],
	)

	var f: int = 0
	f += _check("concurrent second refused", second.is_successful(), false)
	f += _check("concurrent second names the collision", second.error.contains("in flight"), true)
	f += _check(
		"concurrent first still succeeded",
		(first[0] as SpacetimeAuthResult).id_token,
		"FIRST",
	)
	f += _check("concurrent both reported on the signal", results.size(), 2)

	# The guard must clear: a third exchange after the first finished works.
	var third: Array = [null]
	_run_exchange(auth, third)
	await _pump_until(
		func() -> bool:
			return third[0] != null,
		server,
		conns,
		[_http(200, "OK", '{"id_token": "THIRD"}')],
	)
	f += _check(
		"node reusable after the collision",
		(third[0] as SpacetimeAuthResult).id_token,
		"THIRD",
	)

	server.stop()
	auth.queue_free()
	return f


# A server that completes the TCP handshake and then says nothing. Without a
# request timeout this hangs forever; the node's request_timeout_seconds must
# bound it, and the retry budget must still be spent.
func _case_silent_server_times_out() -> int:
	var port: int = 38302
	var server: TCPServer = TCPServer.new()
	server.listen(port, "127.0.0.1")
	var auth: SpacetimeAuth = _make_auth(port)
	auth.request_timeout_seconds = 1.0
	auth.max_attempts = 2
	root.add_child(auth)
	await process_frame

	var out: Array = [null]
	_run_exchange(auth, out)
	var conns: Array[StreamPeerTCP] = []
	var frames: int = await _pump_until(
		func() -> bool:
			return out[0] != null,
		server,
		conns,
		[],
	)

	var res: SpacetimeAuthResult = out[0]
	var f: int = 0
	f += _check("silent server completed", res != null, true)
	if res != null:
		f += _check("silent server failed", res.is_successful(), false)
		f += _check("silent server named TIMEOUT", res.error.contains("TIMEOUT"), true)
	f += _check("silent server took both attempts", frames > 60, true)
	f += _check("silent server accepted a connection", conns.size() > 0, true)

	server.stop()
	auth.queue_free()
	return f


# A 302 from the token endpoint. Godot rewrites an unsafe method to GET and
# strips the content headers, but the request BODY is carried over — so the
# credential fields land on whatever host the Location names.
func _case_redirect_302() -> int:
	return await _redirect_case(38303, 38304, 302, "302")


# A 307 preserves the method, and Godot refuses to follow one automatically for
# an unsafe method — so the SDK must surface it as an error, not hang.
func _case_redirect_307() -> int:
	return await _redirect_case(38305, 38306, 307, "307")


func _redirect_case(port_a: int, port_b: int, code: int, label: String) -> int:
	var server_a: TCPServer = TCPServer.new()
	server_a.listen(port_a, "127.0.0.1")
	var server_b: TCPServer = TCPServer.new()
	server_b.listen(port_b, "127.0.0.1")

	var auth: SpacetimeAuth = _make_auth(port_a)
	auth.max_attempts = 1
	root.add_child(auth)
	await process_frame

	var out: Array = [null]
	var fields: Dictionary[String, Variant] = { "steam_ticket": "SECRET_TICKET" }
	auth.exchange_completed.connect(
		func(r: SpacetimeAuthResult) -> void:
			out[0] = r,
	)
	@warning_ignore("redundant_await")
	auth.exchange("urn:spacetimeauth:steam-ticket", fields, "cid")

	var redirect: String = (
		"HTTP/1.1 %d Found\r\nLocation: http://127.0.0.1:%d/\r\nContent-Length: 0\r\n\r\n"
		% [code, port_b]
	)
	var conns: Array[StreamPeerTCP] = []
	var seen_by_b: PackedStringArray = []
	var guard: int = 0
	while out[0] == null and guard < POLL_FRAME_BUDGET:
		guard += 1
		if server_a.is_connection_available():
			var a: StreamPeerTCP = server_a.take_connection()
			conns.append(a)
			a.put_data(redirect.to_utf8_buffer())
		if server_b.is_connection_available():
			var b: StreamPeerTCP = server_b.take_connection()
			conns.append(b)
			seen_by_b.append("")
		# Drain whatever the redirect target received.
		for i: int in conns.size():
			var c: StreamPeerTCP = conns[i]
			c.poll()
			var n: int = c.get_available_bytes()
			if n > 0 and i > 0 and not seen_by_b.is_empty():
				var chunk: PackedByteArray = c.get_data(n)[1]
				seen_by_b[seen_by_b.size() - 1] += chunk.get_string_from_utf8()
		await process_frame

	var res: SpacetimeAuthResult = out[0]
	var f: int = 0
	f += _check("%s completed" % label, res != null, true)
	if res != null:
		f += _check("%s did not produce a token" % label, res.is_successful(), false)
	var followed: bool = not seen_by_b.is_empty()
	var leaked: bool = false
	for text: String in seen_by_b:
		if text.contains("SECRET_TICKET"):
			leaked = true
	print("  [%s] followed=%s leaked_credential=%s" % [label, followed, leaked])
	f += _check("%s did not forward the credential" % label, leaked, false)

	server_a.stop()
	server_b.stop()
	auth.queue_free()
	return f


# request_timeout_seconds = 0 disables HTTPRequest's timer entirely. Against a
# server that never answers, the exchange must still end somehow — otherwise the
# in-flight guard stays set and the node is wedged for the process's lifetime
# with no signal to tell the caller.
func _case_timeout_disabled() -> int:
	var port: int = 38307
	var server: TCPServer = TCPServer.new()
	server.listen(port, "127.0.0.1")
	var auth: SpacetimeAuth = _make_auth(port)
	auth.request_timeout_seconds = 0.0
	auth.max_attempts = 2
	root.add_child(auth)
	await process_frame

	var out: Array = [null]
	_run_exchange(auth, out)
	var conns: Array[StreamPeerTCP] = []
	# 300 frames (~5s) is far longer than any bounded path in this node.
	var guard: int = 0
	while out[0] == null and guard < 300:
		guard += 1
		if server.is_connection_available():
			conns.append(server.take_connection())
		await process_frame

	var f: int = 0
	f += _check("timeout=0 still ends the exchange", out[0] != null, true)
	if out[0] == null:
		var again: SpacetimeAuthResult = await auth.exchange("steam", { }, "cid")
		print("  [timeout=0] node wedged; a later exchange says: %s" % again.error)

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


# Start an exchange without awaiting it here, storing the result in slot[0].
func _run_exchange(auth: SpacetimeAuth, slot: Array) -> void:
	var runner: Callable = func() -> void:
		slot[0] = await auth.exchange("steam", { }, "cid")
	runner.call()


# Pump frames until `done` is true, serving `responses` one per connection.
# Returns the number of frames spent.
func _pump_until(done: Callable, server: TCPServer, conns: Array[StreamPeerTCP], responses: Array) -> int:
	var guard: int = 0
	while not done.call() and guard < POLL_FRAME_BUDGET:
		guard += 1
		if server != null and server.is_connection_available():
			var conn: StreamPeerTCP = server.take_connection()
			conns.append(conn)
			if not responses.is_empty():
				var resp: String = responses.pop_front()
				conn.put_data(resp.to_utf8_buffer())
		await process_frame
	return guard


func _http(code: int, reason: String, body: String) -> String:
	var n: int = body.to_utf8_buffer().size()
	return (
		"HTTP/1.1 %d %s\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n%s"
		% [code, reason, n, body]
	)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, str(got), str(want)])
	return 1

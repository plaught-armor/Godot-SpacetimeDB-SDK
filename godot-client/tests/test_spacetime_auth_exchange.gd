# Layer-2 integration test for SpacetimeAuth.exchange() — the coroutine glue that
# the pure protocol (test_spacetime_auth_protocol.gd) feeds. A loopback TCPServer
# serves canned HTTP responses so the real HTTPRequest + await + retry loop run
# end to end, with no live SpacetimeAuth endpoint:
#   - 200 -> id_token parsed
#   - 4xx -> authoritative error, not retried
#   - 503 then 200 -> retried, succeeds on the second attempt
#   - unreachable port -> transport error after retries exhausted
#   - node freed mid-backoff -> clean bail, no crash (C5)
#
# Retry delays are set to 0 so the retry cases finish in a couple of frames.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_spacetime_auth_exchange.gd
extends SceneTree

const POLL_FRAME_BUDGET: int = 600 # ~10s @ 60fps — bounds every wait loop (NASA r2)

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += await _case_success()
	f += await _case_http_error()
	f += await _case_retry_then_success()
	f += await _case_transport_error()
	f += await _case_free_during_backoff()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)

# --- cases ---------------------------------------------------------------


func _case_success() -> int:
	var body: String = '{"id_token": "THE_JWT", "expires_in": 3600}'
	var res: SpacetimeAuthResult = await _serve_and_exchange(38271, [_http(200, "OK", body)], 4)
	var f: int = 0
	f += _check("200 successful", res.is_successful(), true)
	f += _check("200 id_token", res.id_token, "THE_JWT")
	f += _check("200 expires_in", res.expires_in, 3600)
	return f


func _case_http_error() -> int:
	# 400 is authoritative: one connection only, no retry.
	var served: Array = [_http(400, "Bad Request", '{"error": "nope"}')]
	var res: SpacetimeAuthResult = await _serve_and_exchange(38272, served, 4)
	var f: int = 0
	f += _check("400 fails", res.is_successful(), false)
	f += _check("400 has code", res.error.contains("HTTP 400"), true)
	f += _check("400 served exactly once", served.is_empty(), true)
	return f


func _case_retry_then_success() -> int:
	# 503 is transient -> retried; second attempt gets a 200.
	var body: String = '{"id_token": "AFTER_RETRY"}'
	var served: Array = [_http(503, "Service Unavailable", "busy"), _http(200, "OK", body)]
	var res: SpacetimeAuthResult = await _serve_and_exchange(38273, served, 4)
	var f: int = 0
	f += _check("retry succeeds", res.is_successful(), true)
	f += _check("retry id_token", res.id_token, "AFTER_RETRY")
	f += _check("retry consumed both responses", served.is_empty(), true)
	return f


func _case_transport_error() -> int:
	# Nothing listening on this port -> RESULT_CANT_CONNECT, code 0.
	var res: SpacetimeAuthResult = await _serve_and_exchange(38999, [], 2, false)
	var f: int = 0
	f += _check("transport fails", res.is_successful(), false)
	f += _check("transport named", res.error.contains("transport error"), true)
	return f


func _case_free_during_backoff() -> int:
	# Serve one 503 (transient -> the exchange enters its backoff wait), then free
	# the node. The backoff timer lives on the SceneTree, not the node, so the
	# suspended coroutine still resumes — on a freed self. The C5 guard must catch
	# that and return without touching the dead _http. This path deliberately does
	# NOT emit exchange_completed (a freed node can't), so the only observable is:
	# the process survives (an unguarded resume would dereference a freed _http)
	# and the completion signal never fires.
	var auth: SpacetimeAuth = SpacetimeAuth.new()
	auth.token_url = "http://127.0.0.1:38274/"
	auth.max_attempts = 4
	auth.base_retry_delay_seconds = 0.0
	auth.max_retry_delay_seconds = 0.0
	root.add_child(auth)
	await process_frame # let the node actually enter the tree before exchange()

	var server: TCPServer = TCPServer.new()
	var listen_err: Error = server.listen(38274, "127.0.0.1")
	var conns: Array = []
	var done: Array = [false]
	auth.exchange_completed.connect(func(_r: SpacetimeAuthResult) -> void: done[0] = true)
	@warning_ignore("redundant_await")
	auth.exchange("steam", { }, "cid")

	# Bounded pump — we can't wait on `done` (the bail path never emits). Serve one
	# 503, then free the node a frame later while it is mid-retry.
	var freed: bool = false
	for i: int in 30:
		if not freed and server.is_connection_available():
			var conn: StreamPeerTCP = server.take_connection()
			conns.append(conn)
			conn.put_data(_http(503, "Service Unavailable", "busy").to_utf8_buffer())
			freed = true
		elif freed and is_instance_valid(auth):
			auth.free()
		await process_frame

	server.stop()
	var f: int = 0
	f += _check("free-during-backoff listened", listen_err, OK)
	f += _check("free-during-backoff freed the node", is_instance_valid(auth), false)
	f += _check("free-during-backoff bail did not emit", done[0], false)
	f += _check("free-during-backoff survived", true, true)
	return f

# --- harness -------------------------------------------------------------


# Serve `responses` (one per incoming connection, in order) from a loopback
# server on `port`, run one exchange against it, and return the result. When
# `serve` is false no server is started (used to force a transport error).
func _serve_and_exchange(
		port: int,
		responses: Array,
		attempts: int,
		serve: bool = true,
) -> SpacetimeAuthResult:
	var server: TCPServer = null
	if serve:
		server = TCPServer.new()
		server.listen(port, "127.0.0.1")

	var auth: SpacetimeAuth = SpacetimeAuth.new()
	auth.token_url = "http://127.0.0.1:%d/" % port
	auth.max_attempts = attempts
	auth.base_retry_delay_seconds = 0.0
	auth.max_retry_delay_seconds = 0.0
	auth.request_timeout_seconds = 5.0
	root.add_child(auth)
	await process_frame # let the node actually enter the tree before exchange()

	var done: Array = [false]
	var captured: Array = [null]
	auth.exchange_completed.connect(
		func(r: SpacetimeAuthResult) -> void:
			captured[0] = r
			done[0] = true
	)
	@warning_ignore("redundant_await")
	auth.exchange("steam", { }, "cid")

	# Keep accepted connections alive until the exchange completes so buffered
	# response bytes are never dropped by an early socket close.
	var conns: Array = []
	var guard: int = 0
	while not done[0] and guard < POLL_FRAME_BUDGET:
		guard += 1
		if server != null and server.is_connection_available():
			var conn: StreamPeerTCP = server.take_connection()
			conns.append(conn)
			if not responses.is_empty():
				var resp: String = responses.pop_front()
				conn.put_data(resp.to_utf8_buffer())
		await process_frame

	if server != null:
		server.stop()
	if is_instance_valid(auth):
		auth.queue_free()
	return captured[0]


# Minimal HTTP/1.1 response with a Content-Length so HTTPRequest knows the body
# is complete and fires request_completed.
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

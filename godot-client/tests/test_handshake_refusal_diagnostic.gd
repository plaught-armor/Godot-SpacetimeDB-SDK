# Regression test: a refused handshake is reported as a refused handshake.
#
# When a server answers the WebSocket upgrade with an HTTP error, Godot's
# `WebSocketPeer` keeps neither the status nor the body: the peer goes to STATE_CLOSED
# with close code -1 and an empty close reason, exactly like a mid-session TCP drop.
# The SDK reported both as `Abnormal closure: ` with nothing after the colon, which
# reads as a network problem — and the two commonest ways to get here are not network
# problems at all. Measured against a live SpacetimeDB 2.2.0 server: a database name
# that does not exist answers 404 (``nosuchdb` not found`) and a rejected token
# answers 401, and the game saw the same empty "Abnormal closure" for both.
#
# The two cases are distinguishable locally without any of that: a socket that never
# opened has `_is_connected == false`. That much the SDK now says — and no more. What
# ENDED the handshake is not knowable from here (a DNS miss, a proxy that dropped the
# connection and a host that accepted TCP and then reset it all arrive identically), so
# the report names both families of cause and the one command that tells them apart
# rather than asserting the server-side one. A drop after the socket opened still
# reports as an abnormal closure.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_handshake_refusal_diagnostic.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

## RFC 6455's fixed handshake GUID.
const WS_GUID: String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
## Shape-valid placeholder; the hand-rolled listener never checks it.
const FAKE_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"
const CONNECTION_ID: String = "00000000000000000000000000000001"
## Ceiling for every wait loop (NASA rule 2). At 60 Hz this is ~5 s.
const MAX_WAIT_FRAMES: int = 300

var _server: TCPServer = TCPServer.new()
var _stream: StreamPeerTCP = null
## What the listener answers the upgrade with: true = 404, false = a real handshake.
var _refuse: bool = false

var _total: int = 0
var _fails: int = 0
var _reasons: PackedStringArray = []
var _codes: PackedInt32Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_diagnostic_text()
	await _scenario_refused_upgrade()
	await _scenario_drop_after_open_still_reads_as_a_drop()
	await _scenario_stall_guard_does_not_steal_a_refusal()
	_stop_server()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)

# --- the diagnostic itself (pure) -----------------------------------------------


func _test_diagnostic_text() -> void:
	var text: String = SpacetimeDBConnection.handshake_refused_diagnostic(
		"ws://host:3000/v1/database/mydb/subscribe?connection_id=1&token=SECRETJWT",
		"mydb",
	)
	# Quoted, so the assertion cannot be satisfied by the name inside the URL path.
	_check_b("names the database it was refused for", text.contains("'mydb'"), true)
	_check_b("says the socket never opened", text.contains("without the socket opening"), true)
	_check_b("names the 404 cause", text.contains("404"), true)
	_check_b("names the 401 cause", text.contains("401"), true)
	# The same close code arrives for a transport failure that never reached a server,
	# so naming only the server-side causes would be asserting one it cannot know.
	_check_b("names the transport-side causes too", text.contains("DNS"), true)
	_check_b("names the sub-protocol", text.contains(SpacetimeDBConnection.BSATN_PROTOCOL_V3), true)
	# The Web handshake carries the token in the query string, and this text is printed.
	_check_b("keeps the query string out of the text", text.contains("SECRETJWT"), false)
	_check_b("is not the abnormal-closure line", text.contains("Abnormal closure"), false)

# --- scenarios -------------------------------------------------------------------


## The listener answers the upgrade with 404, as a server does for an unknown database.
func _scenario_refused_upgrade() -> void:
	print("\n== upgrade refused with 404 ==")
	_refuse = true
	var conn: SpacetimeDBConnection = _start_connection()
	if conn == null:
		return
	for _i: int in MAX_WAIT_FRAMES:
		await process_frame
		_accept_and_answer()
		if not _reasons.is_empty():
			break

	_check_i("reported once", _reasons.size(), 1)
	if _reasons.is_empty():
		await _teardown(conn)
		return
	_check_b(
		"reported as a handshake that never opened",
		_reasons[0].contains("without the socket opening"),
		true,
	)
	_check_b(
		"not reported as a dropped connection",
		_reasons[0].contains("Abnormal closure"),
		false,
	)
	_check_b("names the database", _reasons[0].contains("'db'"), true)
	_check_b(
		"names the URL it was talking to",
		_reasons[0].contains("/v1/database/db/subscribe"),
		true,
	)
	# The code is unchanged (-1): games branch on it, and the socket really did end
	# without a close code.
	_check_i("still code -1", _codes[0], -1)
	_check_b("the connection is not left thinking it is up", conn.is_connected_db(), false)
	await _teardown(conn)


## Control: once the socket HAS opened, a drop is still a drop. Without this a fix that
## reported every -1 as a refused upgrade would pass the scenario above.
func _scenario_drop_after_open_still_reads_as_a_drop() -> void:
	print("\n== TCP drop after the socket opened ==")
	_refuse = false
	var conn: SpacetimeDBConnection = _start_connection()
	if conn == null:
		return
	for _i: int in MAX_WAIT_FRAMES:
		await process_frame
		_accept_and_answer()
		if conn.is_connected_db():
			break
	_check_b("the socket opened", conn.is_connected_db(), true)

	if _stream != null:
		_stream.disconnect_from_host()
		_stream = null
	for _i: int in MAX_WAIT_FRAMES:
		await process_frame
		if not _reasons.is_empty():
			break

	_check_i("reported once", _reasons.size(), 1)
	if not _reasons.is_empty():
		# Exact, not `contains`: this is the arm that runs when the peer really did
		# close, and its empty tail is what tells it from every other report.
		_check_b("reported as an abnormal closure", _reasons[0] == "Abnormal closure: ", true)
		_check_b(
			"not reported as a handshake failure",
			_reasons[0].contains("without the socket opening"),
			false,
		)
	await _teardown(conn)


## A frame-loop freeze arms the post-stall guard whatever the socket is doing, and the
## guard's arm runs first. The engine keepalive only pings an OPEN socket, so a stall
## can never be what killed one that never opened — without the `_is_connected` half of
## that condition, a freeze overlapping a refused handshake was answered with a
## no-backoff reconnect into the same refusal, and the refusal was never reported.
func _scenario_stall_guard_does_not_steal_a_refusal() -> void:
	print("\n== stall guard armed while the upgrade is refused ==")
	_refuse = true
	var conn: SpacetimeDBConnection = _start_connection()
	if conn == null:
		return
	var stalled: Array[int] = [0] # gdlint: ignore[S6]
	conn.connection_stalled.connect(
		func(_code: int) -> void:
			stalled[0] += 1,
	)
	# Arm the guard by hand: a real freeze is not reproducible in a test frame loop,
	# and tests are exempt from the private-access gate.
	conn._post_stall_polls = SpacetimeDBConnection.STALL_GUARD_POLLS
	for _i: int in MAX_WAIT_FRAMES:
		await process_frame
		_accept_and_answer()
		if not _reasons.is_empty() or stalled[0] > 0:
			break

	_check_i("not reported as a stall", stalled[0], 0)
	_check_i("reported once", _reasons.size(), 1)
	if not _reasons.is_empty():
		_check_b(
			"reported as a refused handshake",
			_reasons[0].contains("without the socket opening"),
			true,
		)
	await _teardown(conn)

# --- harness ---------------------------------------------------------------------


func _start_connection() -> SpacetimeDBConnection:
	_reasons.clear()
	_codes.clear()
	_stream = null

	var port: int = _start_server()
	if port == 0:
		_check_b("listener started", false, true)
		return null

	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	# No keepalive: the hand-rolled listener answers no PING.
	options.heartbeat_interval_seconds = 0.0
	options.connect_timeout_seconds = 5.0

	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "db")
	root.add_child(conn)
	conn.connection_error.connect(_on_connection_error)
	conn.set_token(FAKE_TOKEN)
	conn.connect_to_database("http://127.0.0.1:%d" % port, "db", CONNECTION_ID)
	return conn


func _on_connection_error(code: int, reason: String) -> void:
	_codes.append(code)
	_reasons.append(reason)


func _teardown(conn: SpacetimeDBConnection) -> void:
	conn.disconnect_from_server()
	for _i: int in 10:
		await process_frame
	if is_instance_valid(conn):
		conn.queue_free()
	_stop_server()
	for _i: int in 5:
		await process_frame


func _start_server() -> int:
	if _server.is_listening():
		_server.stop()
	if _server.listen(0, "127.0.0.1") != OK:
		return 0
	return _server.get_local_port()


func _stop_server() -> void:
	if _stream != null:
		_stream.disconnect_from_host()
		_stream = null
	if _server.is_listening():
		_server.stop()


## Accepts the pending connection, if any, and answers its upgrade request — with 404
## when [member _refuse] is set, otherwise with a real 101.
func _accept_and_answer() -> void:
	if _stream == null and _server.is_connection_available():
		_stream = _server.take_connection()
	if _stream == null:
		return
	_stream.poll()
	if _stream.get_available_bytes() <= 0:
		return
	var request: String = _stream.get_utf8_string(_stream.get_available_bytes())
	var key: String = _header_value(request, "sec-websocket-key")
	if key.is_empty():
		return
	if _refuse:
		var body: String = "`db` not found"
		var refusal: String = (
			"HTTP/1.1 404 Not Found\r\n" + "Content-Type: text/plain\r\n"
			+ "Content-Length: %d\r\n\r\n" % body.length() + body
		)
		_stream.put_data(refusal.to_utf8_buffer())
		return
	var accept: String = Marshalls.raw_to_base64((key + WS_GUID).sha1_buffer())
	var response: String = (
		"HTTP/1.1 101 Switching Protocols\r\n" + "Upgrade: websocket\r\n"
		+ "Connection: Upgrade\r\n" + "Sec-WebSocket-Accept: %s\r\n" % accept
		+ "Sec-WebSocket-Protocol: %s\r\n\r\n" % SpacetimeDBConnection.BSATN_PROTOCOL_V3
	)
	_stream.put_data(response.to_utf8_buffer())


## The value of [param name] (lower-cased) in an HTTP request, or "" if absent.
func _header_value(request: String, name: String) -> String:
	for line: String in request.split("\r\n"):
		var colon: int = line.find(":")
		if colon < 0:
			continue
		if line.substr(0, colon).strip_edges().to_lower() == name:
			return line.substr(colon + 1).strip_edges()
	return ""


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %s, want %s" % [label, got, want])


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	_fails += 1
	printerr("FAIL  %s — got %d, want %d" % [label, got, want])

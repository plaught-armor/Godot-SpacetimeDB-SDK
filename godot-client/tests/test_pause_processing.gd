# Regression test: a paused game keeps its connection.
#
# The socket is polled from _physics_process, and that poll is what sends Godot's
# keepalive ping, reads inbound frames and flushes outbound ones. On the default process
# mode, `get_tree().paused = true` — the ordinary way to pause a Godot game — stops the
# poll entirely: measured against a real socket, the connection's poll clock advanced
# 338 ms over 20 unpaused physics frames and 0 ms over 20 paused ones, while 332 ms of
# real time went by. The server closes an idle connection after 30 seconds, so a pause
# menu left open outlived the session.
#
# The client now processes regardless of the pause state and its children inherit that,
# unless SpacetimeDBConnectionOptions.process_while_paused is turned off.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_pause_processing.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

var _total: int = 0
var _fails: int = 0
var _server: TCPServer = TCPServer.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Default options: the client and every child keep processing while paused.
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	root.add_child(client)
	_check_i(
		"the client is always-process by default",
		client.process_mode,
		Node.PROCESS_MODE_ALWAYS,
	)

	paused = true
	_check_b("the client processes while paused", client.can_process(), true)
	paused = false

	# Opting out puts it back on the tree's pause state.
	var frozen_options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	frozen_options.process_while_paused = false
	client.connection_options = frozen_options
	client._apply_process_mode()
	# PAUSABLE, not INHERIT: the option promises the SDK freezes with the game, and
	# INHERIT would hand that decision to an ancestor — a client parented under an
	# always-process node would keep running despite the opt-out.
	_check_i("opting out pins pausable", client.process_mode, Node.PROCESS_MODE_PAUSABLE)
	paused = true
	_check_b("the opted-out client freezes with the tree", client.can_process(), false)
	paused = false
	var always_parent: Node = Node.new()
	always_parent.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(always_parent)
	root.remove_child(client)
	always_parent.add_child(client)
	paused = true
	_check_b("the opt-out holds under an always-process parent", client.can_process(), false)
	paused = false
	client.queue_free()
	always_parent.queue_free()

	await _behaviour_check()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# The socket half, driven through the real client so the assertion covers the wiring
# that ships: the client sets its own mode, its children are added by it and left on
# INHERIT, and the connection is what has to keep polling. A local listener accepts and
# never answers, so the peer stays in STATE_CONNECTING and the poll loop keeps running
# instead of shutting itself off.
func _behaviour_check() -> void:
	var err: Error = _server.listen(0, "127.0.0.1")
	if err != OK:
		printerr("FAIL  could not open a listener: %d" % err)
		_fails += 1
		_total += 1
		return
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.auto_connect = false
	client.connection_options = options
	root.add_child(client) # _ready applies the process mode
	# Parented by the client exactly as initialize_and_connect does, and left on the
	# default mode, so this asserts the inheritance the fix relies on rather than a
	# stand-in for it.
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(options, "testdb")
	client.add_child(conn)
	_check_i("the connection stays on inherit", conn.process_mode, Node.PROCESS_MODE_INHERIT)
	conn.set_token("eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig")
	conn.connect_to_database("http://127.0.0.1:%d" % _server.get_local_port(), "testdb", "beef")

	await _frames(10)
	_check_b("the connection is polling", conn.is_physics_processing(), true)

	paused = true
	var before: int = conn._last_poll_ms
	await _frames(20)
	_check_b("the poll clock keeps moving while paused", conn._last_poll_ms > before, true)

	paused = false
	# Close the peer before dropping the listener: a socket still in STATE_CONNECTING
	# reports the vanished listener as an abnormal closure on its next poll, which would
	# printerr after the run had already reported itself green.
	conn.disconnect_from_server()
	await _frames(2)
	client.queue_free()
	_server.stop()


func _frames(count: int) -> void:
	for _i: int in count:
		await physics_frame


func _check_b(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1


func _check_i(label: String, got: int, want: int) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	_fails += 1

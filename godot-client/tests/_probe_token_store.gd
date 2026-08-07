# Probe: the persisted auth token when a project runs MORE THAN ONE generated client
# in one process (the multi-module shape codegen emits an autoload for).
#
# token_save_path is a per-client @export with one hardcoded default, so every client
# in the process reads and writes the SAME file. This measures what that does to the
# identity each module connects with, across two "launches", against a loopback server
# that issues a distinct token per /v1/identity request.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_token_store.gd
extends SceneTree

const PROBE_TOKEN_PATH: String = "user://__probe_token_store.dat"
const MAX_WAIT_FRAMES: int = 600

var _total: int = 0
var _fails: int = 0
var _server: _IdentityStub


## Loopback HTTP/1.1 server answering POST /v1/identity with a fresh token each time,
## so two clients that both fetch are distinguishable.
class _IdentityStub:
	extends Node

	var port: int = 0
	var issued: int = 0
	var _server: TCPServer = TCPServer.new()
	var _peers: Array[StreamPeerTCP] = []


	func listen() -> Error:
		var err: Error = _server.listen(0, "127.0.0.1")
		port = _server.get_local_port()
		return err


	func _process(_delta: float) -> void:
		if _server.is_connection_available():
			var peer: StreamPeerTCP = _server.take_connection()
			if peer != null:
				_peers.append(peer)
		for peer: StreamPeerTCP in _peers.duplicate():
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_peers.erase(peer)
				continue
			if peer.get_available_bytes() <= 0:
				continue
			var request: String = peer.get_utf8_string(peer.get_available_bytes())
			if not request.contains("\r\n\r\n"):
				continue
			peer.put_data(_response().to_utf8_buffer())
			peer.disconnect_from_host()
			_peers.erase(peer)


	func _response() -> String:
		issued += 1
		var payload: String = ('{"identity":"%02x","token":"tok%d"}' % [issued, issued])
		return (
			"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
			% [payload.to_utf8_buffer().size(), payload]
		)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_server = _IdentityStub.new()
	if _server.listen() != OK:
		printerr("could not listen on loopback")
		quit(1)
		return
	root.add_child(_server)

	await _scenario_default_paths_collide()
	await _scenario_two_launches()
	if FileAccess.file_exists(PROBE_TOKEN_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_TOKEN_PATH))

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


# The premise: nothing about a client's module makes its token path its own.
func _scenario_default_paths_collide() -> void:
	var a: SpacetimeDBClient = _make_client("Alpha", "")
	var b: SpacetimeDBClient = _make_client("Beta", "")
	_check_str("Alpha default token path", a.token_save_path, a.token_save_path)
	print("      Alpha path = %s" % a.token_save_path)
	print("      Beta  path = %s" % b.token_save_path)
	_check("two modules share one token file", a.token_save_path == b.token_save_path, true)
	a.queue_free()
	b.queue_free()
	await process_frame


# Launch 1: both clients connect in the same frame with persistence on and no file.
# Launch 2: fresh clients read whatever launch 1 left behind.
func _scenario_two_launches() -> void:
	if FileAccess.file_exists(PROBE_TOKEN_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_TOKEN_PATH))
	var issued_before: int = _server.issued

	var a1: SpacetimeDBClient = _make_client("Alpha", PROBE_TOKEN_PATH)
	var b1: SpacetimeDBClient = _make_client("Beta", PROBE_TOKEN_PATH)
	_connect(a1)
	_connect(b1)
	await _await_tokens([a1, b1])

	print("      launch 1: identity requests = %d" % (_server.issued - issued_before))
	print("      launch 1: Alpha token = '%s'" % a1._token)
	print("      launch 1: Beta  token = '%s'" % b1._token)
	print("      launch 1: file holds    '%s'" % _read_file())
	_check("launch 1: the two modules hold different tokens", a1._token != b1._token, true)

	var a1_token: String = a1._token
	var b1_token: String = b1._token
	a1.disconnect_db()
	b1.disconnect_db()
	a1.queue_free()
	b1.queue_free()
	await process_frame
	await process_frame

	var issued_mid: int = _server.issued
	var a2: SpacetimeDBClient = _make_client("Alpha", PROBE_TOKEN_PATH)
	var b2: SpacetimeDBClient = _make_client("Beta", PROBE_TOKEN_PATH)
	_connect(a2)
	_connect(b2)
	await _await_tokens([a2, b2])

	print("      launch 2: identity requests = %d" % (_server.issued - issued_mid))
	print("      launch 2: Alpha token = '%s'" % a2._token)
	print("      launch 2: Beta  token = '%s'" % b2._token)
	_check("launch 2: Alpha keeps the identity it had in launch 1", a2._token == a1_token, true)
	_check("launch 2: Beta keeps the identity it had in launch 1", b2._token == b1_token, true)
	a2.disconnect_db()
	b2.disconnect_db()
	a2.queue_free()
	b2.queue_free()
	await process_frame

# --- harness ---


func _make_client(module: String, token_path: String) -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = module
	client.name = "Client%s" % module
	client.debug_mode = false
	if not token_path.is_empty():
		client.token_save_path = token_path
	root.add_child(client)
	return client


func _connect(client: SpacetimeDBClient) -> void:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.one_time_token = false # persist + reload: a stable identity across runs
	options.save_token = true
	options.debug_mode = false
	options.auto_reconnect = false
	client.connect_db("http://127.0.0.1:%d" % _server.port, "probe_db", options)


func _await_tokens(clients: Array) -> void:
	for _i: int in MAX_WAIT_FRAMES:
		var all_have: bool = true
		for client: SpacetimeDBClient in clients:
			if client._token.is_empty():
				all_have = false
		if all_have:
			return
		await process_frame


func _read_file() -> String:
	if not FileAccess.file_exists(PROBE_TOKEN_PATH):
		return "<absent>"
	var file: FileAccess = FileAccess.open(PROBE_TOKEN_PATH, FileAccess.READ)
	if file == null:
		return "<unreadable>"
	var text: String = file.get_as_text().strip_edges()
	file.close()
	return text


func _check(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1


func _check_str(label: String, got: String, want: String) -> void:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	_fails += 1

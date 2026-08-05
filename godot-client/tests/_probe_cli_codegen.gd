# Probe: the headless codegen path (cli.gd / SpacetimePlugin.generate_schema) against a
# real HTTP server, with no SpacetimeDB running.
#
# Everything about codegen that has been tested so far starts AFTER the schema is in
# hand (module_config.unparsed_module_schema set by the test). This drives the half
# nobody has: a real HTTPRequest fetching `/v1/database/<name>/schema?version=10` from a
# loopback TCPServer that answers however the scenario wants — the module's real schema,
# a 404, a proxy's HTML error page, or nothing at all.
#
# Only the FAILURE paths are driven, on purpose: generate_schema hardcodes
# res://spacetime_bindings/schema as its output, and a successful run prunes every
# generated file the run did not name. Serving a schema that is not exactly the one the
# committed bindings came from therefore deletes them — measured, when this probe first
# served codegen_debug/unparsed_schema_blackholio.json, which despite its name holds
# whatever schema was last generated under the key "blackholio" (a test fixture, in that
# case): 32 committed files were replaced and 64 deleted, recovered with git checkout.
# The success path is covered by test_codegen_golden.gd, which writes to a temp dir.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/_probe_cli_codegen.gd
extends SceneTree

const MODULE_NAME: String = "blackholio"
const MODULE_ALIAS: String = "Blackholio"
const MAX_WAIT_FRAMES: int = 900

var _total: int = 0
var _fails: int = 0
var _server: _HttpStub


## Loopback HTTP/1.1 server, pumped from _process so it keeps serving while the probe
## is suspended inside generate_schema's await.
class _HttpStub:
	extends Node

	enum Mode {
		NOT_FOUND,
		HTML,
		SILENT,
	}

	var mode: Mode = Mode.NOT_FOUND
	var port: int = 0
	var requests: int = 0
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
		# Bounded: only the peers accepted so far, one pass per frame.
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
			requests += 1
			if mode == Mode.SILENT:
				continue # accepted, never answered — the client has to time out
			peer.put_data(_response().to_utf8_buffer())
			peer.disconnect_from_host()
			_peers.erase(peer)


	func _response() -> String:
		if mode == Mode.NOT_FOUND:
			return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
		var payload: String = "<html><body>502 Bad Gateway</body></html>"
		return (
			"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
			% [payload.to_utf8_buffer().size(), payload]
		)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_server = _HttpStub.new()
	if _server.listen() != OK:
		printerr("could not listen on loopback")
		quit(1)
		return
	root.add_child(_server)

	await _scenario_not_found()
	await _scenario_html_error_page()
	await _scenario_silent_server()

	if _fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [_fails, _total])
	quit(_fails)


func _scenario_not_found() -> void:
	_server.mode = _HttpStub.Mode.NOT_FOUND
	var ok: bool = await _generate()
	_check("404: generation refused", ok, false)


# A proxy or gateway answering 200 with an error page: parse_schema takes a Dictionary,
# so this is the shape that used to go down as a type fault mid-generation.
func _scenario_html_error_page() -> void:
	_server.mode = _HttpStub.Mode.HTML
	var ok: bool = await _generate()
	_check("HTML body with 200: generation refused", ok, false)


# A server that accepts the connection and never answers: HTTPRequest.timeout is what
# has to end it (4s in generate_schema's caller).
func _scenario_silent_server() -> void:
	_server.mode = _HttpStub.Mode.SILENT
	var before: int = _server.requests
	var ok: bool = await _generate()
	_check("silent server: generation refused", ok, false)
	_check("silent server: the request was made", _server.requests > before, true)

# --- harness ---


func _generate() -> bool:
	var request: HTTPRequest = HTTPRequest.new()
	request.timeout = 4.0
	root.add_child(request)
	var config: SpacetimeDBPluginConfig = SpacetimeDBPluginConfig.new()
	config.uri = "http://127.0.0.1:%d" % _server.port
	var module_config: SpacetimeDBModuleConfig = SpacetimeDBModuleConfig.new()
	module_config.name = MODULE_NAME
	module_config.alias = MODULE_ALIAS
	module_config.hide_private_tables = true
	module_config.hide_scheduled_reducers = true
	config.module_configs[MODULE_ALIAS] = module_config
	var ok: bool = await SpacetimePlugin.generate_schema(request, config)
	request.queue_free()
	return ok


func _check(label: String, got: bool, want: bool) -> void:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	_fails += 1

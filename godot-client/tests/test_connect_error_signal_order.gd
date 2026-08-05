# Regression test: connect_db() must not report a failure before it returns.
#
# Every other way a connection attempt ends — DNS, the socket, the identity request —
# reports from a later frame by construction. Three did not: a token refused because it
# carries a control character (handed in through the options, or read back from
# token_save_path), and the no-token-and-auto_request_token-off case. Those were decided
# inside connect_db and emitted inline, so only listeners wired BEFORE the call heard
# them.
#
# That is the opposite order from the one callers write, and it is the order the
# Blackholio example shipped with (connect, then wire the handlers on the next lines):
# the game heard nothing and sat waiting on a connection the SDK had already abandoned.
# Measured before the fix: wired-before saw the error, wired-after saw nothing.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_connect_error_signal_order.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

const TOKEN_PATH: String = "user://test_signal_order_token.dat"
## A token with an embedded newline — SpacetimeDBConnection.token_reject_reason refuses
## it, because it would split the Authorization header on the handshake.
const BAD_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig\nX-Injected: 1"
## Nothing listens here; the run never gets far enough to open a socket.
const UNREACHABLE: String = "http://127.0.0.1:1"
## Shape-valid token, so the refusal under test is the URL rather than the credential.
const GOOD_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.sig"

var _total: int = 0
## Bumped by the named handler below — the sibling test_token_header_safety.gd uses the
## same shape, and a named method keeps the four cases wiring identical Callables.
var _seen: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var f: int = 0
	f += await _case_saved_token_refused(true)
	f += await _case_saved_token_refused(false)
	f += await _case_options_token_refused()
	f += await _case_no_token_available()
	f += await _case_unusable_url()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TOKEN_PATH))
	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


## The saved-token path, with the handler wired before and after the call. Both have to
## hear it.
func _case_saved_token_refused(wire_first: bool) -> int:
	_write_token(BAD_TOKEN)
	var options: SpacetimeDBConnectionOptions = _options()
	options.one_time_token = false # take the saved-token path
	_seen = 0
	var client: SpacetimeDBClient = _client()
	if wire_first:
		client.connection_error.connect(_on_connection_error)
	client.connect_db(UNREACHABLE, "blackholio", options)
	if not wire_first:
		client.connection_error.connect(_on_connection_error)
	await process_frame
	await process_frame
	var label: String = "wired first" if wire_first else "wired after connect_db"
	var f: int = _check("saved token refused, %s" % label, _seen, 1)
	_drop(client)
	return f


## The same refusal, but the token comes in through the options.
func _case_options_token_refused() -> int:
	var options: SpacetimeDBConnectionOptions = _options()
	options.token = BAD_TOKEN
	_seen = 0
	var client: SpacetimeDBClient = _client()
	client.connect_db(UNREACHABLE, "blackholio", options)
	client.connection_error.connect(_on_connection_error)
	await process_frame
	await process_frame
	var f: int = _check("options token refused, wired after connect_db", _seen, 1)
	_drop(client)
	return f


## No token anywhere and auto_request_token off: the third inline report.
func _case_no_token_available() -> int:
	var options: SpacetimeDBConnectionOptions = _options()
	options.one_time_token = false
	_seen = 0
	var client: SpacetimeDBClient = _client()
	client.auto_request_token = false
	_erase_token()
	client.connect_db(UNREACHABLE, "blackholio", options)
	client.connection_error.connect(_on_connection_error)
	await process_frame
	await process_frame
	var f: int = _check("no token available, wired after connect_db", _seen, 1)
	_drop(client)
	return f


## The connection layer decides some failures inline too: WebSocketPeer.connect_to_url
## refuses a URL whose scheme survived build_socket_url's http/https rewrite, with no I/O
## at all, and the client re-emits whatever the connection reports.
func _case_unusable_url() -> int:
	_write_token(GOOD_TOKEN)
	var options: SpacetimeDBConnectionOptions = _options()
	options.one_time_token = false
	_seen = 0
	var client: SpacetimeDBClient = _client()
	client.connect_db("gopher://127.0.0.1:1", "blackholio", options)
	client.connection_error.connect(_on_connection_error)
	await process_frame
	await process_frame
	var f: int = _check("unusable url, wired after connect_db", _seen, 1)
	_drop(client)
	return f

# --- harness ---


func _on_connection_error(_code: int, _reason: String) -> void:
	_seen += 1


func _client() -> SpacetimeDBClient:
	var script: GDScript = load("res://spacetime_bindings/schema/module_blackholio_client.gd")
	var client: SpacetimeDBClient = script.new()
	client.token_save_path = TOKEN_PATH
	root.add_child(client)
	return client


func _options() -> SpacetimeDBConnectionOptions:
	var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	options.auto_reconnect = false
	options.threading = false
	options.save_token = false
	return options


func _drop(client: SpacetimeDBClient) -> void:
	client.disconnect_db()
	client.free()


func _write_token(token: String) -> void:
	var file: FileAccess = FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	file.store_string(token)
	file.close()


func _erase_token() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TOKEN_PATH))


func _check(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1

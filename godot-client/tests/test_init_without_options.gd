# Regression test: initialize_and_connect() with no connection_options must not leave a
# half-built connection.
#
# connection_options is not exported and defaults to null. connect_db() always supplies
# one, but initialize_and_connect() can be reached without it — the exported auto_connect
# flag calls it straight from _ready, and the method is documented as callable directly.
# SpacetimeDBConnection.apply_options dereferences what it is handed on its first line, so
# a null faulted there; being a fault in a callee it unwound only that function, so the
# constructor carried on and the connection ended up with a null _options, no resolved
# buffer sizes and no heartbeat — every later read of them faulting in turn.
#
# Asserts:
#   - the client fills in defaults, so its own connection_options reads back non-null,
#   - the connection took them (its _options is that same object),
#   - the settings reached the socket (peer buffers/heartbeat, stall + connect budgets),
#     not merely that the client decided something,
#   - the exported knobs seed those defaults — compression in particular, which is
#     write-only on the client and so never reached the handshake on this path,
#   - apply_options(null) on a live connection is refused, records the refusal, and
#     changes nothing.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_init_without_options.gd
#
# Exit code = number of failed cases (0 = all pass).

extends SceneTree

## A port nothing listens on. The token request this kicks off must not reach a real
## host: the point of the test is what the client built, not what a server answers.
const CLOSED_URL: String = "http://127.0.0.1:1"

var _total: int = 0
var _client: SpacetimeDBClient


func _initialize() -> void:
	root.call_deferred(&"add_child", _mk_client())
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var fails: int = _check_all()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _check_all() -> int:
	var f: int = 0
	f += _check_b("no options before init", _client.connection_options == null, true)
	_client.initialize_and_connect()

	var options: SpacetimeDBConnectionOptions = _client.connection_options
	f += _check_b("the client filled in defaults", options != null, true)

	var conn: SpacetimeDBConnection = _client._connection
	f += _check_b("the connection was built", conn != null, true)
	# Two checks, not one: with the fix reverted BOTH sides are null, and null == null
	# passes. The buffer/heartbeat members below carry declaration defaults for the same
	# reason — they cannot tell a resolved connection from an unresolved one, so
	# _options is the discriminator.
	f += _check_b("the connection has options at all", conn._options != null, true)
	f += _check_b("the connection took those options", conn._options == options, true)
	# Delivery, not decision. _inbound_buffer_size / _outbound_buffer_size /
	# _heartbeat_seconds all carry declaration defaults, so they read correct even when
	# apply_options never ran — these four do not.
	f += _check_b("stall threshold resolved", conn._stall_threshold_ms > 0, true)
	f += _check_b("connect timeout resolved", conn._connect_timeout_ms > 0, true)
	f += _check_i(
		"the socket got the inbound buffer",
		conn._websocket.inbound_buffer_size,
		SpacetimeDBConnection.DEFAULT_BUFFER_SIZE,
	)
	f += _check_b(
		"the socket got the heartbeat",
		is_equal_approx(
			conn._websocket.heartbeat_interval,
			SpacetimeDBConnection.DEFAULT_HEARTBEAT_SECONDS,
		),
		true,
	)

	# The exported knobs are what the caller configured on this path, so the defaults are
	# seeded from them rather than left bare. compression is the one that never reached
	# the socket before: the client's export is write-only (connect_db writes options INTO
	# it), so an auto_connect client handshook with None whatever the inspector said.
	f += _check_i(
		"the compression export reached the options",
		options.compression,
		_client.compression,
	)
	f += _check_b("threading export reached the options", options.threading, _client.use_threading)
	f += _check_b("save_token export reached the options", options.save_token, _client.save_token)

	# The refusal is recorded, not only printed — push_error cannot be read in-process.
	f += _check_b("no refusal on the happy path", conn._options_refused, false)

	# A direct apply_options(null) keeps what is in force rather than half-applying.
	conn.apply_options(null)
	f += _check_b("the refusal was recorded", conn._options_refused, true)
	f += _check_b("refused null left options in force", conn._options != null, true)
	f += _check_b("refused null still holds the same object", conn._options == options, true)
	f += _check_i(
		"refused null kept the buffer size",
		conn._inbound_buffer_size,
		SpacetimeDBConnection.DEFAULT_BUFFER_SIZE,
	)
	return f


func _mk_client() -> SpacetimeDBClient:
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.module_name = "blackholio"
	client.schema_path = "res://spacetime_bindings/schema"
	client.base_url = CLOSED_URL
	client.database_name = "probe"
	client.save_token = false
	client.token_save_path = "user://__test_init_without_options.dat"
	_client = client
	return client


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1

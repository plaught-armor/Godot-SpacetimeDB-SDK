# Test for auth-token validation before the token reaches the WebSocket handshake.
#
# The token is spliced into an `Authorization: Bearer <token>` entry in
# WebSocketPeer.handshake_headers, and Godot writes those out verbatim
# (`request += handshake_headers[i] + "\r\n"` in wsl_peer.cpp) with no validation of
# its own. A CR or LF inside the token therefore closes the header line early and
# whatever follows becomes further request headers — verified against a local socket:
# a token of `abc\r\nX-Injected: yes` produced an `X-Injected` header and truncated
# the credential to `abc`. Tokens are not always the game's own (SpacetimeAuth parses
# one out of a third-party OIDC host's JSON, the client can read one from disk, and
# the server sends one in its IdentityToken message), so the check belongs here.
#
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_token_header_safety.gd
#
# Exit code = number of failed cases (0 = all pass).
extends SceneTree

# A realistic JWT shape: base64url segments, dots, no padding.
const GOOD_TOKEN: String = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJjMjAwIn0.Xq-3_yA9bQ"

var _total: int = 0
var _errors: PackedStringArray = []


func _initialize() -> void:
	var fails: int = _run()
	if fails == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [fails, _total])
	quit(fails)


func _run() -> int:
	var f: int = 0

	# --- The pure check ---
	f += _check_b("a JWT is accepted", _rejected(GOOD_TOKEN), false)
	f += _check_b("a plain opaque token is accepted", _rejected("abcDEF123-_=+/~."), false)
	f += _check_b("an empty token is rejected", _rejected(""), true)
	f += _check_b("a CR is rejected", _rejected("abc\rdef"), true)
	f += _check_b("an LF is rejected", _rejected("abc\ndef"), true)
	f += _check_b("a CRLF header injection is rejected", _rejected("abc\r\nX-Injected: yes"), true)
	f += _check_b("a trailing newline is rejected", _rejected(GOOD_TOKEN + "\n"), true)
	f += _check_b("a tab is rejected", _rejected("abc\tdef"), true)
	# NUL is not in the table: Godot's String cannot carry one (String.chr(0) is
	# replaced with U+FFFD at parse time), so it cannot reach a header either.
	f += _check_b("a C0 control is rejected", _rejected("abc" + String.chr(0x1F)), true)
	f += _check_b("a DEL is rejected", _rejected("abc" + String.chr(0x7F)), true)
	# The reason names the offending byte and where it is, so the report is actionable.
	var reason: String = SpacetimeDBConnection.token_reject_reason("ab\ncd")
	f += _check_b("the reason names the byte", reason.contains("0x0A"), true)
	f += _check_b("the reason names the index", reason.contains("index 2"), true)

	# --- set_token ---
	var conn: SpacetimeDBConnection = SpacetimeDBConnection.new(
		SpacetimeDBConnectionOptions.new(),
		"testdb",
	)
	conn.set_token(GOOD_TOKEN)
	f += _check_s("a good token is stored", conn._token, GOOD_TOKEN)

	# A refused token must not be stored, and must not leave the previous one in place
	# either: connecting with the older credential would be a silent substitution.
	conn.set_token("abc\r\nX-Injected: yes")
	f += _check_s("a refused token is not stored", conn._token, "")

	# And the connect attempt that follows says so, rather than returning quietly.
	conn.connection_error.connect(_on_connection_error)
	conn.connect_to_database("http://127.0.0.1:3000", "testdb", "deadbeef")
	f += _check_i("the refused token fails the connect loudly", _errors.size(), 1)
	f += _check_b(
		"the failure names the missing token",
		_errors.size() == 1 and _errors[0] == "No auth token",
		true,
	)
	f += _check_b("no connection was requested", conn._connection_requested, false)

	conn.free()

	# --- The client chokepoint ---
	# Every token the client connects with funnels through _on_token_received: one set
	# in the options, one read back from token_save_path, one issued by the REST
	# identity endpoint. Built with .new() and never added to the tree, so _ready
	# (auto-connect, threads) never runs — same harness as tests/test_reconnect_state.gd.
	var client: SpacetimeDBClient = SpacetimeDBClient.new()
	client.connection_error.connect(_on_connection_error)
	_errors.clear()
	# Own path, cleared first: the default one may hold a token from an earlier run.
	client.token_save_path = "user://__test_refused_token.dat"
	client.save_token = true
	DirAccess.remove_absolute(ProjectSettings.globalize_path(client.token_save_path))

	# The refusal returns before the client touches its (here null) connection, which
	# is what keeps this reachable on a client that was never wired up.
	client._on_token_received("abc\r\nX-Injected: yes")
	f += _check_s("the client did not store a refused token", client._token, "")
	f += _check_i("the client reported the refusal", _errors.size(), 1)
	f += _check_b(
		"the refusal says why",
		_errors.size() == 1 and _errors[0].contains("control character"),
		true,
	)
	# And it never reaches disk, whatever save_token says.
	f += _check_b(
		"a refused token is not saved",
		FileAccess.file_exists(client.token_save_path),
		false,
	)

	# connect_db must refuse before storing, or the bad token sits in _token and a later
	# drop spends the whole auto-reconnect budget re-refusing it one attempt at a time.
	_errors.clear()
	var client2: SpacetimeDBClient = SpacetimeDBClient.new()
	client2.connection_error.connect(_on_connection_error)
	var opts: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
	opts.token = "abc\r\nX-Injected: yes"
	client2.connect_db("http://127.0.0.1:3000", "testdb", opts)
	f += _check_s("connect_db did not store a refused token", client2._token, "")
	f += _check_i("connect_db reported the refusal", _errors.size(), 1)
	f += _check_b("connect_db did not initialize", client2._is_initialized, false)
	client2.free()

	# --- The REST client shares the one definition ---
	# It used to check CR/LF only, which let a tab through while the WebSocket path
	# refused it.
	var rest: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:3000", false)
	rest.set_token(GOOD_TOKEN)
	f += _check_s("the REST client stores a good token", rest._token, GOOD_TOKEN)
	rest.set_token("abc\tdef")
	f += _check_s("the REST client refuses a tab and clears", rest._token, "")
	rest.free()

	client.free()
	return f


func _rejected(token: String) -> bool:
	return not SpacetimeDBConnection.token_reject_reason(token).is_empty()


func _on_connection_error(_code: int, reason: String) -> void:
	_errors.append(reason)


func _check_b(label: String, got: bool, want: bool) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %s" % [label, got])
		return 0
	printerr("FAIL  %s: got %s want %s" % [label, got, want])
	return 1


func _check_i(label: String, got: int, want: int) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = %d" % [label, got])
		return 0
	printerr("FAIL  %s: got %d want %d" % [label, got, want])
	return 1


func _check_s(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s = '%s'" % [label, got])
		return 0
	printerr("FAIL  %s: got '%s' want '%s'" % [label, got, want])
	return 1

# Regression test: a host URL written with a trailing slash still reaches the server.
#
# String.path_join concatenates when either side already carries the separator, so
# "http://127.0.0.1:3000/" + "/v1/database/..." produced a path with an empty first
# segment. The server routes that as a different path — measured against 2.7.x with a
# local `spacetime start`: GET /v1/ping answers 200 and //v1/ping answers 404, POST
# /v1/identity answers 200 and //v1/identity answers 404. So a host copied out of a
# browser's address bar failed the token fetch and the handshake, with nothing in either
# error naming the extra character.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_base_url_trailing_slash.gd
extends SceneTree

var _total: int = 0


func _initialize() -> void:
	var f: int = 0
	f += _test_socket_url()
	f += _test_rest_base()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _test_socket_url() -> int:
	var f: int = 0
	f += _check(
		"plain host",
		SpacetimeDBConnection.build_socket_url("http://127.0.0.1:3000", "v1", "game"),
		"ws://127.0.0.1:3000/v1/database/game/subscribe",
	)
	f += _check(
		"trailing slash",
		SpacetimeDBConnection.build_socket_url("http://127.0.0.1:3000/", "v1", "game"),
		"ws://127.0.0.1:3000/v1/database/game/subscribe",
	)
	f += _check(
		"several trailing slashes",
		SpacetimeDBConnection.build_socket_url("http://127.0.0.1:3000///", "v1", "game"),
		"ws://127.0.0.1:3000/v1/database/game/subscribe",
	)
	# A reverse-proxied deployment keeps its path prefix; only the trailing slash goes.
	f += _check(
		"path prefix",
		SpacetimeDBConnection.build_socket_url("https://example.com/stdb/", "v1", "game"),
		"wss://example.com/stdb/v1/database/game/subscribe",
	)
	f += _check(
		"https becomes wss",
		SpacetimeDBConnection.build_socket_url("https://example.com", "v1", "game"),
		"wss://example.com/v1/database/game/subscribe",
	)
	# Only the leading scheme is rewritten — "http://" further along is part of the path.
	f += _check(
		"scheme rewritten once",
		SpacetimeDBConnection.build_socket_url("http://proxy/http://inner", "v1", "game"),
		"ws://proxy/http://inner/v1/database/game/subscribe",
	)
	# A scheme-less host is left as written rather than guessed at.
	f += _check(
		"no scheme",
		SpacetimeDBConnection.build_socket_url("127.0.0.1:3000/", "v1", "game"),
		"127.0.0.1:3000/v1/database/game/subscribe",
	)
	return f


func _test_rest_base() -> int:
	var f: int = 0
	var api: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:3000/", false)
	f += _check("rest base normalized", api._base_url, "http://127.0.0.1:3000")
	# The endpoint the token fetch actually asks for.
	f += _check("rest identity path", api._base_url.path_join("/v1/identity"), "http://127.0.0.1:3000/v1/identity")
	api.free()

	var plain: SpacetimeDBRestAPI = SpacetimeDBRestAPI.new("http://127.0.0.1:3000", false)
	f += _check("rest base without slash unchanged", plain._base_url, "http://127.0.0.1:3000")
	plain.free()
	return f


func _check(label: String, got: String, want: String) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, got, want])
	return 1

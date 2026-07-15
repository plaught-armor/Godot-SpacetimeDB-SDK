# Layer-1 unit test for SpacetimeAuthProtocol — the pure, network-free transforms
# behind the SpacetimeAuth node's token exchange. No node, no socket, no await:
# request encoding, retry decision, backoff math, response classification, and
# credential redaction are all exercised here so the node's own test only has to
# cover the thin HTTP glue.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_spacetime_auth_protocol.gd
extends SceneTree

static var _redact: PackedStringArray = ["id_token", "token", "ticket"]

var _total: int = 0


func _initialize() -> void:
	var f: int = 0

	# --- build_form_body: stable client_id, grant_type, then extras; encoded ---
	f += _check(
		"form body basic",
		SpacetimeAuthProtocol.build_form_body("cid", "steam", { }),
		"client_id=cid&grant_type=steam",
	)
	f += _check(
		"form body extras encoded",
		SpacetimeAuthProtocol.build_form_body("cid", "steam", { "steam_ticket": "a b/c" }),
		"client_id=cid&grant_type=steam&steam_ticket=a%20b%2Fc",
	)
	f += _check(
		"form body int value stringified",
		SpacetimeAuthProtocol.build_form_body("cid", "steam", { "app_id": 480 }),
		"client_id=cid&grant_type=steam&app_id=480",
	)

	# --- is_transient: retry on no-response / 5xx, authoritative on 2xx/4xx ---
	f += _check("transient code 0", SpacetimeAuthProtocol.is_transient(0), true)
	f += _check("transient 500", SpacetimeAuthProtocol.is_transient(500), true)
	f += _check("transient 503", SpacetimeAuthProtocol.is_transient(503), true)
	f += _check("authoritative 200", SpacetimeAuthProtocol.is_transient(200), false)
	f += _check("authoritative 400", SpacetimeAuthProtocol.is_transient(400), false)
	f += _check("authoritative 499", SpacetimeAuthProtocol.is_transient(499), false)

	# --- backoff_delay: doubling, clamped to cap ---
	f += _check("backoff attempt 0", SpacetimeAuthProtocol.backoff_delay(0, 0.5, 4.0), 0.5)
	f += _check("backoff attempt 1", SpacetimeAuthProtocol.backoff_delay(1, 0.5, 4.0), 1.0)
	f += _check("backoff attempt 3", SpacetimeAuthProtocol.backoff_delay(3, 0.5, 4.0), 4.0)
	f += _check("backoff clamped", SpacetimeAuthProtocol.backoff_delay(5, 0.5, 4.0), 4.0)

	# --- transport_result_name ---
	f += _check(
		"transport name known",
		SpacetimeAuthProtocol.transport_result_name(HTTPRequest.RESULT_CANT_RESOLVE),
		"CANT_RESOLVE",
	)
	f += _check(
		"transport name success",
		SpacetimeAuthProtocol.transport_result_name(HTTPRequest.RESULT_SUCCESS),
		"SUCCESS",
	)
	f += _check(
		"transport name unknown",
		SpacetimeAuthProtocol.transport_result_name(9999),
		"UNKNOWN",
	)

	# --- classify: happy 200 ---
	var ok: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_SUCCESS,
		200,
		'{"id_token": "JWT", "expires_in": 3600}',
		_redact,
	)
	f += _check("classify 200 successful", ok.is_successful(), true)
	f += _check("classify 200 id_token", ok.id_token, "JWT")
	f += _check("classify 200 expires_in", ok.expires_in, 3600)

	# --- classify: 200 missing id_token ---
	var no_tok: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_SUCCESS,
		200,
		'{"expires_in": 1}',
		_redact,
	)
	f += _check("classify 200 no-token fails", no_tok.is_successful(), false)
	f += _check("classify 200 no-token msg", no_tok.error.contains("missing id_token"), true)

	# --- classify: 200 non-JSON / non-object ---
	var not_json: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_SUCCESS,
		200,
		"totally not json",
		_redact,
	)
	f += _check("classify 200 non-json", not_json.error, "response not JSON object")
	var json_arr: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_SUCCESS,
		200,
		"[1, 2, 3]",
		_redact,
	)
	f += _check("classify 200 json-array", json_arr.error, "response not JSON object")

	# --- classify: 4xx authoritative error, body redacted ---
	var http400: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_SUCCESS,
		400,
		'{"error": "bad", "token": "SECRET"}',
		_redact,
	)
	f += _check("classify 400 fails", http400.is_successful(), false)
	f += _check("classify 400 has code", http400.error.contains("HTTP 400"), true)
	f += _check("classify 400 redacted", http400.error.contains("SECRET"), false)

	# --- classify: 5xx also surfaces as HTTP error (retry already exhausted) ---
	var http500: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_SUCCESS,
		500,
		"server on fire",
		_redact,
	)
	f += _check("classify 500 has code", http500.error.contains("HTTP 500"), true)

	# --- classify: code 0 transport error names the transport result ---
	var transport: SpacetimeAuthResult = SpacetimeAuthProtocol.classify(
		HTTPRequest.RESULT_CANT_RESOLVE,
		0,
		"",
		_redact,
	)
	f += _check("classify transport fails", transport.is_successful(), false)
	f += _check(
		"classify transport named",
		transport.error.contains("transport error: CANT_RESOLVE"),
		true,
	)

	# --- redact: JSON and form shapes, non-matches untouched ---
	var scrubbed_json: String = SpacetimeAuthProtocol.redact('{"id_token": "abc123"}', _redact)
	f += _check("redact json value gone", scrubbed_json.contains("abc123"), false)
	f += _check("redact json marker", scrubbed_json.contains("<redacted>"), true)
	var scrubbed_form: String = SpacetimeAuthProtocol.redact("ticket=xyz&grant_type=steam", _redact)
	f += _check("redact form value gone", scrubbed_form.contains("xyz"), false)
	f += _check("redact form keeps other", scrubbed_form.contains("grant_type=steam"), true)
	f += _check(
		"redact no-match untouched",
		SpacetimeAuthProtocol.redact("grant_type=steam", _redact),
		"grant_type=steam",
	)

	# --- SpacetimeAuthResult default + failure ---
	var res: SpacetimeAuthResult = SpacetimeAuthResult.new()
	f += _check("fresh result successful", res.is_successful(), true)
	res.error = "boom"
	f += _check("errored result fails", res.is_successful(), false)

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	var ok: bool = (
			is_equal_approx(got, want) if (got is float and want is float) else got == want
	)
	if ok:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, str(got), str(want)])
	return 1

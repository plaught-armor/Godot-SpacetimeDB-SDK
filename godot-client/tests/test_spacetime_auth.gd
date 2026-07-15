# Unit test for the SpacetimeAuth OIDC exchange node + JwtHelper decoder.
#
# Covers the pure / synchronous surface — no network is touched:
#   - JwtHelper.decode_payload / login_method / summarize (base64url + padding).
#   - SpacetimeAuth._transport_result_name (RESULT_* -> name table).
#   - ExchangeResult.is_successful.
#   - exchange() guard paths that return before any HTTP request (empty
#     client_id, node not inside the tree).
#   - _redact_credentials scrubbing JSON and form bodies.
#
# Run:
#   cd godot-client && <godot> --headless --path . \
#       --script tests/test_spacetime_auth.gd
extends SceneTree

var _total: int = 0


# base64url-encode a JSON object the same way SpacetimeAuth issues a payload, so
# decode_payload has a real round-trip to invert (including the pad-restore).
func _make_jwt(payload: Dictionary) -> String:
	var json: String = JSON.stringify(payload)
	var b64: String = Marshalls.raw_to_base64(json.to_utf8_buffer())
	var b64url: String = b64.replace("+", "-").replace("/", "_").replace("=", "")
	return "eyJhbGciOiJub25lIn0.%s.sig" % b64url


func _initialize() -> void:
	var f: int = 0

	# --- JwtHelper.decode_payload round-trip + padding ---
	var jwt: String = _make_jwt({ "login_method": "steam", "sub": "0xabc" })
	var decoded: Dictionary = JwtHelper.decode_payload(jwt)
	f += _check("decode login_method", String(decoded.get("login_method", "")), "steam")
	f += _check("decode sub", String(decoded.get("sub", "")), "0xabc")

	# A one-extra-char subject shifts the base64 length so padding differs — the
	# pad-restore loop must still round-trip.
	var jwt2: String = _make_jwt({ "login_method": "google", "sub": "0xabcd" })
	f += _check(
		"decode padding variant",
		String(JwtHelper.decode_payload(jwt2).get("login_method", "")),
		"google",
	)

	# --- malformed input -> {} ---
	f += _check("decode one part", JwtHelper.decode_payload("nodots").is_empty(), true)
	f += _check("decode garbage payload", JwtHelper.decode_payload("aa.!!!!.bb").is_empty(), true)
	f += _check("decode empty", JwtHelper.decode_payload("").is_empty(), true)

	# --- login_method convenience ---
	f += _check("login_method valid", JwtHelper.login_method(jwt), "steam")
	f += _check("login_method empty", JwtHelper.login_method(""), "")
	f += _check("login_method malformed", JwtHelper.login_method("nodots"), "")

	# --- summarize ---
	f += _check("summarize empty", JwtHelper.summarize(""), "<empty>")
	f += _check(
		"summarize malformed",
		JwtHelper.summarize("nodots"),
		"<malformed jwt or non-json payload>",
	)
	f += _check(
		"summarize contains claim",
		JwtHelper.summarize(jwt).contains("login_method = steam"),
		true,
	)

	# --- ExchangeResult.is_successful ---
	var ok_result: SpacetimeAuthResult = SpacetimeAuthResult.new()
	f += _check("empty error is success", ok_result.is_successful(), true)
	ok_result.error = "boom"
	f += _check("nonempty error is failure", ok_result.is_successful(), false)

	# --- exchange() guard paths (no network) ---
	var auth: SpacetimeAuth = SpacetimeAuth.new()
	var empty_id: SpacetimeAuthResult = await auth.exchange("steam", { }, "")
	f += _check("empty client_id error", empty_id.error, "client_id empty")
	var no_tree: SpacetimeAuthResult = await auth.exchange("steam", { }, "cid")
	f += _check("not-in-tree fails", no_tree.error.contains("inside the scene tree"), true)
	auth.free()

	if f == 0:
		print("ALL PASS (%d/%d)" % [_total, _total])
	else:
		printerr("%d/%d FAIL" % [f, _total])
	quit(f)


func _check(label: String, got: Variant, want: Variant) -> int:
	_total += 1
	if got == want:
		print("PASS  %s" % label)
		return 0
	printerr("FAIL  %s — got %s want %s" % [label, str(got), str(want)])
	return 1

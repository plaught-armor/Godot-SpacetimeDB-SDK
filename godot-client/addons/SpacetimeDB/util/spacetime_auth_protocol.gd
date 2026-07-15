class_name SpacetimeAuthProtocol
extends RefCounted
## Pure, network-free transforms behind [SpacetimeAuth]'s OIDC token exchange.
## Split out from the node (D6 transforms over methods) so the response
## classification, retry decision, backoff math, and credential redaction are
## unit-testable without a live HTTP endpoint. The [SpacetimeAuth] node keeps
## only the thin [HTTPRequest] glue + the await/retry loop that these feed.

# Maps HTTPRequest.RESULT_* to a readable name for diagnostics (D7 condition
# table over a value-only match — P2/D7b). `.get(rc, ...)` because `rc` is an
# untrusted transport int, not a known-closed key. static var + make_read_only
# (C2a) — not const (C2 shared-mutable trap); frozen in _static_init.
static var _result_names: Dictionary = {
	HTTPRequest.RESULT_SUCCESS: "SUCCESS",
	HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: "CHUNKED_BODY_SIZE_MISMATCH",
	HTTPRequest.RESULT_CANT_CONNECT: "CANT_CONNECT",
	HTTPRequest.RESULT_CANT_RESOLVE: "CANT_RESOLVE",
	HTTPRequest.RESULT_CONNECTION_ERROR: "CONNECTION_ERROR",
	HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS_HANDSHAKE_ERROR",
	HTTPRequest.RESULT_NO_RESPONSE: "NO_RESPONSE",
	HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "BODY_SIZE_LIMIT_EXCEEDED",
	HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED: "BODY_DECOMPRESS_FAILED",
	HTTPRequest.RESULT_REQUEST_FAILED: "REQUEST_FAILED",
	HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: "DOWNLOAD_FILE_CANT_OPEN",
	HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: "DOWNLOAD_FILE_WRITE_ERROR",
	HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: "REDIRECT_LIMIT_REACHED",
	HTTPRequest.RESULT_TIMEOUT: "TIMEOUT",
}


static func _static_init() -> void:
	if not _result_names.is_read_only():
		_result_names.make_read_only()


## Form-encode the OIDC token request body. Field order is stable: client_id,
## grant_type, then each extra field in the dictionary's iteration order. Values
## are stringified, so a non-String field (e.g. an int app id) encodes correctly.
static func build_form_body(
		client_id: String,
		grant_type: String,
		extra_fields: Dictionary[String, Variant],
) -> String:
	var parts: PackedStringArray = []
	parts.append("client_id=" + client_id.uri_encode())
	parts.append("grant_type=" + grant_type.uri_encode())
	for key: String in extra_fields:
		parts.append("%s=%s" % [key.uri_encode(), str(extra_fields[key]).uri_encode()])
	return "&".join(parts)


## True when a completed request should be retried: no HTTP response was produced
## ([param code] 0, a transport error) or the server returned 5xx. A 2xx/4xx
## status is authoritative and must not be retried.
static func is_transient(code: int) -> bool:
	return code == 0 or code >= 500


## Exponential backoff in seconds, clamped to [param cap]. [param attempt] is
## 0-based, so attempt 0 returns [param base].
static func backoff_delay(attempt: int, base: float, cap: float) -> float:
	return minf(cap, base * pow(2.0, attempt))


## Readable name for an [enum HTTPRequest.Result] transport code (e.g.
## [code]"CANT_RESOLVE"[/code]); [code]"UNKNOWN"[/code] for an unrecognized code.
static func transport_result_name(rc: int) -> String:
	return _result_names.get(rc, "UNKNOWN")


## Classify a completed HTTP response (body already decoded to text) into a
## [SpacetimeAuthResult]. [param code] 0 means a transport failure; non-200 is an
## authoritative HTTP error (body redacted for the log); 200 must carry a
## non-empty id_token.
static func classify(
		transport_result: int,
		code: int,
		body: String,
		redact_fields: PackedStringArray,
) -> SpacetimeAuthResult:
	var result: SpacetimeAuthResult = SpacetimeAuthResult.new()
	if code == 0:
		result.error = (
				"transport error: %s (HTTPRequest.Result=%d)"
				% [transport_result_name(transport_result), transport_result]
		)
		return result
	if code != 200:
		result.error = "HTTP %d: %s" % [code, redact(body, redact_fields)]
		return result
	var parsed_variant: Variant = JSON.parse_string(body)
	if not (parsed_variant is Dictionary):
		result.error = "response not JSON object"
		return result
	var parsed: Dictionary = parsed_variant
	result.id_token = str(parsed.get("id_token", ""))
	result.expires_in = int(parsed.get("expires_in", 0))
	if result.id_token.is_empty():
		result.error = "response missing id_token (keys=%s)" % str(parsed.keys())
	return result


## Best-effort scrub of credential-bearing field values from a body before it is
## logged. Handles JSON objects ([code]"field": "..."[/code] ->
## [code]"field": "<redacted>"[/code]) and url-encoded form bodies
## ([code]field=...[/code] -> [code]field=<redacted>[/code]). Not a security
## boundary — just keeps single-use tickets / tokens out of log files.
static func redact(body: String, fields: PackedStringArray) -> String:
	var redacted: String = body
	for field: String in fields:
		var json_re: RegEx = RegEx.new()
		json_re.compile('"%s"\\s*:\\s*"[^"]*"' % field)
		redacted = json_re.sub(redacted, '"%s": "<redacted>"' % field, true)
		var form_re: RegEx = RegEx.new()
		form_re.compile("%s=[^&]*" % field)
		redacted = form_re.sub(redacted, "%s=<redacted>" % field, true)
	return redacted

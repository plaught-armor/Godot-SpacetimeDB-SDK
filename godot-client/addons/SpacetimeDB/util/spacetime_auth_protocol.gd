class_name SpacetimeAuthProtocol
extends RefCounted
## Pure, network-free transforms behind [SpacetimeAuth]'s OIDC token exchange.
## Split out from the node (D6 transforms over methods) so the response
## classification, retry decision, backoff math, and credential redaction are
## unit-testable without a live HTTP endpoint. The [SpacetimeAuth] node keeps
## only the thin [HTTPRequest] glue + the await/retry loop that these feed.

## Characters that carry meaning inside a RegEx pattern, and so have to be
## escaped for one to match itself. See [method _escape_regex_literal].
const _REGEX_METACHARACTERS: String = "\\^$.|?*+()[]{}"
## Shortest retry delay [method resolve_retry_delay] accepts. The loop waits on a
## [SceneTreeTimer], so under a frame is not a shorter wait but no wait at all.
const MIN_RETRY_DELAY_SECONDS: float = 0.05
## Longest retry delay accepted, and the ceiling both bounds clamp to. Bounding the top is
## what keeps the delay finite — see [method backoff_delay].
##
## An order of magnitude under [constant SpacetimeDBClient.MAX_RESPONSE_TIMEOUT_SECONDS] on
## purpose: the two bound different quantities. That one is how long a caller is willing to
## wait for an answer; this one is how long [method SpacetimeAuth.exchange] pauses BETWEEN
## two attempts of a single exchange, with its coroutine suspended and its in-flight guard
## held the whole time. Nothing bounds the product of this and
## [member SpacetimeAuth.max_attempts], so the ceiling is what keeps a degenerate pair from
## turning "retry a few times" into an hours-long suspension.
const MAX_RETRY_DELAY_SECONDS: float = 60.0
## Fallback for a first-retry delay that cannot be waited out. Mirrors
## [member SpacetimeAuth.base_retry_delay_seconds]'s default, so a refused value behaves as
## if the node had been left alone.
const DEFAULT_BASE_RETRY_DELAY: float = 0.5
## Fallback for an unusable backoff ceiling. Mirrors
## [member SpacetimeAuth.max_retry_delay_seconds]'s default.
const DEFAULT_MAX_RETRY_DELAY: float = 4.0
## Longest single HTTP request [SpacetimeAuth] will wait on, and the ceiling
## [member SpacetimeAuth.request_timeout_seconds] clamps to.
##
## A floor alone is not enough: [HTTPRequest] starts its timeout timer only for a POSITIVE
## timeout, so [code]INF[/code] starts one that never counts down and a merely enormous
## finite value (a milliseconds figure typed into a seconds field) is the same wedge without
## tripping any is-finite check.
##
## Far below [constant SpacetimeDBClient.MAX_RESPONSE_TIMEOUT_SECONDS], for the reason
## [constant MAX_RETRY_DELAY_SECONDS] is: this bounds a pause INSIDE one
## [method SpacetimeAuth.exchange] — repeated once per attempt, with the coroutine suspended,
## the in-flight guard held and no abort signal — not a caller's own willingness to wait.
## Two minutes is long for an OIDC token POST and short enough to keep the worst case in
## [constant MAX_ATTEMPTS]'s note a wait rather than an outage.
const MAX_REQUEST_TIMEOUT_SECONDS: float = 120.0
## Shortest request timeout accepted. Below this the request is answered as timed out before
## a LAN round trip could finish (measured: 0.01 reported TIMEOUT in 0 ms, before the TCP
## connection was even accepted), which is the same "told the server did not answer before
## it could have" this whole resolution exists to prevent.
const MIN_REQUEST_TIMEOUT_SECONDS: float = 0.05
## What [method resolve_request_timeout] answers for a value it refuses outright.
##
## Negative rather than [code]0.0[/code] deliberately: this is a public static, and
## [code]0.0[/code] is exactly [HTTPRequest]'s "no timeout" — the wedge the resolution
## exists to prevent — so a caller who assigned the refusal straight to
## [member HTTPRequest.timeout] would install the bug instead of being stopped by it.
## [method HTTPRequest.set_timeout] refuses a negative value loudly and keeps its previous
## one, so a misuse fails at the boundary.
const REFUSED_REQUEST_TIMEOUT: float = -1.0
## Most attempts one [method SpacetimeAuth.exchange] may make.
##
## The other factor of the suspension a single exchange can cost: each attempt waits out a
## request timeout and then a backoff delay, and nothing bounds their product but these
## three ceilings. Worst case with every knob pushed over its ceiling is
## [code]10 x 120 + 9 x 60 = 1740[/code] seconds — 29 minutes, against the 10 hours the same
## arithmetic gave before the request timeout was bounded, and the hours-to-days an
## unbounded attempt budget gave before that. It is still a long time for an exchange that
## cannot be cancelled, so it is a bound on damage, not a target.
const MAX_ATTEMPTS: int = 10

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
##
## Both bounds are resolved again here ([method resolve_retry_delay]) even though
## [method SpacetimeAuth.exchange] resolves them once before its retry loop — a second pass
## over already-resolved values reports nothing, and it keeps a direct caller from handing
## the result to a timer that cannot fire. The result goes straight to
## [method SceneTree.create_timer] in that loop, which has no way out of a delay that never
## elapses: zero or negative spends the whole
## attempt budget inside a handful of frames, and [code]INF[/code] — which survives
## [method @GlobalScope.minf] when it is the cap AND when it is the base — suspends the
## exchange for the life of the process with no abort signal to escape it. NaN survives the
## clamp from either side too ([method @GlobalScope.minf] returns its second argument when
## [code]a < b[/code] is false, and every comparison against NaN is false), and a NaN wait
## fires on the next frame.
static func backoff_delay(attempt: int, base: float, cap: float) -> float:
	var resolved_base: float = resolve_retry_delay(base, DEFAULT_BASE_RETRY_DELAY, "backoff base")
	var resolved_cap: float = resolve_retry_delay(cap, DEFAULT_MAX_RETRY_DELAY, "backoff cap")
	return minf(resolved_cap, resolved_base * pow(2.0, attempt))


## [param value] if it is a delay the retry loop can wait out, else [param fallback].
## [param setting] names the caller for the diagnostic.
##
## Clamped at the top, refused at the bottom — the split the SDK's other knob resolvers
## take ([method SpacetimeDBConnection.resolve_buffer_size],
## [method SpacetimeDBClient.resolve_wait_timeout]). Above
## [constant MAX_RETRY_DELAY_SECONDS] the intent is unambiguous (wait longer); below
## [constant MIN_RETRY_DELAY_SECONDS] it is not, since a sub-frame delay is not a shorter
## wait but no wait, and the retries then land on the endpoint that is already failing as
## fast as the frame loop allows.
static func resolve_retry_delay(value: float, fallback: float, setting: String) -> float:
	if value > MAX_RETRY_DELAY_SECONDS:
		push_error(
			(
				"SpacetimeAuthProtocol: %s = %s is above the %.0f-second maximum (INF lands "
				+ "here too, and an infinite delay never elapses at all); using %.0f instead."
			)
			% [setting, value, MAX_RETRY_DELAY_SECONDS, MAX_RETRY_DELAY_SECONDS]
		)
		return MAX_RETRY_DELAY_SECONDS
	if value >= MIN_RETRY_DELAY_SECONDS:
		return value
	push_error(
		(
			"SpacetimeAuthProtocol: %s = %s is not a delay the retry loop can wait out — "
			+ "under the %.2f-second minimum the retries run a frame apart, and zero, "
			+ "negative and NaN all do the same; using %s instead."
		)
		% [setting, value, MIN_RETRY_DELAY_SECONDS, fallback]
	)
	return fallback


## [param value] if it is a request timeout [HTTPRequest] can act on, else
## [constant MAX_REQUEST_TIMEOUT_SECONDS] when it is over the ceiling and
## [constant REFUSED_REQUEST_TIMEOUT] when it cannot be used at all.
##
## Zero, negative, NaN and anything under [constant MIN_REQUEST_TIMEOUT_SECONDS] are NOT
## clamped up to something usable: they are the caller saying something
## [method SpacetimeAuth.exchange] refuses outright, and it reports the refusal as the
## exchange's own error rather than silently substituting a deadline. The refusal comes
## back as a distinct value rather than a substitute, which is why this is not shaped like
## [method resolve_retry_delay].
static func resolve_request_timeout(value: float) -> float:
	if value > MAX_REQUEST_TIMEOUT_SECONDS:
		push_error(
			(
				"SpacetimeAuthProtocol: request_timeout_seconds = %s is above the %.0f-second "
				+ "maximum (INF lands here too, and HTTPRequest starts a timer that never "
				+ "counts down); using %.0f instead."
			)
			% [value, MAX_REQUEST_TIMEOUT_SECONDS, MAX_REQUEST_TIMEOUT_SECONDS]
		)
		return MAX_REQUEST_TIMEOUT_SECONDS
	if value >= MIN_REQUEST_TIMEOUT_SECONDS:
		return value
	if value > 0.0:
		push_error(
			(
				"SpacetimeAuthProtocol: request_timeout_seconds = %s is below the %.2f-second "
				+ "minimum — the request is reported as timed out before a round trip could "
				+ "finish — and is refused."
			)
			% [value, MIN_REQUEST_TIMEOUT_SECONDS]
		)
	return REFUSED_REQUEST_TIMEOUT


## [param value] clamped into the attempt budget one exchange may spend.
##
## [method SpacetimeAuth.exchange] refuses a budget below one outright, before calling this,
## so the bottom arm here is only reachable by a direct caller — it exists so this cannot
## answer with a value nothing can use. See [constant MAX_ATTEMPTS] for what the ceiling
## bounds.
static func resolve_attempts(value: int) -> int:
	if value < 1:
		push_error("SpacetimeAuthProtocol: max_attempts = %d is not a request; using 1." % value)
		return 1
	if value <= MAX_ATTEMPTS:
		return value
	push_error(
		(
			"SpacetimeAuthProtocol: max_attempts = %d is above the maximum %d; each attempt "
			+ "waits out a request timeout and a backoff delay, and the exchange cannot be "
			+ "cancelled, so the budget is capped. Using %d instead."
		)
		% [value, MAX_ATTEMPTS, MAX_ATTEMPTS]
	)
	return MAX_ATTEMPTS


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
		# The field name is captured and written back through $1 rather than
		# interpolated into the replacement, where `$` and `\` would read as
		# backreferences.
		var pattern_field: String = _escape_regex_literal(field)
		var json_re: RegEx = RegEx.new()
		json_re.compile('"(%s)"\\s*:\\s*"[^"]*"' % pattern_field)
		redacted = json_re.sub(redacted, '"$1": "<redacted>"', true)
		var form_re: RegEx = RegEx.new()
		form_re.compile("(%s)=[^&]*" % pattern_field)
		redacted = form_re.sub(redacted, "$1=<redacted>", true)
	return redacted


## Quote [param text] for use as a literal inside a RegEx pattern. A field name
## is a plain string out of configuration, not a pattern: interpolated raw, one
## carrying a metacharacter either matches the wrong span (a `.` matching any
## field name) or fails to compile — and [method RegEx.sub] on a RegEx that
## failed to compile returns an empty [String], which would silently erase the
## whole body it was asked to scrub rather than one value inside it.
static func _escape_regex_literal(text: String) -> String:
	var escaped: String = ""
	for character: String in text:
		if _REGEX_METACHARACTERS.contains(character):
			escaped += "\\"
		escaped += character
	return escaped

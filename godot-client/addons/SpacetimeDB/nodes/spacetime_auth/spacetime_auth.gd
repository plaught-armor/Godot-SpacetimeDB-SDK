@tool
class_name SpacetimeAuth
extends Node
## Provider-agnostic SpacetimeAuth token exchange.
##
## POSTs to the SpacetimeAuth OIDC token endpoint with a [code]client_id[/code],
## a [code]grant_type[/code], and a set of provider-specific credential fields,
## then returns the issued id_token (a JWT you hand to SpacetimeDBClient as the
## connection token). The node owns its own [HTTPRequest] child, so callers just
## add it to the tree and await:
## [codeblock]
## var auth: SpacetimeAuth = SpacetimeAuth.new()
## add_child(auth)
## var result: SpacetimeAuthResult = await auth.exchange(
##     "urn:spacetimeauth:steam-ticket",                     # grant_type
##     {"steam_ticket": ticket_hex, "steam_app_id": app_id}, # provider fields
##     my_client_id,
## )
## auth.queue_free()
## if result.is_successful():
##     connection_options.token = result.id_token
## [/codeblock]
## The same result is also emitted via [signal exchange_completed] for
## signal-based callers. This node is provider-agnostic: [code]grant_type[/code]
## and the [code]extra_fields[/code] keys are whatever the SpacetimeAuth endpoint
## defines for your provider (Steam above is verified against the 2.7.0 docs).
## Look up the exact grant-type string and field names for each provider at
## https://docs.spacetimedb.com/ .
##
## This node is deliberately thin: everything network-free (request encoding,
## response classification, retry decision, backoff, redaction) lives in the
## stateless [SpacetimeAuthProtocol] so it can be unit-tested without a live
## endpoint. What remains here is the [HTTPRequest] glue + await/retry loop.

## Emitted when an [method exchange] finishes, carrying the same
## [SpacetimeAuthResult] the coroutine returns (for signal-based callers).
signal exchange_completed(result: SpacetimeAuthResult)

const TOKEN_URL_DEFAULT: String = "https://auth.spacetimedb.com/oidc/token"

@export var debug_mode: bool = false
## OIDC token endpoint. Override for a self-hosted SpacetimeAuth deployment.
@export var token_url: String = TOKEN_URL_DEFAULT
## Bounds the network hang on an unreachable endpoint (DNS stall, TLS failure).
@export var request_timeout_seconds: float = 15.0
## Total attempts before giving up. Transient failures (transport error / 5xx)
## are retried; a 2xx/4xx is authoritative and never retried.
@export var max_attempts: int = 4
## First-retry backoff, doubled each further attempt (clamped to the max below).
@export var base_retry_delay_seconds: float = 0.5
## Upper bound the exponential backoff delay is clamped to.
@export var max_retry_delay_seconds: float = 4.0
## Field names whose VALUES are redacted from any error body echoed to the log.
@export var redact_fields: PackedStringArray = [
	"id_token",
	"access_token",
	"refresh_token",
	"token",
	"code",
	"ticket",
	"client_secret",
]

var _http: HTTPRequest
## True while an exchange() coroutine is in flight; guards against a second
## concurrent exchange colliding on the single shared _http child.
var _pending: bool = false


func _print_log(message: String) -> void:
	if debug_mode:
		print("[SpacetimeAuth] %s" % message)


func _ensure_http() -> void:
	if not is_instance_valid(_http):
		_http = HTTPRequest.new()
		add_child(_http)
	# Set every call so an inspector tweak to request_timeout_seconds after the
	# first exchange still takes effect on reuse (not just at construction).
	_http.timeout = request_timeout_seconds


## Exchange a provider credential for a SpacetimeAuth id_token. Coroutine: await
## it for the [SpacetimeAuthResult], or connect [signal exchange_completed] — the
## same result is delivered both ways. [param extra_fields] carries the
## provider-specific credential fields. The node must be inside the tree first.
## Retries transient failures (submit error / no response / 5xx) with exponential
## backoff; a 2xx/4xx is authoritative and returned immediately.
func exchange(
	grant_type: String,
	extra_fields: Dictionary[String, Variant],
	client_id: String,
) -> SpacetimeAuthResult:
	# Re-entrancy guard. The node owns one _http child; a second concurrent
	# exchange would collide on it (its request() returns ERR_BUSY and burns the
	# retry budget waiting for the first to release the socket). Reject the
	# overlapping call cleanly. This wrapper is the single site that clears
	# _pending, so it holds on every _exchange_impl return path.
	if _pending:
		var busy: SpacetimeAuthResult = SpacetimeAuthResult.new()
		busy.error = "exchange already in flight on this SpacetimeAuth node"
		exchange_completed.emit(busy)
		return busy
	_pending = true
	var result: SpacetimeAuthResult = await _exchange_impl(grant_type, extra_fields, client_id)
	_pending = false
	return result


func _exchange_impl(
	grant_type: String,
	extra_fields: Dictionary[String, Variant],
	client_id: String,
) -> SpacetimeAuthResult:
	var result: SpacetimeAuthResult = SpacetimeAuthResult.new()
	if client_id.is_empty():
		result.error = "client_id empty"
		exchange_completed.emit(result)
		return result
	if not is_inside_tree():
		result.error = "SpacetimeAuth node must be inside the scene tree before calling exchange()"
		push_error("[SpacetimeAuth] %s" % result.error)
		exchange_completed.emit(result)
		return result
	if max_attempts < 1:
		result.error = "max_attempts must be >= 1 (got %d)" % max_attempts
		push_error("[SpacetimeAuth] %s" % result.error)
		exchange_completed.emit(result)
		return result

	_ensure_http()

	var body: String = SpacetimeAuthProtocol.build_form_body(client_id, grant_type, extra_fields)
	var headers: PackedStringArray = ["content-type: application/x-www-form-urlencoded"]

	_print_log(
		(
			"POST %s grant_type=%s client_id=%s (%d bytes)"
			% [token_url, grant_type, client_id, body.length()]
		),
	)

	# Retry transient failures with exponential backoff: a request submit error,
	# no HTTP response, or a 5xx status is retried; a 2xx/4xx status code is
	# authoritative and breaks out immediately.
	var response: Array = []
	for attempt: int in max_attempts:
		var last: bool = attempt == max_attempts - 1
		var err: Error = _http.request(token_url, headers, HTTPClient.METHOD_POST, body)
		if err == OK:
			response = await _http.request_completed
			if not is_instance_valid(_http):
				result.error = "HTTPRequest freed mid-await (node shutdown?)"
				exchange_completed.emit(result)
				return result
			var status_code: int = int(response[1]) if response.size() >= 2 else 0
			if not SpacetimeAuthProtocol.is_transient(status_code):
				break
		if last:
			if err != OK:
				result.error = "HTTPRequest.request err=%d" % err
				push_error("[SpacetimeAuth] %s" % result.error)
				exchange_completed.emit(result)
				return result
			break
		var delay: float = SpacetimeAuthProtocol.backoff_delay(
			attempt,
			base_retry_delay_seconds,
			max_retry_delay_seconds,
		)
		push_warning(
			(
				"[SpacetimeAuth] transient failure (attempt %d/%d), retry in %.1fs"
				% [attempt + 1, max_attempts, delay]
			),
		)
		await get_tree().create_timer(delay).timeout
		# Parent may have freed us during the real-time backoff wait (C5); the
		# next iteration would touch a dead _http. Bail before that.
		if not is_instance_valid(self):
			result.error = "SpacetimeAuth freed during retry backoff"
			return result

	if response.size() < 4:
		result.error = "unexpected request_completed payload size=%d" % response.size()
		push_error("[SpacetimeAuth] %s" % result.error)
		exchange_completed.emit(result)
		return result

	var transport_result: int = int(response[0])
	var code: int = int(response[1])
	var body_str: String = (response[3] as PackedByteArray).get_string_from_utf8()
	_print_log("response: transport=%d HTTP=%d" % [transport_result, code])

	result = SpacetimeAuthProtocol.classify(transport_result, code, body_str, redact_fields)
	exchange_completed.emit(result)
	return result

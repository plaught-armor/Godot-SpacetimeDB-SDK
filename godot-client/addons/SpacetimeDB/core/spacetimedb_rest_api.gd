## HTTP REST client for SpacetimeDB token acquisition and reducer calls.
##
## Handles the [code]/v1/identity[/code] endpoint for authentication tokens and
## optional REST-based reducer invocation. Used internally by [SpacetimeDBClient]
## game code normally uses the WebSocket-based reducer path instead.
class_name SpacetimeDBRestAPI
extends Node

## Emitted when a new authentication token is received.
signal token_received(token: String)
## Emitted when the token request fails.
signal token_request_failed(error_code: int, response_body: String)
## Emitted when a REST-based reducer call succeeds. [param result] is [code]null[/code]
## for a reducer — one that commits answers with an empty body, since a reducer has no
## return value over HTTP. A procedure answers with the JSON encoding of its return
## value, which is any JSON value (object, array, number, string, bool), so [param result]
## is typed [Variant] rather than [Dictionary].
signal reducer_call_completed(result: Variant)
## Emitted when a REST-based reducer call fails.
signal reducer_call_failed(error_code: int, response_body: String)

## Tracks which kind of HTTP request is currently in flight.
enum RequestType {
	## No pending request.
	NONE,
	## Waiting for a token response.
	TOKEN,
	## Waiting for a reducer call response.
	REDUCER_CALL,
}

## Bounds a stalled token/identity fetch. Without it HTTPRequest.timeout defaults
## to 0 (infinite): a server that accepts the TCP connection but never responds
## (wedged load balancer, mid-connection firewall drop) leaves _pending_request_type
## stuck on TOKEN forever — every later request_new_token() no-ops and no
## token_request_failed ever fires. On timeout, request_completed delivers
## RESULT_TIMEOUT, which routes through the normal failure path.
const REQUEST_TIMEOUT_SECONDS: float = 15.0

var _http_request: HTTPRequest = HTTPRequest.new()
var _base_url: String
var _token: String
# State variable to track the expected response type
var _pending_request_type: RequestType = RequestType.NONE
var _debug_mode: bool = false


# Name of a [enum RequestType] value for error messages, without allocating the
# RequestType.keys() Array. Iterates the enum dict (keys = names) to match the value.
static func _type_name(t: RequestType) -> String:
	for name: String in RequestType:
		if RequestType[name] == t:
			return name
	return "?"


func _init(base_url: String, debug_mode: bool) -> void:
	# Trailing slashes dropped for the same reason as SpacetimeDBConnection.build_socket_url:
	# path_join concatenates when either side carries the separator, so a host written as
	# "http://127.0.0.1:3000/" asked for "//v1/identity", which the server answers 404
	# (measured against 2.7.x) — the token fetch failed with nothing naming the cause.
	self._base_url = base_url.rstrip("/")
	self._debug_mode = debug_mode
	add_child(_http_request)
	_http_request.timeout = REQUEST_TIMEOUT_SECONDS
	# Fresh HTTPRequest — no prior connections to guard against.
	_http_request.request_completed.connect(_on_request_completed)


func print_log(log_message: String) -> void:
	if _debug_mode:
		print(log_message)


func set_token(token: String) -> void:
	# One definition of an unusable token for the whole SDK: this used to check CR/LF
	# only, which let a tab or a DEL through here while the WebSocket path refused it.
	# Cleared rather than left alone on refusal, so a later call_reducer cannot go out
	# under a credential this call was told not to accept.
	var reason: String = SpacetimeDBConnection.token_reject_reason(token)
	if not reason.is_empty():
		push_error("SpacetimeDBRestAPI: refusing the auth token — %s." % reason)
		self._token = ""
		return
	self._token = token


# --- Token Management ---
func request_new_token() -> void:
	# Prevent concurrent requests if this handler isn't designed for it
	if _pending_request_type != RequestType.NONE:
		printerr(
			"SpacetimeDBRestAPI: Cannot request token while another request is pending (%s)."
			% _type_name(_pending_request_type)
		)
		# Optionally queue or emit a busy error
		return

	print_log("SpacetimeDBRestAPI: Requesting new token...")
	var url: String = _base_url.path_join("/v1/identity")
	# Set state *before* making the request
	_pending_request_type = RequestType.TOKEN
	var error: Error = _http_request.request(url, [], HTTPClient.METHOD_POST)
	if error != OK:
		printerr("SpacetimeDBRestAPI: Error initiating token request: ", error)
		# Reset state on immediate failure
		_pending_request_type = RequestType.NONE
		token_request_failed.emit(error, "Failed to initiate request")


# --- Reducer Call (REST Example) ---
func call_reducer(database: String, reducer_name: String, args: Dictionary) -> void:
	if _pending_request_type != RequestType.NONE:
		printerr(
			"SpacetimeDBRestAPI: Cannot call reducer while another request is pending (%s)."
			% _type_name(_pending_request_type)
		)
		reducer_call_failed.emit(-1, "Another request pending")
		return

	if _token.is_empty():
		printerr("SpacetimeDBRestAPI: Cannot call reducer without auth token.")
		reducer_call_failed.emit(-1, "Auth token not set")
		return

	var url: String = (
		_base_url
		.path_join("/v1/database")
		.path_join(database.uri_encode())
		.path_join("call")
		.path_join(reducer_name.uri_encode())
	)
	var headers: PackedStringArray = [
		"Authorization: Bearer " + _token,
		"Content-Type: application/json",
	]
	var body: String = JSON.stringify(args)

	# Set state *before* making the request
	_pending_request_type = RequestType.REDUCER_CALL
	var error: Error = _http_request.request(url, headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		printerr("SpacetimeDBRestAPI: Error initiating reducer call request: ", error)
		# Reset state on immediate failure
		_pending_request_type = RequestType.NONE
		reducer_call_failed.emit(error, "Failed to initiate request")


func _handle_token_response(
	result_code: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	# (Logic for handling token response - remains the same as before)
	var body_text: String = body.get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS:
		printerr("SpacetimeDBRestAPI: Token request failed. Result code: ", result_code)
		token_request_failed.emit(result_code, body_text)
		return

	var json: Variant = JSON.parse_string(body_text)

	if response_code >= 400 or json == null:
		printerr("SpacetimeDBRestAPI: Token request failed. Response code: ", response_code)
		printerr("SpacetimeDBRestAPI: Response body: ", body_text)
		token_request_failed.emit(response_code, body_text)
		return

	if (
		json is Dictionary and json.has("token")
		and json["token"] is String and not json["token"].is_empty()
	):
		var new_token: String = json["token"]
		print_log("SpacetimeDBRestAPI: New token received.")
		set_token(new_token) # Store it internally as well
		token_received.emit(new_token)
	else:
		printerr("SpacetimeDBRestAPI: Token not found or empty in JSON response: ", body_text)
		token_request_failed.emit(response_code, "Invalid token format in response")


func _handle_reducer_response(
	result_code: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	var body_text: String = body.get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS or response_code >= 400:
		# A reducer that returns an error answers 530, which lands here with the
		# module's message as the body.
		printerr(
			"SpacetimeDBRestAPI: Reducer call failed. Result: %d, Code: %d"
			% [result_code, response_code]
		)
		printerr("SpacetimeDBRestAPI: Response body: ", body_text)
		reducer_call_failed.emit(response_code, body_text)
		return

	# A committed reducer answers 200 with an empty body — it has no return value over
	# HTTP. Demanding a JSON object here reported every successful call as a failure,
	# so reducer_call_completed could not fire for a reducer at all.
	if body_text.is_empty():
		reducer_call_completed.emit(null)
		return

	# Only a procedure sends a body, and it is the JSON encoding of its return value —
	# any JSON value, not necessarily an object. Parse through a JSON instance rather
	# than JSON.parse_string, whose null return cannot tell a literal `null` body from
	# a parse failure.
	var parser: JSON = JSON.new()
	var parse_result: Error = parser.parse(body_text)
	if parse_result != OK:
		printerr(
			"SpacetimeDBRestAPI: reducer response was not valid JSON (line %d: %s): %s"
			% [parser.get_error_line(), parser.get_error_message(), body_text]
		)
		reducer_call_failed.emit(response_code, "Invalid JSON response")
		return

	reducer_call_completed.emit(parser.data)


# --- Request Completion Handler ---
func _on_request_completed(
	result: int,
	response_code: int,
	headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	# Capture the type of request that was pending *before* resetting state
	var request_type_that_completed: RequestType = _pending_request_type
	# Reset state immediately, allowing new requests
	_pending_request_type = RequestType.NONE

	# Route the response based on the captured state
	if request_type_that_completed == RequestType.TOKEN:
		_handle_token_response(result, response_code, headers, body)
	elif request_type_that_completed == RequestType.REDUCER_CALL:
		_handle_reducer_response(result, response_code, headers, body)
	elif request_type_that_completed == RequestType.NONE:
		# This might happen if the request failed immediately before the state was properly set,
		# or if the signal fires unexpectedly after state reset (less likely).
		push_warning(
			"SpacetimeDBRestAPI: Received request completion signal but no request type was pending."
		)
	else:
		printerr(
			"SpacetimeDBRestAPI: Internal error - completed request type was unknown: ",
			request_type_that_completed,
		)

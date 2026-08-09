## Handle returned by [method SpacetimeDBClient.call_procedure].
##
## Tracks the lifecycle of a single stored-procedure call. Poll [member outcome]
## or [code]await[/code] [method wait_for_response] to get the result bytes.
## Use [method decode] to BSATN-decode the return value.
class_name SpacetimeDBProcedureCall
extends RefCounted

## Lifecycle states of a procedure call.
enum Outcome {
	## Waiting for the server to respond.
	PENDING,
	## Procedure returned successfully.
	RETURNED,
	## Procedure returned an application-level error.
	ERROR,
	## Server encountered an internal error.
	INTERNAL_ERROR,
	## Client timed out waiting for a response.
	TIMEOUT,
	## Connection was lost before a response arrived.
	DISCONNECTED,
}

## Client-assigned request id for correlation.
var request_id: int = -1
## Immediate serialization or send error, or [constant OK].
var error: Error = OK
## Current lifecycle state.
var outcome: Outcome = Outcome.PENDING
## Human-readable error description.
var error_message: String = ""
## BSATN-encoded return value (populated on [constant Outcome.RETURNED]).
var return_bytes: PackedByteArray
## Why the most recent [method decode] returned [code]null[/code], or [code]""[/code]
## when it did not fail. Reset at the start of every [method decode].
var decode_error_message: String = ""
var _return_bsatn_type: StringName = &""
var _client: SpacetimeDBClient


static func create(
	p_client: SpacetimeDBClient,
	p_request_id: int,
	p_return_bsatn_type: StringName = &"",
) -> SpacetimeDBProcedureCall:
	var call: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.new()
	call._client = p_client
	call.request_id = p_request_id
	call._return_bsatn_type = p_return_bsatn_type
	return call


## Creates a pre-failed handle for an immediate client-side error.
static func fail(p_error: Error) -> SpacetimeDBProcedureCall:
	var call: SpacetimeDBProcedureCall = SpacetimeDBProcedureCall.new()
	call.error = p_error
	call.outcome = Outcome.ERROR
	call.error_message = error_string(p_error)
	return call


## Awaits the server response for up to [param timeout_sec] seconds, then returns this
## handle so the unambiguous outcome is available in one step:[br]
## [code]var call := await procedures.foo(args).wait_for_response()[/code][br]
## then inspect [member outcome] / [method is_ok] / [method is_error] / [method decode] /
## [member return_bytes] / [member error_message]. Distinguishes RETURNED / ERROR /
## INTERNAL_ERROR / TIMEOUT / DISCONNECTED instead of an ambiguous empty-array return.
## [param timeout_sec] is resolved before it is waited on — see
## [method SpacetimeDBClient.resolve_wait_timeout] — so a deadline under a frame is
## refused for the default rather than read as an instant timeout.
func wait_for_response(timeout_sec: float = SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS) -> SpacetimeDBProcedureCall:
	# fail() handles carry a null _client; short-circuit before awaiting on it.
	# error != OK covers every fail(err); _client == null also catches fail(OK).
	if error != OK or _client == null:
		return self
	await _client.wait_for_procedure_response(request_id, timeout_sec)
	if outcome == Outcome.PENDING:
		outcome = Outcome.TIMEOUT
		error_message = "Timeout waiting for procedure response"
	return self


## Decodes [member return_bytes] using the BSATN type provided at call time.[br]
## Returns [code]null[/code] if the bytes are empty or no type was specified.
## [br][br]
## A [code]null[/code] is ambiguous on its own — no bytes, no declared type, and a
## failed decode all produce it. Pair it with [method has_return_value] and
## [method has_decode_error] to tell them apart; a failed decode also raises a Godot
## error rather than passing silently. (An [code]opt_[/code] return is not one of the
## ambiguous cases: it decodes to an [Option] whose [method Option.is_none] is true,
## never to a bare [code]null[/code].)
func decode() -> Variant:
	decode_error_message = ""
	if not has_return_value():
		return null
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = return_bytes
	spb.big_endian = false
	spb.seek(0)
	# Main-thread decoder, not the worker's _deserializer (thread-race, see client).
	# Clear any error left by a prior failed decode(): this instance is never reset
	# by worker traffic, so a stale error would make every later decode() null.
	var deserializer: BSATNDeserializer = _client._decode_deserializer
	deserializer.clear_error()
	var value: Variant = deserializer._read_value_from_bsatn_type(
		spb,
		_return_bsatn_type,
		&"procedure_return",
	)
	if deserializer.has_error():
		# get_last_error() clears the deserializer; this handle keeps the message so a
		# caller can still ask what went wrong after the fact.
		decode_error_message = deserializer.get_last_error()
		# Second report on purpose: the deserializer already printerr'd the bare message,
		# but only this one carries the request id and the declared type, and push_error
		# is what puts it in the editor's error list rather than just the output log.
		push_error(
			"SpacetimeDBProcedureCall.decode() failed for request %d (type %s): %s"
			% [request_id, _return_bsatn_type, decode_error_message]
		)
		return null
	return value


## Whether [method decode] has anything to decode: the server sent return bytes AND a
## return type was supplied at call time. [code]false[/code] for a procedure with no
## declared return type and for every non-[constant Outcome.RETURNED] outcome.
func has_return_value() -> bool:
	return _client != null and not return_bytes.is_empty() and not _return_bsatn_type.is_empty()


## Whether the most recent [method decode] failed to parse the bytes the server sent —
## as opposed to there being nothing to decode. See [member decode_error_message].
func has_decode_error() -> bool:
	return not decode_error_message.is_empty()


## Returns [code]true[/code] if the procedure returned successfully.
func is_ok() -> bool:
	return outcome == Outcome.RETURNED


## Returns [code]true[/code] if the procedure ended in any error state.
func is_error() -> bool:
	return (
		outcome == Outcome.ERROR or outcome == Outcome.INTERNAL_ERROR
		or outcome == Outcome.DISCONNECTED
	)


## Returns [code]true[/code] if the call has received a terminal outcome.
func is_completed() -> bool:
	return outcome != Outcome.PENDING

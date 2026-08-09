## Handle returned by [method SpacetimeDBClient.call_reducer].
##
## Tracks the lifecycle of a single reducer call from submission through
## server response. Poll [member outcome] or [code]await[/code]
## [method wait_for_response] to determine the result.
class_name SpacetimeDBReducerCall
extends RefCounted

## Lifecycle states of a reducer call.
enum Outcome {
	## Waiting for the server to respond.
	PENDING,
	## Reducer succeeded and produced database changes.
	OK,
	## Reducer succeeded with no database changes.
	OK_EMPTY,
	## Reducer returned an application-level error.
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
## Current lifecycle state. Updated by the client when the server responds.
var outcome: Outcome = Outcome.PENDING
## Human-readable error description (populated on [constant Outcome.ERROR] or [constant Outcome.INTERNAL_ERROR]).
var error_message: String = ""
## The transaction update from a successful reducer (populated on [constant Outcome.OK]).
var transaction_update: TransactionUpdateMessage = null
## Raw BSATN bytes of the reducer's return value (populated only on [constant Outcome.OK]; empty on [constant Outcome.OK_EMPTY] and all other outcomes).
var ret_value: PackedByteArray = PackedByteArray()
## Why the most recent [method decode] returned [code]null[/code], or [code]""[/code]
## when it did not fail. Reset at the start of every [method decode].
var decode_error_message: String = ""
var _ret_bsatn_type: StringName = &""
var _client: SpacetimeDBClient


static func create(
	p_client: SpacetimeDBClient,
	p_request_id: int,
	p_ret_bsatn_type: StringName = &"",
) -> SpacetimeDBReducerCall:
	var reducer_call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.new()
	reducer_call._client = p_client
	reducer_call.request_id = p_request_id
	reducer_call._ret_bsatn_type = p_ret_bsatn_type
	return reducer_call


## Creates a pre-failed handle for an immediate client-side error.
static func fail(p_error: Error) -> SpacetimeDBReducerCall:
	var reducer_call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.new()
	reducer_call.error = p_error
	reducer_call.outcome = Outcome.ERROR
	reducer_call.error_message = error_string(p_error)
	return reducer_call


## Awaits the server response for up to [param timeout_sec] seconds, then returns this
## handle so the unambiguous outcome is available in one step:[br]
## [code]var call := await reducers.foo(args).wait_for_response()[/code][br]
## then inspect [member outcome] / [method is_ok] / [method is_error] / [method decode] /
## [member transaction_update] / [member error_message]. Unlike a bare [TransactionUpdateMessage]
## return, this distinguishes OK / OK_EMPTY / ERROR / INTERNAL_ERROR / TIMEOUT / DISCONNECTED.
## [param timeout_sec] is resolved before it is waited on — see
## [method SpacetimeDBClient.resolve_wait_timeout] — so a deadline under a frame is
## refused for the default rather than read as an instant timeout.
func wait_for_response(timeout_sec: float = SpacetimeDBClient.DEFAULT_RESPONSE_TIMEOUT_SECONDS) -> SpacetimeDBReducerCall:
	# fail() handles carry a null _client; short-circuit before awaiting on it.
	# error != OK covers every fail(err); _client == null also catches fail(OK).
	if error != OK or _client == null:
		return self
	await _client.wait_for_reducer_response(request_id, timeout_sec)
	if outcome == Outcome.PENDING:
		outcome = Outcome.TIMEOUT
		error_message = "Timeout waiting for reducer response"
	return self


## Decodes [member ret_value] using the reducer's ok return type provided at call
## time.[br] Returns [code]null[/code] if the reducer returned no value (unit) or
## no return type was specified (e.g. a hand-written [method SpacetimeDBClient.call_reducer]).
## [br][br]
## A [code]null[/code] is ambiguous on its own — a unit reducer, a missing return type,
## and a failed decode all produce it. Pair it with [method has_return_value] and
## [method has_decode_error] to tell them apart; a failed decode also raises a Godot
## error rather than passing silently. (An [code]opt_[/code] return is not one of the
## ambiguous cases: it decodes to an [Option] whose [method Option.is_none] is true,
## never to a bare [code]null[/code].)
func decode() -> Variant:
	decode_error_message = ""
	if not has_return_value():
		return null
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	spb.data_array = ret_value
	spb.big_endian = false
	spb.seek(0)
	# Main-thread decoder, not the worker's _deserializer (thread-race, see client).
	# Clear any error left by a prior failed decode(): this instance is never reset
	# by worker traffic, so a stale error would make every later decode() null.
	var deserializer: BSATNDeserializer = _client._decode_deserializer
	deserializer.clear_error()
	var value: Variant = deserializer._read_value_from_bsatn_type(
		spb,
		_ret_bsatn_type,
		&"reducer_return",
	)
	if deserializer.has_error():
		# get_last_error() clears the deserializer; this handle keeps the message so a
		# caller can still ask what went wrong after the fact.
		decode_error_message = deserializer.get_last_error()
		# Second report on purpose: the deserializer already printerr'd the bare message,
		# but only this one carries the request id and the declared type, and push_error
		# is what puts it in the editor's error list rather than just the output log.
		push_error(
			"SpacetimeDBReducerCall.decode() failed for request %d (type %s): %s"
			% [request_id, _ret_bsatn_type, decode_error_message]
		)
		return null
	return value


## Whether [method decode] has anything to decode: the server sent return bytes AND a
## return type was supplied at call time. [code]false[/code] for a unit reducer, for a
## hand-written [method SpacetimeDBClient.call_reducer] with no declared return type, and
## for every non-[constant Outcome.OK] outcome.
func has_return_value() -> bool:
	return _client != null and not ret_value.is_empty() and not _ret_bsatn_type.is_empty()


## Whether the most recent [method decode] failed to parse the bytes the server sent —
## as opposed to there being nothing to decode. See [member decode_error_message].
func has_decode_error() -> bool:
	return not decode_error_message.is_empty()


## Returns [code]true[/code] if the reducer succeeded ([constant Outcome.OK] or [constant Outcome.OK_EMPTY]).
func is_ok() -> bool:
	return outcome == Outcome.OK or outcome == Outcome.OK_EMPTY


## Returns [code]true[/code] if the reducer ended in any error state.
func is_error() -> bool:
	return (
		outcome == Outcome.ERROR or outcome == Outcome.INTERNAL_ERROR
		or outcome == Outcome.DISCONNECTED
	)


## Returns [code]true[/code] if the call has received a terminal outcome (no longer [constant Outcome.PENDING]).
func is_completed() -> bool:
	return outcome != Outcome.PENDING

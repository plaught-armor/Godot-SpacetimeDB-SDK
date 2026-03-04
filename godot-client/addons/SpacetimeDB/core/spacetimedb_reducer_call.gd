class_name SpacetimeDBReducerCall extends RefCounted

enum Outcome { PENDING, OK, OK_EMPTY, ERROR, INTERNAL_ERROR, TIMEOUT, DISCONNECTED }

var request_id: int = -1
var error: Error = OK
var outcome: Outcome = Outcome.PENDING
var error_message: String = ""
var transaction_update: TransactionUpdateMessage = null
var _client: SpacetimeDBClient


static func create(
		p_client: SpacetimeDBClient,
		p_request_id: int,
) -> SpacetimeDBReducerCall:
	var reducer_call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.new()
	reducer_call._client = p_client
	reducer_call.request_id = p_request_id
	return reducer_call


static func fail(p_error: Error) -> SpacetimeDBReducerCall:
	var reducer_call: SpacetimeDBReducerCall = SpacetimeDBReducerCall.new()
	reducer_call.error = p_error
	reducer_call.outcome = Outcome.ERROR
	reducer_call.error_message = error_string(p_error)
	return reducer_call


func wait_for_response(timeout_sec: float = 10) -> TransactionUpdateMessage:
	if error:
		return null
	var res: TransactionUpdateMessage = await _client.wait_for_reducer_response(request_id, timeout_sec)
	if outcome == Outcome.PENDING:
		outcome = Outcome.TIMEOUT
		error_message = "Timeout waiting for reducer response"
	return res


func is_ok() -> bool:
	return outcome == Outcome.OK or outcome == Outcome.OK_EMPTY


func is_error() -> bool:
	return outcome == Outcome.ERROR or outcome == Outcome.INTERNAL_ERROR or outcome == Outcome.DISCONNECTED


func is_completed() -> bool:
	return outcome != Outcome.PENDING

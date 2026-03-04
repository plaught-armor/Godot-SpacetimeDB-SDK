class_name SpacetimeDBProcedureCall extends RefCounted

enum Outcome { PENDING, RETURNED, ERROR, INTERNAL_ERROR, TIMEOUT, DISCONNECTED }

var request_id: int = -1
var error: Error = OK
var outcome: Outcome = Outcome.PENDING
var error_message: String = ""
var return_bytes: PackedByteArray
var _return_bsatn_type: StringName = &""
var _client: SpacetimeDBClient


static func create(
		p_client: SpacetimeDBClient,
		p_request_id: int,
		p_return_bsatn_type: StringName = &"",
) -> SpacetimeDBProcedureCall:
	var call := SpacetimeDBProcedureCall.new()
	call._client = p_client
	call.request_id = p_request_id
	call._return_bsatn_type = p_return_bsatn_type
	return call


static func fail(p_error: Error) -> SpacetimeDBProcedureCall:
	var call := SpacetimeDBProcedureCall.new()
	call.error = p_error
	call.outcome = Outcome.ERROR
	call.error_message = error_string(p_error)
	return call


func wait_for_response(timeout_sec: float = 10) -> PackedByteArray:
	if error:
		return PackedByteArray()
	var res: PackedByteArray = await _client.wait_for_procedure_response(request_id, timeout_sec)
	if outcome == Outcome.PENDING:
		outcome = Outcome.TIMEOUT
		error_message = "Timeout waiting for procedure response"
	return res


func decode() -> Variant:
	if return_bytes.is_empty() or _return_bsatn_type.is_empty():
		return null
	var spb := StreamPeerBuffer.new()
	spb.data_array = return_bytes
	spb.big_endian = false
	spb.seek(0)
	return _client._deserializer._read_value_from_bsatn_type(spb, _return_bsatn_type, &"procedure_return")


func is_ok() -> bool:
	return outcome == Outcome.RETURNED


func is_error() -> bool:
	return outcome == Outcome.ERROR or outcome == Outcome.INTERNAL_ERROR or outcome == Outcome.DISCONNECTED


func is_completed() -> bool:
	return outcome != Outcome.PENDING

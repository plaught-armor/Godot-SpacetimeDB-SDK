class_name ProcedureResultData extends SpacetimeDBServerMessage

var request_id: int
var timestamp: int
var duration: int
var status_tag: int  # 0 = Returned, 1 = InternalError
var return_bytes: PackedByteArray
var error_message: String

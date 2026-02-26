@tool
class_name UpdateStatusData extends RefCounted

enum StatusType {
	COMMITTED,
	FAILED,
	OUT_OF_ENERGY
}

var status_type: StatusType = StatusType.COMMITTED
var committed_update: DatabaseUpdateData # only valid if COMMITTED
var failure_message: String = "" # only valid if FAILED

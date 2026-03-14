## The commit status of a transaction in the v2 protocol.
##
## A transaction can be [constant StatusType.COMMITTED] (with an associated
## [DatabaseUpdateData]), [constant StatusType.FAILED] (with an error message),
## or [constant StatusType.OUT_OF_ENERGY].
@tool
class_name UpdateStatusData
extends RefCounted

## Possible outcomes for a transaction.
enum StatusType {
	## Transaction committed successfully.
	COMMITTED,
	## Transaction failed; see [member failure_message].
	FAILED,
	## Transaction aborted because the module ran out of energy.
	OUT_OF_ENERGY,
}

## The outcome of this transaction.
var status_type: StatusType = StatusType.COMMITTED
## The database changes produced by the transaction (valid only when [member status_type] is [constant StatusType.COMMITTED]).
var committed_update: DatabaseUpdateData
## Error description (valid only when [member status_type] is [constant StatusType.FAILED]).
var failure_message: String = ""

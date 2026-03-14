## Client message that unsubscribes from a previously registered query set.
##
## Serialized with variant tag [constant SpacetimeDBClientMessage.UNSUBSCRIBE].
## The server responds with an [UnsubscribeAppliedMessage].
class_name UnsubscribeMessage
extends SpacetimeDBClientMessage

## Flags controlling unsubscribe behaviour.
enum UnsubscribeFlags {
	## No special behaviour.
	Default,
	## Server sends the dropped rows so the client can remove them locally.
	SendDroppedRows,
}

## BSATN type hints used by the SDK's binary serializer.
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32", &"query_id": &"u32" }

## Client-assigned id used to match this request to its [UnsubscribeAppliedMessage].
@export var request_id: int
## The query set id originally assigned in the corresponding [SubscribeMessage].
@export var query_id: int
## Unsubscribe flags. See [enum UnsubscribeFlags].
@export var flags: UnsubscribeFlags = UnsubscribeFlags.Default


func _init(p_request_id: int = 0, p_query_id: int = 0):
	request_id = p_request_id
	query_id = p_query_id

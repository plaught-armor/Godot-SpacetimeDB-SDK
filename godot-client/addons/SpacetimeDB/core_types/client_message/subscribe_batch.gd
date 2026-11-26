## Client message that registers several query sets in one request.
##
## Serialized with variant tag [constant SpacetimeDBClientMessage.SUBSCRIBE_BATCH]
## (SpacetimeDB 2.10.2+). The server answers with one [SubscribeBatchAppliedMessage]
## holding a result per set, in request order, all computed at one transaction offset.
## The SDK sends it to replay saved subscriptions after an automatic reconnect.
class_name SubscribeBatchMessage
extends SpacetimeDBClientMessage

## BSATN type hints used by the SDK's binary serializer.
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32" }

## Client-assigned id echoed back in [member SubscribeBatchAppliedMessage.request_id].
@export var request_id: int
## The query sets to register, one result per set comes back.
@export var sets: Array[SubscribeSetData]


func _init(p_request_id: int = 0, p_sets: Array[SubscribeSetData] = []) -> void:
	request_id = p_request_id
	sets = p_sets

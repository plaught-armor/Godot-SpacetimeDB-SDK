## One query set inside a [SubscribeBatchMessage].
##
## Wire shape [code]SubscribeSet { query_set_id: QuerySetId(u32), query_strings: Box<[Box<str>]> }[/code].
## Serialized inline, as an element of [member SubscribeBatchMessage.sets]. A [Resource],
## not [RefCounted]: an [code]@export[/code]ed typed array only takes resource elements.
class_name SubscribeSetData
extends Resource

## BSATN type hints used by the SDK's binary serializer.
const BSATN_TYPES: Dictionary[StringName, StringName] = { &"query_set_id": &"u32" }

## Client-assigned query set id these queries register under.
@export var query_set_id: int
## SQL query strings for this set. [code]Array[String][/code] for the same reason as
## [member SubscribeMessage.queries].
@export var query_strings: Array[String] # gdlint: ignore[S6]


func _init(p_query_set_id: int = 0, p_query_strings: Array[String] = []) -> void: # gdlint: ignore[S6]
	query_set_id = p_query_set_id
	query_strings = p_query_strings

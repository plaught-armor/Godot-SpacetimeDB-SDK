@tool
class_name UnsubscribeAppliedMessage extends Resource

@export var request_id: int # u32
@export var query_id: QueryIdData # Nested Resource
@export var rows: SubscribeRowsData # Nested Resource

func _init():
	set_meta("bsatn_type_request_id", "u32")

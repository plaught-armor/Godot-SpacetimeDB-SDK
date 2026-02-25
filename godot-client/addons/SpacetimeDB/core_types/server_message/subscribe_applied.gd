@tool
class_name SubscribeAppliedMessage extends Resource

@export var request_id: int # u32
@export var query_id: QueryIdData # Nested Resource
@export var rows: Array[TableUpdateData] # Nested Resource

func _init():
	query_id = QueryIdData.new()
	set_meta("bsatn_type_request_id", &"u32")
	set_meta("bsatn_type_request_id", &"QueryIdData")
	set_meta("bsatn_type_request_id", &"SubscribeRowsData")

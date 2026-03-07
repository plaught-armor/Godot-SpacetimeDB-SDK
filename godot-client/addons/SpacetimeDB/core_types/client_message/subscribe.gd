class_name SubscribeMessage extends SpacetimeDBClientMessage

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32", &"query_id": &"u32" }

@export var request_id: int
@export var query_id: int
@export var queries: Array[String]

func _init(p_request_id: int = 0, p_query_id: int = 0, p_queries: Array[String] = []):
	request_id = p_request_id
	query_id = p_query_id
	queries = p_queries

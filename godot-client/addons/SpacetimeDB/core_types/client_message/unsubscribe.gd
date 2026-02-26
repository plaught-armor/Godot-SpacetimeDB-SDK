class_name UnsubscribeMessage extends SpacetimeDBClientMessage

enum UnsubscribeFlags {Default, SendDroppedRows}

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32", &"query_id": &"u32" }

@export var request_id: int
@export var query_id: int
@export var flags: UnsubscribeFlags = UnsubscribeFlags.Default

func _init(p_request_id: int = 0, p_query_id: int = 0):
	request_id = p_request_id
	query_id = p_query_id

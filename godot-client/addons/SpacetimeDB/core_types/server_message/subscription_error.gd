@tool
class_name SubscriptionErrorMessage extends SpacetimeDBServerMessage

var request_id: int # u32 or -1 for None
var query_id: QueryIdData # null for None
var error_message: String

func _init():
	request_id = -1 # Default to None
	query_id = null

func has_request_id() -> bool: return request_id != -1
func has_query_id() -> bool: return query_id != null

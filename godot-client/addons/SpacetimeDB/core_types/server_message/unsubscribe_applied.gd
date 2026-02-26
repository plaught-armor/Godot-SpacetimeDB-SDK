@tool
class_name UnsubscribeAppliedMessage extends SpacetimeDBServerMessage

var request_id: int # u32
var query_id: QueryIdData
var tables: Array[TableUpdateData]

func _init():
	query_id = QueryIdData.new()

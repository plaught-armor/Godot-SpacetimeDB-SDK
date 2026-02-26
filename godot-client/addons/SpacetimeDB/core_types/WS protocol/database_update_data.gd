@tool
class_name DatabaseUpdateData extends RefCounted

var query_id: QueryIdData
var tables: Array[TableUpdateData]

func _init():
	query_id = QueryIdData.new()

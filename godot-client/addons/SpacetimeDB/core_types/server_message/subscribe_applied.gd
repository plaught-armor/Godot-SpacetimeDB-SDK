@tool
class_name SubscribeAppliedMessage extends SpacetimeDBServerMessage

## v2 protocol: SubscribeApplied { request_id: u32, query_set_id: QuerySetId, rows: QueryRows }
## QueryRows { tables: Array[SingleTableRows] }
## SingleTableRows { table: String, rows: BsatnRowList }
## We parse SingleTableRows into TableUpdateData for compatibility with LocalDatabase.

var request_id: int # u32
var query_set_id: QueryIdData # maps to query_set_id
var tables: Array[TableUpdateData] # populated from QueryRows.tables during parsing

func _init():
	query_set_id = QueryIdData.new()

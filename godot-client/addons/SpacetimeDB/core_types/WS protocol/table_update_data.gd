@tool
class_name TableUpdateData extends RefCounted

## v2 protocol: TableUpdate { table_name: RawIdentifier, rows: Array[TableUpdateRows] }
## TableUpdateRows is an enum: PersistentTable(inserts, deletes) | EventTable(events)
## We flatten it here: inserts/deletes for persistent tables, events for event tables.

var table_name: StringName
var deletes: Array[Resource] # _ModuleTableType rows (must stay Resource)
var inserts: Array[Resource] # _ModuleTableType rows (must stay Resource)

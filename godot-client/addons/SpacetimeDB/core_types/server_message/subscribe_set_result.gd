## One per-set outcome inside a [SubscribeBatchAppliedMessage].
##
## Wire shape [code]SubscribeSetResult { query_set_id: QuerySetId(u32), outcome: SubscribeSetOutcome }[/code],
## where the outcome is [code]0 = Applied(QueryRows)[/code] or [code]1 = Error(string)[/code].
## A failed set is not registered on the server.
@tool
class_name SubscribeSetResultData
extends RefCounted

## The query set id this result answers.
var query_set_id: int
## [code]true[/code] if the server refused this set.
var is_error: bool = false
## Why the set was refused (valid only when [member is_error] is [code]true[/code]).
var error_message: String = ""
## Initial rows of an applied set, one [TableUpdateData] per table (inserts only).
var tables: Array[TableUpdateData] = []

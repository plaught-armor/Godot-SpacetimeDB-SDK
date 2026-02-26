@tool
class_name ReducerResultMessage
extends SpacetimeDBServerMessage

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32", &"timestamp": &"timestamp", &"reducer_result": &"ReducerOutcomeEnum" }

@export var request_id: int
@export var timestamp: int

var reducer_result: ReducerOutcomeEnum

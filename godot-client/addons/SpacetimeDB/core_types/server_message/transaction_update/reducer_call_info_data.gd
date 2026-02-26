@tool
class_name ReducerCallInfoData extends RefCounted

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"reducer_id": &"u32", &"request_id": &"u32", &"execution_time": &"i64" }

@export var reducer_name: String
@export var reducer_id: int
@export var args: PackedByteArray
@export var request_id: int
@export var execution_time: int

@tool
class_name QueryIdData extends RefCounted

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"id": &"u32" }

@export var id: int

func _init(p_id: int = 0):
	id = p_id

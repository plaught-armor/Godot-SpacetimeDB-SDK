# Fuzz fixture (root): nests a FuzzMid (which nests a FuzzLeaf) plus a trailing i32
# desync canary — any over/under-read inside the nested chain corrupts it.
class_name FuzzRoot
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"mid": &"FuzzMid", &"tail": &"i32" }

@export var mid: FuzzMid
@export var tail: int

# Fuzz fixture (leaf): innermost nested resource. FuzzRoot -> FuzzMid -> FuzzLeaf
# exercises the nested-plan hoist's recursion + per-level error/desync handling.
class_name FuzzLeaf
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"v": &"i32" }

@export var v: int

# Fuzz fixture (mid): nests a FuzzLeaf. One hoist level above the leaf.
class_name FuzzMid
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"leaf": &"FuzzLeaf" }

@export var leaf: FuzzLeaf

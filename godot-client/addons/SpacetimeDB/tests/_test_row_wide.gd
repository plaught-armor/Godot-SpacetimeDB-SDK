# Wider row fixture for profiling: 4 u32 fields + a variable-length String, to
# test whether the in-place parse ever wins when rows carry larger / copied data.
extends Resource

const BSATN_TYPES: Dictionary = { &"id": &"u32", &"x": &"u32", &"y": &"u32", &"hp": &"u32" }

@export var id: int = 0
@export var x: int = 0
@export var y: int = 0
@export var label: String = ""
@export var hp: int = 0

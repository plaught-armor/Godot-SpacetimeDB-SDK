# Row schema fixture for test_nested_array_roundtrip.gd. One nested-array field
# (a Vec<Vec<i32>> on the module side). GDScript can't express Array[Array[int]],
# so codegen emits the field as Array[Array] and the inner nesting lives entirely
# in the BSATN type string (vec_i32 — the outer vec is the GDScript Array itself).
extends Resource

const BSATN_TYPES: Dictionary = { &"grid": &"vec_i32" }

@export var grid: Array[Array] = []

# Row schema with one column per native array-like element type, in the shape
# codegen emits for a `Vec<Vector3>`-style column: the GDScript type carries the
# outer Array and BSATN_TYPES carries the ELEMENT type, component list included.
# Used by test_native_vector_array_roundtrip.gd.
#
# The Array[Vector3] / Array[Color] columns are deliberately NOT the packed
# equivalents S6 would prefer: this file exists to mirror what codegen emits, and
# codegen emits `Array[%s]` from _gd_type_from_nested. Swapping in a packed array
# would test a shape the SDK never sees.
extends Resource

const BSATN_TYPES: Dictionary = {
	&"points": &"vector3[f32,f32,f32]",
	&"cells": &"vector2i[i32,i32]",
	&"tint": &"color[f32,f32,f32,f32]",
	&"spins": &"quaternion[f32,f32,f32,f32]",
}

@export var points: Array[Vector3] = [] # gdlint: ignore[S6]
@export var cells: Array[Vector2i] = []
@export var tint: Array[Color] = [] # gdlint: ignore[S6]
@export var spins: Array[Quaternion] = []

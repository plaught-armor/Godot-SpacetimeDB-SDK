# Flat 16B counterpart to BlackholioEntity (which nests a BlackholioDbVector2).
# Same byte layout (i32, f32, f32, i32) but ZERO nesting — isolates the per-row
# nested-resource re-resolution cost (_read_nested_resource: schema get_type hash
# + _get_or_build_plan hash + _normalize, none hoisted into the plan step).
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = {
	&"a": &"i32",
	&"x": &"f32",
	&"y": &"f32",
	&"b": &"i32",
}

@export var a: int
@export var x: float
@export var y: float
@export var b: int

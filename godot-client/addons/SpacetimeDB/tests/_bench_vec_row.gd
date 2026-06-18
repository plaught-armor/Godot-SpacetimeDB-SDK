# Native-Vector fixture for the hot-path-match bench. 4 Vector3 fields exercise the
# converted matches: _read_native_arraylike (match prop.type) once per field +
# _get_primitive_reader_from_bsatn_type (match bsatn_type) per f32 component.
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = {
	&"a": &"vector3[f32,f32,f32]",
	&"b": &"vector3[f32,f32,f32]",
	&"c": &"vector3[f32,f32,f32]",
	&"d": &"vector3[f32,f32,f32]",
}

@export var a: Vector3
@export var b: Vector3
@export var c: Vector3
@export var d: Vector3

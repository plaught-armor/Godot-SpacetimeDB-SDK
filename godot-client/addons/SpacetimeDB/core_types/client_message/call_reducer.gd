class_name CallReducerMessage extends SpacetimeDBClientMessage

enum CallReducerFlags {
	Default
}

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32", &"flags": &"u8" }

@export var request_id: int
@export var flags: CallReducerFlags
@export var reducer_name: String
@export var args: PackedByteArray

func _init(p_reducer_name: String = "", p_args: PackedByteArray = PackedByteArray(), p_request_id: int = 0, p_flags: CallReducerFlags = CallReducerFlags.Default):
	reducer_name = p_reducer_name
	args = p_args
	request_id = p_request_id
	flags = p_flags

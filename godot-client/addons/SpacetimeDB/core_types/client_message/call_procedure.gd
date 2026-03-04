class_name CallProcedureMessage extends SpacetimeDBClientMessage

enum CallProcedureFlags { Default }

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"request_id": &"u32", &"flags": &"u8" }

@export var request_id: int
@export var flags: CallProcedureFlags
@export var procedure_name: String
@export var args: PackedByteArray

func _init(p_procedure_name: String = "", p_args: PackedByteArray = PackedByteArray(), p_request_id: int = 0, p_flags: CallProcedureFlags = CallProcedureFlags.Default):
	procedure_name = p_procedure_name
	args = p_args
	request_id = p_request_id
	flags = p_flags

@tool
class_name IdentityTokenMessage extends SpacetimeDBServerMessage

const BSATN_TYPES: Dictionary[StringName, StringName] = { &"identity": &"identity", &"connection_id": &"connection_id", &"token": &"string" }

@export var identity: PackedByteArray
@export var connection_id: PackedByteArray
@export var token: String

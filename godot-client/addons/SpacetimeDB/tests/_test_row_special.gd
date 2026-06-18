# Row schema exercising the special/wide BSATN field types through the same
# exported-var + BSATN_TYPES contract codegen emits for generated rows. Used by
# test_special_field_roundtrip.gd to prove these types survive the full
# serialize/deserialize dispatch path (not just the bare reader/writer funcs).
extends Resource

const BSATN_TYPES: Dictionary = {
	&"v_u128": &"u128",
	&"v_i128": &"i128",
	&"v_u256": &"u256",
	&"v_i256": &"i256",
	&"v_uuid": &"u128", # Uuid is Product { __uuid__: u128 } — wire-identical to u128.
	&"v_sched": &"scheduled_at",
}

@export var v_u128: PackedByteArray
@export var v_i128: PackedByteArray
@export var v_u256: PackedByteArray
@export var v_i256: PackedByteArray
@export var v_uuid: PackedByteArray
@export var v_sched: ScheduleAt

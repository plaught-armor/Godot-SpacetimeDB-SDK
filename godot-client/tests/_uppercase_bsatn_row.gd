# Fixture for test_bsatn_type_case: BSATN_TYPES written in the PascalCase spelling
# the schema uses on the wire ("U32"), rather than the lowercase codegen emits.
# The serializer has always lowercased at its metadata read; the deserializer did
# not, so this shape decoded through the Variant.Type fallback instead.
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = {
	&"small": &"U32",
	&"flag": &"Bool",
}

@export var small: int
@export var flag: bool

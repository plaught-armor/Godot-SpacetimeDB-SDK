# Row schema whose second field has no BSATN writer (Transform3D is neither a
# primitive nor one of the native array-like types), so building a serialization
# plan for it always fails. Used by test_serializer_plan_cache.gd to check that
# the failure is reported on every attempt, not just the first.
extends Resource

const BSATN_TYPES: Dictionary = { &"a": &"u32" }

@export var a: int = 0
@export var unwritable: Transform3D = Transform3D.IDENTITY

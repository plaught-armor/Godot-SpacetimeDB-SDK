# Row schema with no storage fields — a legitimately empty serialization plan.
# Used by test_serializer_plan_cache.gd to keep the "don't cache a failed plan"
# fix from turning every empty plan into a rebuild-and-fail.
extends Resource

const BSATN_TYPES: Dictionary = { }

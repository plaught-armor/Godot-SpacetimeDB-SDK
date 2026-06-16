# Minimal row schema for test_row_parse.gd: two little-endian u32 fields, so each
# fixed-size row is 8 bytes. Mirrors the generated row-type contract the
# deserializer introspects (exported vars + a BSATN_TYPES constant map).
extends Resource

const BSATN_TYPES: Dictionary = { &"a": &"u32", &"b": &"u32" }

@export var a: int = 0
@export var b: int = 0

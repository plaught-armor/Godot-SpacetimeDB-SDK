# Fixture for the schema-registry key collision test — stands in for a generated row
# type without needing codegen or a global class_name. Table `user_data`.
extends Resource

const table_names: Array[StringName] = [&"user_data"]
const PRIMARY_KEY: StringName = &"id"
const BSATN_TYPES: Dictionary[StringName, StringName] = {&"id": &"u32"}

@export var id: int = 0

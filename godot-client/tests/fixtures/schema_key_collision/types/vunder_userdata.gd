# Sibling of vunder_user_data.gd whose table name differs from it only by an
# underscore. Both normalize to the same registry key. Table `userdata`.
extends Resource

const table_names: Array[StringName] = [&"userdata"]
const PRIMARY_KEY: StringName = &"other_id"
const BSATN_TYPES: Dictionary[StringName, StringName] = {&"other_id": &"u32"}

@export var other_id: int = 0

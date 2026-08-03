# Fixture: a type with no `table_names` const, so the registry knows it only under its
# filename alias. get_table has to fall back to the normalized key to find it.
extends Resource

const BSATN_TYPES: Dictionary[StringName, StringName] = {&"label": &"string"}

@export var label: String = ""

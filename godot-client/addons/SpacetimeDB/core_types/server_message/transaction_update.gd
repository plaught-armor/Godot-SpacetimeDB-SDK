@tool
class_name TransactionUpdateMessage extends Resource

@export var query_sets: Array[DatabaseUpdateData]

#func _init() -> void:
	#set_meta("bsatn_type_query_sets", &"DatabaseUpdateData")

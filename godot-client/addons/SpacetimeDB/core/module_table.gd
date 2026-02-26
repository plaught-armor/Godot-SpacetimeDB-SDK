class_name _ModuleTable extends RefCounted

var _db: LocalDatabase
var _table_name: StringName

func _init(db: LocalDatabase) -> void:
	_db = db

func count() -> int:
	return _db.count_all_rows(_table_name)

func iter() -> Array:
	return _db.get_all_rows(_table_name)

func on_insert(listener: Callable) -> void:
	_db.subscribe_to_inserts(_table_name, listener)

func remove_on_insert(listener: Callable) -> void:
	_db.unsubscribe_from_inserts(_table_name, listener)

func on_update(listener: Callable) -> void:
	_db.subscribe_to_updates(_table_name, listener)

func remove_on_update(listener: Callable) -> void:
	_db.unsubscribe_from_updates(_table_name, listener)

func on_delete(listener: Callable) -> void:
	_db.subscribe_to_deletes(_table_name, listener)

func remove_on_delete(listener: Callable) -> void:
	_db.unsubscribe_from_deletes(_table_name, listener)

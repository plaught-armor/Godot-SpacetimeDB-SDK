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


func find_where(predicate: Callable) -> Array:
	return _db.find_where(_table_name, predicate)


func first_where(predicate: Callable) -> _ModuleTableType:
	return _db.first_where(_table_name, predicate)


func find_by(field: StringName, value: Variant) -> Array:
	return _db.find_by(_table_name, field, value)


func first_by(field: StringName, value: Variant) -> _ModuleTableType:
	return _db.first_by(_table_name, field, value)


func count_where(predicate: Callable) -> int:
	return _db.count_where(_table_name, predicate)

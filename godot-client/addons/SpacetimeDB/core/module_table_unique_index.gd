class_name _ModuleTableUniqueIndex
extends Resource

var _table_name: StringName
var _field_name: StringName


func _connect_cache_to_db(cache: Dictionary, db: LocalDatabase) -> void:
	db.subscribe_to_inserts(
		_table_name,
		func(r: _ModuleTableType):
			var col_val = r[_field_name]
			cache[col_val] = r
	)
	db.subscribe_to_updates(
		_table_name,
		func(p: _ModuleTableType, r: _ModuleTableType):
			var previous_col_val = p[_field_name]
			var col_val = r[_field_name]

			if previous_col_val != col_val:
				cache.erase(previous_col_val)
			cache[col_val] = r
	)
	db.subscribe_to_deletes(
		_table_name,
		func(r: _ModuleTableType):
			var col_val = r[_field_name]
			cache.erase(col_val)
	)

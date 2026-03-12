## Base class for codegen'd unique index accessors.
##
## Each generated unique index (e.g. [code]WorldPawnStatsPawnIdUniqueIndex[/code])
## extends this and exposes a typed [code]find()[/code] method. Internally keeps
## a dictionary cache that stays in sync with [LocalDatabase] via insert/update/delete
## listeners.
class_name _ModuleTableUniqueIndex
extends Resource

## Normalized table name this index belongs to.
var _table_name: StringName
## The field name used as the unique key.
var _field_name: StringName


## Wires [param cache] to live insert/update/delete callbacks on [param db]
## so the dictionary stays current without manual polling.
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

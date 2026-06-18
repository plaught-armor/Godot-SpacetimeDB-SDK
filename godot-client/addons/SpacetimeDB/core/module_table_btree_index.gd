## Base class for codegen'd btree (non-unique) index accessors.
##
## Each generated btree index (e.g. [code]BlackholioCirclePlayerIdBTreeIndex[/code])
## extends this and exposes a typed [code]filter(col_val) -> Array[Row][/code]
## returning every row whose indexed column equals the given value. Backed by a
## multimap cache (one bucket of rows per distinct column value) kept in sync with
## [LocalDatabase] via insert/update/delete listeners, so a lookup is O(1) on the
## value plus O(k) over the k matching rows, not a linear scan of the whole table.
class_name _ModuleTableBTreeIndex
extends Resource

## Normalized table name this index belongs to.
var _table_name: StringName
## The field name used as the (non-unique) index key.
var _field_name: StringName


## Wires [param cache] (a [code]Dictionary[value, Array[Row]][/code] multimap) to live
## insert/update/delete callbacks on [param db] so each per-value bucket stays current
## without manual polling. Mirrors [_ModuleTableUniqueIndex] but keeps a bucket of rows
## per key instead of a single row.
func _connect_cache_to_db(cache: Dictionary, db: LocalDatabase) -> void:
	db.subscribe_to_inserts(
		_table_name,
		func(r: _ModuleTableType):
			var col_val = r[_field_name]
			if not cache.has(col_val):
				cache[col_val] = []
			cache[col_val].append(r)
	)
	db.subscribe_to_updates(
		_table_name,
		func(p: _ModuleTableType, r: _ModuleTableType):
			var previous_col_val = p[_field_name]
			var col_val = r[_field_name]

			if previous_col_val != col_val:
				if cache.has(previous_col_val):
					cache[previous_col_val].erase(p)
					if cache[previous_col_val].is_empty():
						cache.erase(previous_col_val)
				if not cache.has(col_val):
					cache[col_val] = []
				cache[col_val].append(r)
			elif cache.has(col_val):
				# Same key — swap the stale instance for the new one in place.
				var idx: int = cache[col_val].find(p)
				if idx != -1:
					cache[col_val][idx] = r
				else:
					cache[col_val].append(r)
			else:
				cache[col_val] = [r]
	)
	db.subscribe_to_deletes(
		_table_name,
		func(r: _ModuleTableType):
			var col_val = r[_field_name]
			if cache.has(col_val):
				cache[col_val].erase(r)
				if cache[col_val].is_empty():
					cache.erase(col_val)
	)

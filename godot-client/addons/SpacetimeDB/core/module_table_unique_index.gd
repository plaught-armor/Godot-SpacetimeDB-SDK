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
## Reference to the subclass-owned cache, captured in [method _connect_cache_to_db]
## so the named listeners below can read it (the typed cache lives on the subclass).
var _cache_ref: Dictionary = { }


## Wires [param cache] to live insert/update/delete callbacks on [param db]
## so the dictionary stays current without manual polling. The callbacks read the
## cache via [member _cache_ref] (set here), so they're named methods rather than
## capturing lambdas.
func _connect_cache_to_db(cache: Dictionary, db: LocalDatabase) -> void:
	_cache_ref = cache
	db.subscribe_to_inserts(_table_name, _on_insert)
	db.subscribe_to_updates(_table_name, _on_update)
	db.subscribe_to_deletes(_table_name, _on_delete)
	db.register_index_invalidator(_clear_cache)


## Drops every cached row. Registered with [method LocalDatabase.register_index_invalidator]
## because the delete listener above is not reached by
## [method LocalDatabase.clear_all_tables], which empties the mirror in silence — this
## cache would otherwise keep answering [code]find()[/code] with rows that are gone.
func _clear_cache() -> void:
	_cache_ref.clear()


## Insert listener — maps the row's unique key to the row.
func _on_insert(r: _ModuleTableType) -> void:
	var col_val: Variant = r[_field_name]
	_cache_ref[col_val] = r


## Update listener — moves the row to its new key when the key changed. The old key is
## given up only if this row is still the one holding it: another row may have taken it
## already, since one transaction can hand a unique value over and [LocalDatabase]
## applies its whole insert list before any delete.
func _on_update(p: _ModuleTableType, r: _ModuleTableType) -> void:
	var previous_col_val: Variant = p[_field_name]
	var col_val: Variant = r[_field_name]
	if previous_col_val != col_val and _cache_ref.get(previous_col_val) == p:
		_cache_ref.erase(previous_col_val)
	_cache_ref[col_val] = r


## Delete listener — drops the row's key from the cache, unless the key has already been
## handed to another row. A transaction that deletes the holder of a unique value and
## inserts its successor in the same batch arrives here with the successor already
## cached (inserts are applied first), and erasing by key alone dropped it — leaving the
## generated find() returning null for a row iter() still yields, for good.
func _on_delete(r: _ModuleTableType) -> void:
	var col_val: Variant = r[_field_name]
	if _cache_ref.get(col_val) == r:
		_cache_ref.erase(col_val)

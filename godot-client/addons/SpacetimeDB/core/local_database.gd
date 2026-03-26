## Client-side in-memory mirror of SpacetimeDB tables.
##
## Stores rows keyed by primary key (or in flat arrays for PK-less tables).
## Processes [TableUpdateData] batches from the server, resolves inserts vs
## updates via PK matching, and dispatches per-table listener callbacks and
## signals. Game code normally interacts via [_ModuleTable] wrappers rather
## than calling [LocalDatabase] directly.
class_name LocalDatabase
extends Node

var _tables: Dictionary[StringName, Dictionary] = { }
var _primary_key_cache: Dictionary[StringName, StringName] = { }
var _schema: SpacetimeDBSchema
var _cached_normalized_table_names: Dictionary[StringName, StringName] = { }
var _insert_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _update_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _delete_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _transactions_completed_listeners_by_table: Dictionary[StringName, Array] = { } ## Array[Callable]
var _pk_less_tables: Dictionary[StringName, Array] = { } ## Array[_ModuleTableType]
var _pk_less_property_cache: Dictionary[StringName, Array] = { } ## Array[StringName]

## Emitted after a row is inserted into a table.
signal row_inserted(table_name: StringName, row: _ModuleTableType)
## Emitted after a row is updated (PK match found in inserts + existing data).
signal row_updated(table_name: StringName, old_row: _ModuleTableType, new_row: _ModuleTableType)
## Emitted after a row is deleted from a table.
signal row_deleted(table_name: StringName, row: _ModuleTableType)
## Emitted once after all inserts/deletes in a single [TableUpdateData] are processed.
signal row_transactions_completed(table_name: StringName)


func _init(p_schema: SpacetimeDBSchema) -> void:
	_schema = p_schema
	for raw_name: StringName in p_schema.raw_table_names:
		_tables[raw_name.to_lower()] = { }
	p_schema.raw_table_names.clear() # consumed — free the memory


# --- Normalization helper (#2) ---
# Single shared cache for both apply_table_update and access methods
func _normalize(table_name: StringName) -> StringName:
	if _cached_normalized_table_names.has(table_name):
		return _cached_normalized_table_names[table_name]
	var normalized: StringName = table_name.to_lower()
	_cached_normalized_table_names[table_name] = normalized
	return normalized


## Registers [param callable] to be called with the inserted row for [param table_name].
func subscribe_to_inserts(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _insert_listeners_by_table.has(key):
		_insert_listeners_by_table[key] = []
	if not _insert_listeners_by_table[key].has(callable):
		_insert_listeners_by_table[key].append(callable)


## Removes an insert listener for [param table_name].
func unsubscribe_from_inserts(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _insert_listeners_by_table.has(key):
		_insert_listeners_by_table[key].erase(callable)
		if _insert_listeners_by_table[key].is_empty():
			_insert_listeners_by_table.erase(key)


## Registers [param callable] to be called with [code](old_row, new_row)[/code] for [param table_name].
func subscribe_to_updates(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _update_listeners_by_table.has(key):
		_update_listeners_by_table[key] = []
	if not _update_listeners_by_table[key].has(callable):
		_update_listeners_by_table[key].append(callable)


## Removes an update listener for [param table_name].
func unsubscribe_from_updates(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _update_listeners_by_table.has(key):
		_update_listeners_by_table[key].erase(callable)
		if _update_listeners_by_table[key].is_empty():
			_update_listeners_by_table.erase(key)


## Registers [param callable] to be called with the deleted row for [param table_name].
func subscribe_to_deletes(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _delete_listeners_by_table.has(key):
		_delete_listeners_by_table[key] = []
	if not _delete_listeners_by_table[key].has(callable):
		_delete_listeners_by_table[key].append(callable)


## Removes a delete listener for [param table_name].
func unsubscribe_from_deletes(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _delete_listeners_by_table.has(key):
		_delete_listeners_by_table[key].erase(callable)
		if _delete_listeners_by_table[key].is_empty():
			_delete_listeners_by_table.erase(key)


## Registers [param callable] to be called (no args) after all changes in a batch for [param table_name].
func subscribe_to_transactions_completed(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _transactions_completed_listeners_by_table.has(key):
		_transactions_completed_listeners_by_table[key] = []
	if not _transactions_completed_listeners_by_table[key].has(callable):
		_transactions_completed_listeners_by_table[key].append(callable)


## Removes a transactions-completed listener for [param table_name].
func unsubscribe_from_transactions_completed(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _transactions_completed_listeners_by_table.has(key):
		_transactions_completed_listeners_by_table[key].erase(callable)
		if _transactions_completed_listeners_by_table[key].is_empty():
			_transactions_completed_listeners_by_table.erase(key)


# --- Primary Key Handling (#5) ---
# _primary_key_cache now serves both roles — _cached_pk_fields removed
func _get_primary_key_field(table_name_lower: StringName) -> StringName:
	if _primary_key_cache.has(table_name_lower):
		return _primary_key_cache[table_name_lower]

	# schema.types is still keyed with underscore-stripped names for Rust/filename compat
	var schema_key: StringName = table_name_lower.replace("_", "")
	if not _schema.types.has(schema_key):
		printerr("LocalDatabase: No schema found for table '", table_name_lower, "' to determine PK.")
		return &""

	var schema := _schema.get_type(schema_key)
	var constants: Dictionary = schema.get_script_constant_map()
	if constants.has(&"PRIMARY_KEY"):
		var pk_field: StringName = constants[&"PRIMARY_KEY"]
		_primary_key_cache[table_name_lower] = pk_field
		return pk_field

	var properties := schema.get_script_property_list()
	for prop: Dictionary in properties:
		if prop.usage & PROPERTY_USAGE_STORAGE:
			if prop.name == &"identity" or prop.name == &"id":
				_primary_key_cache[table_name_lower] = prop.name
				return prop.name

	_primary_key_cache[table_name_lower] = &""
	return &""


# --- PK-less Row Helpers ---
func _get_row_properties(table_name_lower: StringName) -> Array[StringName]:
	if _pk_less_property_cache.has(table_name_lower):
		return _pk_less_property_cache[table_name_lower]
	var schema_key: StringName = table_name_lower.replace("_", "")
	if not _schema.types.has(schema_key):
		return []
	var schema := _schema.get_type(schema_key)
	var props: Array[StringName] = []
	for prop: Dictionary in schema.get_script_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE:
			props.append(prop.name)
	_pk_less_property_cache[table_name_lower] = props
	return props


func _rows_equal(a: _ModuleTableType, b: _ModuleTableType, props: Array[StringName]) -> bool:
	for prop_name: StringName in props:
		if a.get(prop_name) != b.get(prop_name):
			return false
	return true


func _row_hash(row: _ModuleTableType, props: Array[StringName]) -> int:
	var h: int = 0
	for prop_name: StringName in props:
		h = h * 31 + hash(row.get(prop_name))
	return h


## Applies all table updates from a [SubscribeAppliedMessage] to the local store.
func apply_database_subscription_applied(db_update: SubscribeAppliedMessage) -> void:
	if not db_update:
		return
	for table_update: TableUpdateData in db_update.tables:
		apply_table_update(table_update)


## Applies all table updates from a [DatabaseUpdateData] to the local store.
func apply_database_update(db_update: DatabaseUpdateData) -> void:
	if not db_update:
		return
	for table_update: TableUpdateData in db_update.tables:
		apply_table_update(table_update)


## Applies a single [TableUpdateData] — processes inserts then deletes, dispatches
## listener callbacks and signals, and handles both PK-keyed and PK-less tables.
func apply_table_update(table_update: TableUpdateData) -> void:
	var table_name_lower: StringName = _normalize(table_update.table_name)

	if not _tables.has(table_name_lower):
		printerr("LocalDatabase: Received update for unknown table '", table_update.table_name, "' (normalized: '", table_name_lower, "')")
		return

	var pk_field: StringName = _get_primary_key_field(table_name_lower)

	# Hoist listener array lookups once per table_update, not per row
	var insert_listeners: Array = _insert_listeners_by_table.get(table_name_lower, [])
	var update_listeners: Array = _update_listeners_by_table.get(table_name_lower, [])
	var delete_listeners: Array = _delete_listeners_by_table.get(table_name_lower, [])
	var tx_listeners: Array = _transactions_completed_listeners_by_table.get(table_name_lower, [])
	var has_insert_listeners: bool = not insert_listeners.is_empty()
	var has_update_listeners: bool = not update_listeners.is_empty()
	var has_delete_listeners: bool = not delete_listeners.is_empty()

	var table_dict: Dictionary = _tables[table_name_lower]
	var inserted_pks_set: Dictionary = { }
	var had_any_change: bool = false

	if pk_field == &"":
		# PK-less table: array-based storage with property-level matching for deletes
		if not _pk_less_tables.has(table_name_lower):
			_pk_less_tables[table_name_lower] = []
		var rows_array: Array = _pk_less_tables[table_name_lower]
		var props: Array[StringName] = _get_row_properties(table_name_lower)

		for inserted_row: _ModuleTableType in table_update.inserts:
			rows_array.append(inserted_row)
			had_any_change = true
			if has_insert_listeners:
				for listener: Callable in insert_listeners:
					listener.call(inserted_row)
			row_inserted.emit(table_name_lower, inserted_row)

		# Build hash-based multiset of rows to delete: O(m*p) instead of O(n*m*p) scanning
		if not table_update.deletes.is_empty():
			var delete_set: Dictionary = { } # hash -> Array of [row, count]
			for deleted_row: _ModuleTableType in table_update.deletes:
				var h: int = _row_hash(deleted_row, props)
				if not delete_set.has(h):
					delete_set[h] = []
				var bucket: Array = delete_set[h]
				var matched: bool = false
				for entry: Array in bucket:
					if _rows_equal(entry[0], deleted_row, props):
						entry[1] += 1
						matched = true
						break
				if not matched:
					bucket.append([deleted_row, 1])

			# Single pass compact — avoids repeated remove_at() shifts
			var write_idx: int = 0
			for read_idx: int in range(rows_array.size()):
				var row: _ModuleTableType = rows_array[read_idx]
				var h: int = _row_hash(row, props)
				var removed: bool = false
				if delete_set.has(h):
					for entry: Array in delete_set[h]:
						if entry[1] > 0 and _rows_equal(row, entry[0], props):
							entry[1] -= 1
							removed = true
							had_any_change = true
							if has_delete_listeners:
								for listener: Callable in delete_listeners:
									listener.call(row)
							row_deleted.emit(table_name_lower, row)
							break
				if not removed:
					rows_array[write_idx] = row
					write_idx += 1
			rows_array.resize(write_idx)

		if had_any_change:
			for listener: Callable in tx_listeners:
				listener.call()
			row_transactions_completed.emit(table_name_lower)
		return

	for inserted_row: _ModuleTableType in table_update.inserts:
		var pk_value: Variant = inserted_row.get(pk_field)
		if pk_value == null:
			push_error("LocalDatabase: Inserted row for table '", table_name_lower, "' has null PK '", pk_field, "'. Skipping.")
			continue
		inserted_pks_set[pk_value] = true
		var prev_row: _ModuleTableType = table_dict.get(pk_value, null)
		table_dict[pk_value] = inserted_row
		had_any_change = true
		if prev_row != null:
			if has_update_listeners:
				for listener: Callable in update_listeners:
					listener.call(prev_row, inserted_row)
			row_updated.emit(table_name_lower, prev_row, inserted_row)
		else:
			if has_insert_listeners:
				for listener: Callable in insert_listeners:
					listener.call(inserted_row)
			row_inserted.emit(table_name_lower, inserted_row)

	for deleted_row: _ModuleTableType in table_update.deletes:
		var pk_value: Variant = deleted_row.get(pk_field)
		if pk_value == null:
			push_warning("LocalDatabase: Deleted row for table '", table_name_lower, "' has null PK '", pk_field, "'. Skipping.")
			continue
		if not inserted_pks_set.has(pk_value):
			if table_dict.erase(pk_value):
				had_any_change = true
				if has_delete_listeners:
					for listener: Callable in delete_listeners:
						listener.call(deleted_row)
				row_deleted.emit(table_name_lower, deleted_row)

	if had_any_change:
		for listener: Callable in tx_listeners:
			listener.call()
		row_transactions_completed.emit(table_name_lower)


## Returns a single row by its primary key [param primary_key_value], or [code]null[/code].
func get_row_by_pk(table_name: StringName, primary_key_value: Variant) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if not _tables.has(key):
		return null
	return _tables[key].get(primary_key_value, null)


## Returns all rows in [param table_name] as a typed array.
func get_all_rows(table_name: StringName) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		var result: Array[_ModuleTableType] = []
		result.assign(_pk_less_tables[key])
		return result
	if not _tables.has(key):
		return []
	var result: Array[_ModuleTableType] = []
	result.assign(_tables[key].values())
	return result


## Returns the number of rows in [param table_name].
func count_all_rows(table_name: StringName) -> int:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		return _pk_less_tables[key].size()
	if not _tables.has(key):
		return 0
	return _tables[key].size()


## Returns all rows in [param table_name] for which [param predicate] returns [code]true[/code].
func find_where(table_name: StringName, predicate: Callable) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	var result: Array[_ModuleTableType] = []
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if predicate.call(row):
				result.append(row)
	elif _tables.has(key):
		for row: _ModuleTableType in _tables[key].values():
			if predicate.call(row):
				result.append(row)
	return result


## Returns the first row matching [param predicate], or [code]null[/code].
func first_where(table_name: StringName, predicate: Callable) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if predicate.call(row):
				return row
	elif _tables.has(key):
		for row: _ModuleTableType in _tables[key].values():
			if predicate.call(row):
				return row
	return null


## Returns all rows where [param field] equals [param value].
func find_by(table_name: StringName, field: StringName, value: Variant) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	var result: Array[_ModuleTableType] = []
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if row.get(field) == value:
				result.append(row)
	elif _tables.has(key):
		for row: _ModuleTableType in _tables[key].values():
			if row.get(field) == value:
				result.append(row)
	return result


## Returns the first row where [param field] equals [param value], or [code]null[/code].
func first_by(table_name: StringName, field: StringName, value: Variant) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if row.get(field) == value:
				return row
	elif _tables.has(key):
		for row: _ModuleTableType in _tables[key].values():
			if row.get(field) == value:
				return row
	return null


## Returns the count of rows matching [param predicate].
func count_where(table_name: StringName, predicate: Callable) -> int:
	var key: StringName = _normalize(table_name)
	var c: int = 0
	if _pk_less_tables.has(key):
		for row: _ModuleTableType in _pk_less_tables[key]:
			if predicate.call(row):
				c += 1
	elif _tables.has(key):
		for row: _ModuleTableType in _tables[key].values():
			if predicate.call(row):
				c += 1
	return c


## Erases all rows from every table. Used during reconnection to reset state.
func clear_all_tables() -> void:
	for table_name: StringName in _tables:
		_tables[table_name].clear()
	for table_name: StringName in _pk_less_tables:
		_pk_less_tables[table_name].clear()

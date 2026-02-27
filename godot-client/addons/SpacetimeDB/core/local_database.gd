class_name LocalDatabase extends Node

var _tables: Dictionary[StringName, Dictionary] = {}
var _primary_key_cache: Dictionary[StringName, StringName] = {}  # #5: also serves as pk_fields cache
var _schema: SpacetimeDBSchema
var _cached_normalized_table_names: Dictionary[StringName, StringName] = {}
# #3: Fully typed listener dicts
var _insert_listeners_by_table: Dictionary[StringName, Array] = {}
var _update_listeners_by_table: Dictionary[StringName, Array] = {}
var _delete_listeners_by_table: Dictionary[StringName, Array] = {}
var _transactions_completed_listeners_by_table: Dictionary[StringName, Array] = {}

# #6: Signals use StringName
signal row_inserted(table_name: StringName, row: _ModuleTableType)
signal row_updated(table_name: StringName, old_row: _ModuleTableType, new_row: _ModuleTableType)
signal row_deleted(table_name: StringName, row: _ModuleTableType)
signal row_transactions_completed(table_name: StringName)

func _init(p_schema: SpacetimeDBSchema) -> void:
	_schema = p_schema
	for raw_name: StringName in p_schema.raw_table_names:
		_tables[raw_name.to_lower()] = {}
	p_schema.raw_table_names.clear() # consumed — free the memory


# --- Normalization helper (#2) ---
# Single shared cache for both apply_table_update and access methods
func _normalize(table_name: StringName) -> StringName:
	if _cached_normalized_table_names.has(table_name):
		return _cached_normalized_table_names[table_name]
	var normalized: StringName = table_name.to_lower()
	_cached_normalized_table_names[table_name] = normalized
	return normalized

func subscribe_to_inserts(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _insert_listeners_by_table.has(key):
		_insert_listeners_by_table[key] = []
	if not _insert_listeners_by_table[key].has(callable):
		_insert_listeners_by_table[key].append(callable)

func unsubscribe_from_inserts(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _insert_listeners_by_table.has(key):
		_insert_listeners_by_table[key].erase(callable)
		if _insert_listeners_by_table[key].is_empty():
			_insert_listeners_by_table.erase(key)

func subscribe_to_updates(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _update_listeners_by_table.has(key):
		_update_listeners_by_table[key] = []
	if not _update_listeners_by_table[key].has(callable):
		_update_listeners_by_table[key].append(callable)

func unsubscribe_from_updates(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _update_listeners_by_table.has(key):
		_update_listeners_by_table[key].erase(callable)
		if _update_listeners_by_table[key].is_empty():
			_update_listeners_by_table.erase(key)

func subscribe_to_deletes(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _delete_listeners_by_table.has(key):
		_delete_listeners_by_table[key] = []
	if not _delete_listeners_by_table[key].has(callable):
		_delete_listeners_by_table[key].append(callable)

func unsubscribe_from_deletes(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if _delete_listeners_by_table.has(key):
		_delete_listeners_by_table[key].erase(callable)
		if _delete_listeners_by_table[key].is_empty():
			_delete_listeners_by_table.erase(key)

func subscribe_to_transactions_completed(table_name: StringName, callable: Callable) -> void:
	var key: StringName = _normalize(table_name)
	if not _transactions_completed_listeners_by_table.has(key):
		_transactions_completed_listeners_by_table[key] = []
	if not _transactions_completed_listeners_by_table[key].has(callable):
		_transactions_completed_listeners_by_table[key].append(callable)

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

	print_debug("LocalDatabase: table %s has no primary_key" % table_name_lower)
	_primary_key_cache[table_name_lower] = &""
	return &""


# --- Applying Updates ---
func apply_database_subscription_applied(db_update: SubscribeAppliedMessage) -> void:
	if not db_update:
		return
	for table_update: TableUpdateData in db_update.tables:
		apply_table_update(table_update)

func apply_database_update(db_update: DatabaseUpdateData) -> void:
	if not db_update:
		return
	for table_update: TableUpdateData in db_update.tables:
		apply_table_update(table_update)

# Fused update + callback dispatch — no intermediary collections, no second pass.
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
	var inserted_pks_set: Dictionary = {}
	var had_any_change: bool = false

	if pk_field == &"":
		# No PK — emit inserts/deletes as-is without dedup
		for inserted_row: _ModuleTableType in table_update.inserts:
			had_any_change = true
			if has_insert_listeners:
				for listener: Callable in insert_listeners:
					listener.call(inserted_row)
			row_inserted.emit(table_name_lower, inserted_row)
		for deleted_row: _ModuleTableType in table_update.deletes:
			had_any_change = true
			if has_delete_listeners:
				for listener: Callable in delete_listeners:
					listener.call(deleted_row)
			row_deleted.emit(table_name_lower, deleted_row)
		if had_any_change:
			for listener: Callable in tx_listeners:
				listener.call()
			if not tx_listeners.is_empty():
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
		if not tx_listeners.is_empty():
			row_transactions_completed.emit(table_name_lower)



# --- Access Methods (#2) ---
# StringName params + shared _normalize cache — no raw string ops on each call
func get_row_by_pk(table_name: StringName, primary_key_value: Variant) -> _ModuleTableType:
	var key: StringName = _normalize(table_name)
	if not _tables.has(key):
		return null
	return _tables[key].get(primary_key_value, null)

func get_all_rows(table_name: StringName) -> Array[_ModuleTableType]:
	var key: StringName = _normalize(table_name)
	if not _tables.has(key):
		return []
	var result: Array[_ModuleTableType] = []
	result.assign(_tables[key].values())
	return result

func count_all_rows(table_name: StringName) -> int:
	var key: StringName = _normalize(table_name)
	if not _tables.has(key):
		return 0
	return _tables[key].size()

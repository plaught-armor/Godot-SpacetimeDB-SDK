class_name LocalDatabase extends Node

var _tables: Dictionary[StringName, Dictionary] = {}
var _primary_key_cache: Dictionary[StringName, StringName] = {}  # #5: also serves as pk_fields cache
var _schema: SpacetimeDBSchema
var _cached_normalized_table_names: Dictionary[StringName, StringName] = {}
# #3: Fully typed listener dicts
var _insert_listeners_by_table: Dictionary[StringName, Array] = {}
var _update_listeners_by_table: Dictionary[StringName, Array] = {}
var _delete_listeners_by_table: Dictionary[StringName, Array] = {}
var _delete_key_listeners_by_table: Dictionary[StringName, Array] = {}
var _transactions_completed_listeners_by_table: Dictionary[StringName, Array] = {}

# #6: Signals use StringName
signal row_inserted(table_name: StringName, row: _ModuleTableType)
signal row_updated(table_name: StringName, old_row: _ModuleTableType, new_row: _ModuleTableType)
signal row_deleted(table_name: StringName, row: _ModuleTableType)
signal row_transactions_completed(table_name: StringName)

func _init(p_schema: SpacetimeDBSchema) -> void:
	_schema = p_schema
	for table_name_lower: StringName in _schema.tables.keys():
		_tables[table_name_lower] = {}


# --- Normalization helper (#2) ---
# Single shared cache for both apply_table_update and access methods
func _normalize(table_name: StringName) -> StringName:
	var cached: StringName = _cached_normalized_table_names.get(table_name, &"")
	if cached != &"":
		return cached
	var normalized: StringName = table_name.to_lower().replace("_", "")
	_cached_normalized_table_names[table_name] = normalized
	return normalized

func subscribe_to_inserts(table_name: StringName, callable: Callable) -> void:
	if not _insert_listeners_by_table.has(table_name):
		_insert_listeners_by_table[table_name] = []
	if not _insert_listeners_by_table[table_name].has(callable):
		_insert_listeners_by_table[table_name].append(callable)


func unsubscribe_from_inserts(table_name: StringName, callable: Callable) -> void:
	if _insert_listeners_by_table.has(table_name):
		_insert_listeners_by_table[table_name].erase(callable)
		if _insert_listeners_by_table[table_name].is_empty():
			_insert_listeners_by_table.erase(table_name)

func subscribe_to_updates(table_name: StringName, callable: Callable) -> void:
	if not _update_listeners_by_table.has(table_name):
		_update_listeners_by_table[table_name] = []
	if not _update_listeners_by_table[table_name].has(callable):
		_update_listeners_by_table[table_name].append(callable)

func unsubscribe_from_updates(table_name: StringName, callable: Callable) -> void:
	if _update_listeners_by_table.has(table_name):
		_update_listeners_by_table[table_name].erase(callable)
		if _update_listeners_by_table[table_name].is_empty():
			_update_listeners_by_table.erase(table_name)

func subscribe_to_deletes(table_name: StringName, callable: Callable) -> void:
	if not _delete_listeners_by_table.has(table_name):
		_delete_listeners_by_table[table_name] = []
	if not _delete_listeners_by_table[table_name].has(callable):
		_delete_listeners_by_table[table_name].append(callable)

func unsubscribe_from_deletes(table_name: StringName, callable: Callable) -> void:
	if _delete_listeners_by_table.has(table_name):
		_delete_listeners_by_table[table_name].erase(callable)
		if _delete_listeners_by_table[table_name].is_empty():
			_delete_listeners_by_table.erase(table_name)

func subscribe_to_transactions_completed(table_name: StringName, callable: Callable) -> void:
	if not _transactions_completed_listeners_by_table.has(table_name):
		_transactions_completed_listeners_by_table[table_name] = []
	if not _transactions_completed_listeners_by_table[table_name].has(callable):
		_transactions_completed_listeners_by_table[table_name].append(callable)

func unsubscribe_from_transactions_completed(table_name: StringName, callable: Callable) -> void:
	if _transactions_completed_listeners_by_table.has(table_name):
		_transactions_completed_listeners_by_table[table_name].erase(callable)
		if _transactions_completed_listeners_by_table[table_name].is_empty():
			_transactions_completed_listeners_by_table.erase(table_name)

# --- Primary Key Handling (#5) ---
# _primary_key_cache now serves both roles — _cached_pk_fields removed
func _get_primary_key_field(table_name_lower: StringName) -> StringName:
	if _primary_key_cache.has(table_name_lower):
		return _primary_key_cache[table_name_lower]

	if not _schema.types.has(table_name_lower):
		printerr("LocalDatabase: No schema found for table '", table_name_lower, "' to determine PK.")
		return &""

	var schema := _schema.get_type(table_name_lower)
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
	var changes: Array[Dictionary] = []
	for table_update: TableUpdateData in db_update.tables:
		changes.append(apply_table_update(table_update))
	emit_db_callbacks(changes)

func apply_database_update(db_update: DatabaseUpdateData) -> void:
	if not db_update:
		return
	var changes: Array[Dictionary] = []
	for table_update: TableUpdateData in db_update.tables:
		changes.append(apply_table_update(table_update))
	emit_db_callbacks(changes)

func emit_db_callbacks(changes: Array[Dictionary]) -> void:
	for change: Dictionary in changes:
		# #1: table_name is a plain StringName, not wrapped in an array
		var table_name: StringName = change.get(&"table_name", &"")
		if table_name == &"":
			continue

		for insert: Array in change.get(&"inserts", []):
			for listener: Callable in _insert_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					push_error("LocalDB: insert callback is not valid: skipped")
					continue
				listener.call(insert[0])
			row_inserted.emit(table_name, insert[0])

		for update: Array in change.get(&"updates", []):
			for listener: Callable in _update_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					push_error("LocalDB: update callback is not valid: skipped")
					continue
				listener.call(update[0], update[1])
			row_updated.emit(table_name, update[0], update[1])

		for delete: Array in change.get(&"deletes", []):
			for listener: Callable in _delete_listeners_by_table.get(table_name, []):
				if not listener.is_valid():
					push_error("LocalDB: delete callback is not valid: skipped")
					continue
				listener.call(delete[0])
			row_deleted.emit(table_name, delete[0])

		var tx_listeners: Array = _transactions_completed_listeners_by_table.get(table_name, [])
		for listener: Callable in tx_listeners:
			if not listener.is_valid():
				push_error("LocalDB: transaction_completed callback is not valid: skipped")
				continue
			listener.call()
		if not tx_listeners.is_empty():
			row_transactions_completed.emit(table_name)

# #1: StringName keys; #4: listener checks use table_name_lower matching registration
func apply_table_update(table_update: TableUpdateData) -> Dictionary:
	var table_name_lower: StringName = _normalize(StringName(table_update.table_name))

	if not _tables.has(table_name_lower):
		printerr("LocalDatabase: Received update for unknown table '", table_update.table_name, "' (normalized: '", table_name_lower, "')")
		return {&"table_name": &"", &"inserts": [], &"updates": [], &"deletes": []}

	# #5: _primary_key_cache already caches internally — no separate _cached_pk_fields needed
	var pk_field: StringName = _get_primary_key_field(table_name_lower)
	if pk_field == &"":
		return {
			&"table_name": table_name_lower,
			&"inserts": [table_update.inserts] if not table_update.inserts.is_empty() else [],
			&"updates": [],
			&"deletes": [table_update.deletes] if not table_update.deletes.is_empty() else [],
		}

	var table_dict: Dictionary = _tables[table_name_lower]
	var inserted_pks_set: Dictionary = {}
	var inserts_to_emit: Array = []
	var updates_to_emit: Array = []
	var deletes_to_emit: Array = []

	for inserted_row: _ModuleTableType in table_update.inserts:
		var pk_value: Variant = inserted_row.get(pk_field)
		if pk_value == null:
			push_error("LocalDatabase: Inserted row for table '", table_name_lower, "' has null PK for field '", pk_field, "'. Skipping.")
			continue
		inserted_pks_set[pk_value] = true
		var prev_row: _ModuleTableType = table_dict.get(pk_value, null)
		table_dict[pk_value] = inserted_row
		# #4: was using table_name_original — now uses table_name_lower to match how listeners register
		if prev_row != null:
			if _update_listeners_by_table.has(table_name_lower):
				updates_to_emit.append([prev_row, inserted_row])
		else:
			if _insert_listeners_by_table.has(table_name_lower):
				inserts_to_emit.append([inserted_row])

	for deleted_row: _ModuleTableType in table_update.deletes:
		var pk_value: Variant = deleted_row.get(pk_field)
		if pk_value == null:
			push_warning("LocalDatabase: Deleted row for table '", table_name_lower, "' has null PK for field '", pk_field, "'. Skipping.")
			continue
		if not inserted_pks_set.has(pk_value):
			if table_dict.erase(pk_value):
				if _delete_listeners_by_table.has(table_name_lower):  # #4: same fix
					deletes_to_emit.append([deleted_row])

	return {
		&"table_name": table_name_lower,
		&"inserts": inserts_to_emit,
		&"updates": updates_to_emit,
		&"deletes": deletes_to_emit,
	}



# --- Access Methods (#2) ---
# StringName params + shared _normalize cache — no raw string ops on each call
func get_row_by_pk(table_name: StringName, primary_key_value: Variant) -> _ModuleTableType:
	return _tables.get(_normalize(table_name), {}).get(primary_key_value, null)

func get_all_rows(table_name: StringName) -> Array[_ModuleTableType]:
	var result: Array[_ModuleTableType] = []
	result.assign(_tables.get(_normalize(table_name), {}).values())
	return result

func count_all_rows(table_name: StringName) -> int:
	return _tables.get(_normalize(table_name), {}).size()

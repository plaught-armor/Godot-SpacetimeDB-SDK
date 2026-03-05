class_name SpacetimeDBQuery extends RefCounted

static var _identifier_regex: RegEx

var _table_name: String
var _conditions: Array[String] = []

# --- Construction ---

static func table(name: String) -> SpacetimeDBQuery:
	var q := SpacetimeDBQuery.new()
	q._table_name = _validate_identifier(name)
	return q


static func from(t: _ModuleTable) -> SpacetimeDBQuery:
	var q := SpacetimeDBQuery.new()
	q._table_name = t._table_name
	return q


# --- WHERE conditions (all AND'd) ---

func where(field: String, value: Variant) -> SpacetimeDBQuery:
	_conditions.append("%s = %s" % [_validate_identifier(field), _format_value(value)])
	return self


func where_ne(field: String, value: Variant) -> SpacetimeDBQuery:
	_conditions.append("%s != %s" % [_validate_identifier(field), _format_value(value)])
	return self


func where_gt(field: String, value: Variant) -> SpacetimeDBQuery:
	_conditions.append("%s > %s" % [_validate_identifier(field), _format_value(value)])
	return self


func where_lt(field: String, value: Variant) -> SpacetimeDBQuery:
	_conditions.append("%s < %s" % [_validate_identifier(field), _format_value(value)])
	return self


func where_gte(field: String, value: Variant) -> SpacetimeDBQuery:
	_conditions.append("%s >= %s" % [_validate_identifier(field), _format_value(value)])
	return self


func where_lte(field: String, value: Variant) -> SpacetimeDBQuery:
	_conditions.append("%s <= %s" % [_validate_identifier(field), _format_value(value)])
	return self


# --- Output ---

func to_sql() -> String:
	var sql := "SELECT * FROM %s" % _table_name
	if not _conditions.is_empty():
		sql += " WHERE " + " AND ".join(_conditions)
	return sql


func _to_string() -> String:
	return to_sql()


# --- Value formatting with proper escaping ---

static func _format_value(value: Variant) -> String:
	match typeof(value):
		TYPE_STRING:
			return "'%s'" % value.replace("'", "''")
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_PACKED_BYTE_ARRAY:
			return "'0x%s'" % (value as PackedByteArray).hex_encode()
		_:
			return str(value)


# --- Identifier validation ---

static func _validate_identifier(name: Variant) -> String:
	var s: String = str(name)
	if _identifier_regex == null:
		_identifier_regex = RegEx.new()
		_identifier_regex.compile("^[a-zA-Z_][a-zA-Z0-9_]*$")
	if not _identifier_regex.search(s):
		push_error("SpacetimeDBQuery: Invalid SQL identifier '%s'. Only alphanumeric characters and underscores are allowed." % s)
		return ""
	return s


# --- Convenience for identity hex encoding ---

static func identity(bytes: PackedByteArray) -> String:
	return "'0x%s'" % bytes.hex_encode()

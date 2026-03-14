## Decodes BSATN binary data from SpacetimeDB server messages into GDScript values.
##
## Used internally by [SpacetimeDBClient] to parse raw WebSocket packets into
## typed [SpacetimeDBServerMessage] subclasses. Provides low-level primitive
## readers ([method read_u8], [method read_i32], [method read_string], etc.)
## and a plan-based resource deserializer that populates a [Resource]'s exported
## properties from a byte stream.
##
## Check [method has_error] after any deserialization call; if [code]true[/code],
## retrieve the message via [method get_last_error].
class_name BSATNDeserializer
extends RefCounted

const MAX_STRING_LEN: int = 4 * 1024 * 1024 # 4 MiB
const MAX_VEC_LEN: int = 131072
const MAX_BYTE_ARRAY_LEN: int = 16 * 1024 * 1024 # 16 MiB
const IDENTITY_SIZE: int = 32
const CONNECTION_ID_SIZE: int = 16
const U128_SIZE: int = 16
const ROW_LIST_FIXED_SIZE: int = 0
const ROW_LIST_ROW_OFFSETS: int = 1
const NATIVE_ARRAYLIKE: Array[Variant.Type] = [
	TYPE_VECTOR2,
	TYPE_VECTOR2I,
	TYPE_VECTOR3,
	TYPE_VECTOR3I,
	TYPE_VECTOR4,
	TYPE_VECTOR4I,
	TYPE_QUATERNION,
	TYPE_COLOR,
]

var debug_mode: bool = false
var _has_error: bool = false
var _last_error: String = ""
var _deserialization_plan_cache: Dictionary[Script, Array] = { }
var _pending_data: PackedByteArray = []
var _schema: SpacetimeDBSchema
var _native_arraylike_regex := RegEx.new()
var _normalized_name_cache: Dictionary[StringName, StringName] = { }


func _init(p_schema: SpacetimeDBSchema, p_debug_mode: bool = false) -> void:
	debug_mode = p_debug_mode
	_schema = p_schema
	_native_arraylike_regex.compile("^(?<struct>.+)\\[(?<components>.*)\\]$")


func _normalize(name: StringName) -> StringName:
	var cached: StringName = _normalized_name_cache.get(name, &"")
	if cached != &"":
		return cached
	var normalized: StringName = name.to_lower().replace("_", "")
	_normalized_name_cache[name] = normalized
	return normalized

#--- Error Handling ---


## Returns [code]true[/code] if the last deserialization operation failed.
func has_error() -> bool:
	return _has_error


## Returns and clears the last error message. Resets [method has_error] to [code]false[/code].
func get_last_error() -> String:
	var err: String = _last_error
	_last_error = ""
	_has_error = false
	return err


## Clears the error state without returning the message.
func clear_error() -> void:
	_last_error = ""
	_has_error = false


#--- Primitive Readers ---
func read_i8(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 1):
		return 0
	return spb.get_8()


func read_i16_le(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 2):
		return 0
	spb.big_endian = false
	return spb.get_16()


func read_i32_le(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 4):
		return 0
	spb.big_endian = false
	return spb.get_32()


func read_i64_le(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 8):
		return 0
	spb.big_endian = false
	return spb.get_64()


func read_u8(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 1):
		return 0
	return spb.get_u8()


func read_u16_le(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 2):
		return 0
	spb.big_endian = false
	return spb.get_u16()


func read_u32_le(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 4):
		return 0
	spb.big_endian = false
	return spb.get_u32()


func read_u64_le(spb: StreamPeerBuffer) -> int:
	if not _check_read(spb, 8):
		return 0
	spb.big_endian = false
	return spb.get_u64()


func read_u128(spb: StreamPeerBuffer) -> PackedByteArray:
	var num: PackedByteArray = read_bytes(spb, U128_SIZE)
	num.reverse() # We receive the bytes in reverse
	return num


func read_f32_le(spb: StreamPeerBuffer) -> float:
	if not _check_read(spb, 4):
		return 0.0
	spb.big_endian = false
	return spb.get_float()


func read_f64_le(spb: StreamPeerBuffer) -> float:
	if not _check_read(spb, 8):
		return 0.0
	spb.big_endian = false
	return spb.get_double()


func read_bool(spb: StreamPeerBuffer) -> bool:
	var byte: int = read_u8(spb)
	if has_error():
		return false
	if byte != 0 and byte != 1:
		_set_error("Invalid boolean value: %d (expected 0 or 1)" % byte, spb.get_position() - 1)
		return false
	return byte == 1


func read_bytes(spb: StreamPeerBuffer, num_bytes: int) -> PackedByteArray:
	if num_bytes < 0:
		_set_error("Attempted to read negative bytes: %d" % num_bytes, spb.get_position())
		return PackedByteArray()
	if num_bytes == 0 or not _check_read(spb, num_bytes):
		return PackedByteArray()
	var result: Array = spb.get_data(num_bytes)
	if result[0] != OK:
		_set_error("StreamPeerBuffer.get_data failed: %d" % result[0], spb.get_position() - num_bytes)
		return PackedByteArray()
	return result[1]


func read_string_with_u32_len(spb: StreamPeerBuffer) -> String:
	var start_pos: int = spb.get_position()
	var length: int = read_u32_le(spb)
	if has_error() or length == 0:
		return ""
	if length > MAX_STRING_LEN:
		_set_error("String length %d exceeds limit %d" % [length, MAX_STRING_LEN], start_pos)
		return ""
	var str_bytes: PackedByteArray = read_bytes(spb, length)
	if has_error():
		return ""
	var str_result: String = str_bytes.get_string_from_utf8()
	# More robust check for UTF-8 decoding errors
	if str_result == "" and length > 0 and (str_bytes.get_string_from_ascii() == "" or str_bytes.find(0) != -1):
		_set_error("Failed to decode UTF-8 string length %d" % length, start_pos)
		return ""
	return str_result


func read_identity(spb: StreamPeerBuffer) -> PackedByteArray:
	var identity: PackedByteArray = read_bytes(spb, IDENTITY_SIZE)
	identity.reverse() # We receive the identity bytes in reverse
	return identity


func read_connection_id(spb: StreamPeerBuffer) -> PackedByteArray:
	return read_bytes(spb, CONNECTION_ID_SIZE)


func read_timestamp(spb: StreamPeerBuffer) -> int:
	return read_i64_le(spb)


func read_scheduled_at(spb: StreamPeerBuffer) -> int:
	read_i8(spb) # skip enum tag
	return read_timestamp(spb)


func read_query_id_data(spb: StreamPeerBuffer) -> QueryIdData:
	var query_id_data: QueryIdData = QueryIdData.new()
	query_id_data.id = read_u32_le(spb)
	return query_id_data


func read_vec_u8(spb: StreamPeerBuffer) -> PackedByteArray:
	var start_pos: int = spb.get_position()
	var length: int = read_u32_le(spb)
	if has_error() or length == 0:
		return PackedByteArray()
	if length > MAX_BYTE_ARRAY_LEN:
		_set_error("Vec<u8> length %d exceeds limit %d" % [length, MAX_BYTE_ARRAY_LEN], start_pos)
		return PackedByteArray()
	return read_bytes(spb, length)


#--- BsatnRowList Reader ---
## Reads a v2 BsatnRowList into raw byte slices, one per row.
func read_bsatn_row_list(spb: StreamPeerBuffer) -> Array[PackedByteArray]:
	var start_pos: int = spb.get_position()
	var size_hint_type: int = read_u8(spb)
	if has_error():
		return []
	var rows: Array[PackedByteArray] = []

	match size_hint_type:
		ROW_LIST_FIXED_SIZE:
			var row_size: int = read_u16_le(spb)
			var data_len: int = read_u32_le(spb)
			if has_error():
				return []
			if row_size == 0:
				if data_len != 0:
					_set_error("FixedSize row_size is 0 but data_len is %d" % data_len, start_pos)
					read_bytes(spb, data_len)
				return []
			var data: PackedByteArray = read_bytes(spb, data_len)
			if has_error():
				return []
			if data_len % row_size != 0:
				_set_error("FixedSize data_len %d not divisible by row_size %d" % [data_len, row_size], start_pos)
				return []
			var num_rows: int = data_len / row_size
			rows.resize(num_rows)
			for i: int in range(num_rows):
				rows[i] = data.slice(i * row_size, (i + 1) * row_size)
		ROW_LIST_ROW_OFFSETS:
			var num_offsets: int = read_u32_le(spb)
			if has_error():
				return []
			var offsets: Array[int] = []
			offsets.resize(num_offsets)
			for i: int in range(num_offsets):
				offsets[i] = read_u64_le(spb)
				if has_error():
					return []
			var data_len: int = read_u32_le(spb)
			if has_error():
				return []
			var data: PackedByteArray = read_bytes(spb, data_len)
			if has_error():
				return []
			rows.resize(num_offsets)
			for i: int in range(num_offsets):
				var start_offset: int = offsets[i]
				var end_offset: int = data_len if (i + 1 == num_offsets) else offsets[i + 1]
				if start_offset < 0 or end_offset < start_offset or end_offset > data_len:
					_set_error(
						"Invalid row offsets: start=%d, end=%d, data_len=%d, row=%d" % [start_offset, end_offset, data_len, i],
						start_pos,
					)
					return []
				rows[i] = data.slice(start_offset, end_offset)
		_:
			_set_error("Unknown RowSizeHint type: %d" % size_hint_type, start_pos)
			return []

	return rows


## Appends [param new_data] to the internal buffer and extracts all complete
## [SpacetimeDBServerMessage] instances. Returns an array of parsed messages.
func process_bytes_and_extract_messages(new_data: PackedByteArray) -> Array[SpacetimeDBServerMessage]:
	if new_data.is_empty():
		return []
	_pending_data.append_array(new_data)
	var parsed_messages: Array[SpacetimeDBServerMessage] = []
	var spb: StreamPeerBuffer = StreamPeerBuffer.new()
	while not _pending_data.is_empty():
		clear_error()
		spb.data_array = _pending_data
		spb.seek(0)
		var message: SpacetimeDBServerMessage = _parse_message_from_stream(spb)

		if _has_error:
			if _last_error.contains("past end of buffer"):
				clear_error()
				break
			else:
				printerr("BSATNDeserializer: Unrecoverable parsing error: %s. Clearing buffer to prevent infinite loop." % get_last_error())
				_pending_data.clear()
				break

		if message:
			parsed_messages.append(message)
			var bytes_consumed: int = spb.get_position()

			if bytes_consumed == 0:
				printerr("BSATNDeserializer: Parser consumed 0 bytes. Clearing buffer to prevent infinite loop.")
				_pending_data.clear()
				break
			_pending_data = _pending_data.slice(bytes_consumed)
		else:
			break

	return parsed_messages


func _set_error(msg: String, position: int = -1) -> void:
	if _has_error:
		return
	var pos_str: String = " (at approx. position %d)" % position if position >= 0 else ""
	_last_error = "BSATNDeserializer Error: %s%s" % [msg, pos_str]
	_has_error = true
	printerr(_last_error)


func _check_read(spb: StreamPeerBuffer, bytes_needed: int) -> bool:
	if has_error():
		return false
	if spb.get_position() + bytes_needed > spb.get_size():
		_set_error(
			"Attempted to read %d bytes past end of buffer (size: %d)." % [bytes_needed, spb.get_size()],
			spb.get_position(),
		)
		return false
	return true


# --- Complex Property Readers ---
func _read_option(
		spb: StreamPeerBuffer,
		option_prop_dict: Dictionary,
		inner_type: StringName,
) -> Option:
	var option_instance := Option.new()
	var prop_name: StringName = option_prop_dict.name
	var tag_pos: int = spb.get_position()
	var tag: int = read_u8(spb)
	if has_error():
		return null

	if tag == 1: # None
		option_instance.set_none()
		return option_instance

	if tag != 0:
		_set_error("Invalid Option tag %d for property '%s' (expected 0=Some, 1=None)" % [tag, prop_name], tag_pos)
		return null

	if inner_type == &"":
		_set_error("Missing BSATN_TYPES entry for Option property '%s'" % prop_name, tag_pos)
		return null

	var inner_value: Variant = _read_value_from_bsatn_type(spb, inner_type, prop_name)

	if has_error():
		if not _last_error.contains(str(prop_name)):
			var cause := get_last_error()
			_set_error("Failed reading Some value for Option '%s' (inner type '%s'). Cause: %s" % [prop_name, inner_type, cause], tag_pos + 1)
		return null

	option_instance.set_some(inner_value)
	return option_instance


func _read_array(spb: StreamPeerBuffer, prop: Dictionary, bsatn_type_str: StringName) -> Array:
	var prop_name: StringName = prop.name
	var start_pos: int = spb.get_position()
	var length: int = read_u32_le(spb)
	if has_error() or length == 0:
		return []
	elif length > MAX_VEC_LEN:
		_set_error("Array length %d exceeds limit %d for property '%s'" % [length, MAX_VEC_LEN, prop_name], start_pos)
		return []

	# Determine element type from hint_string
	var hint: int = prop.hint
	var hint_string: String = prop.hint_string
	var element_type_code: Variant.Type = TYPE_MAX
	var element_class_name: StringName = &""

	if hint == PROPERTY_HINT_TYPE_STRING and ":" in hint_string:
		var parts: PackedStringArray = hint_string.split(":", true, 1)
		if parts.size() == 2:
			element_type_code = int(parts[0])
			element_class_name = parts[1]
		else:
			_set_error("Array '%s': bad hint_string format '%s'" % [prop_name, hint_string], start_pos)
			return []
	elif hint == PROPERTY_HINT_ARRAY_TYPE:
		var main_type_str: String = hint_string.split(":", true, 1)[0]
		if "/" in main_type_str:
			var parts: PackedStringArray = main_type_str.split("/", true, 1)
			element_type_code = int(parts[0])
			element_class_name = parts[1]
		else:
			element_type_code = int(main_type_str)
	else:
		_set_error("Array '%s' needs a typed hint (hint=%d, hint_string='%s')" % [prop_name, hint, hint_string], start_pos)
		return []

	if element_type_code == TYPE_MAX:
		_set_error("Could not determine element type for array '%s'" % prop_name, start_pos)
		return []

	var element_prop_sim: Dictionary = {
		"name": prop_name,
		"type": element_type_code,
		"class_name": element_class_name,
		"usage": PROPERTY_USAGE_STORAGE,
		"hint": 0,
		"hint_string": "",
	}

	# Resolve element reader from pre-bound bsatn_type_str
	var element_reader: Callable
	if bsatn_type_str.begins_with(&"opt_") or bsatn_type_str.begins_with(&"vec_"):
		# Prefixed type — use recursive type-driven deserialization for deep nesting
		element_reader = _read_value_from_bsatn_type.bind(bsatn_type_str, prop_name)
	elif element_class_name == &"Option":
		if bsatn_type_str == &"":
			_set_error("Array '%s' of Options is missing BSATN_TYPES entry for inner type T" % prop_name, start_pos)
			return []
		element_reader = _read_option.bind(element_prop_sim, bsatn_type_str)
	else:
		if bsatn_type_str != &"":
			element_reader = _get_primitive_reader_from_bsatn_type(bsatn_type_str)
			if not element_reader.is_valid() and _schema.types.has(bsatn_type_str):
				element_reader = _read_nested_resource.bind(element_prop_sim)
		if not element_reader.is_valid():
			element_reader = _get_reader_callable_for_property(element_prop_sim, &"")

	if not element_reader.is_valid():
		_set_error(
			"Cannot determine reader for elements of array '%s' (type code %d, class '%s')" % [prop_name, element_type_code, element_class_name],
			start_pos,
		)
		return []

	var result: Array[Variant] = []
	result.resize(length)
	for i: int in length:
		if has_error():
			return []
		var element_start_pos: int = spb.get_position()
		var element_value: Variant = element_reader.call(spb)
		if has_error():
			if not _last_error.contains("element %d" % i) and not _last_error.contains(str(prop_name)):
				var cause := get_last_error()
				_set_error("Failed reading element %d for array '%s'. Cause: %s" % [i, prop_name, cause], element_start_pos)
			return []
		result[i] = element_value
	return result


func _read_native_arraylike(spb: StreamPeerBuffer, prop: Dictionary, bsatn_type_str: StringName) -> Variant:
	var prop_name: StringName = prop.name
	var start_pos: int = spb.get_position()

	if bsatn_type_str == &"":
		_set_error("Missing BSATN_TYPES entry for '%s' (type %s)" % [prop_name, type_string(prop.type)], start_pos)
		return null

	var result: RegExMatch = _native_arraylike_regex.search(bsatn_type_str)
	var components_str: String = result.get_string("components") if result else ""
	if components_str.is_empty():
		_set_error("Missing component types in 'bsatn_type' for '%s'" % prop_name, start_pos)
		return null

	var components: Array[Variant] = []
	for component_type: StringName in components_str.split(","):
		components.append(_read_value_from_bsatn_type(spb, component_type, prop_name))

	match prop.type:
		TYPE_VECTOR2:
			return Vector2.ZERO if has_error() else Vector2(components[0], components[1])
		TYPE_VECTOR2I:
			return Vector2i.ZERO if has_error() else Vector2i(components[0], components[1])
		TYPE_VECTOR3:
			return Vector3.ZERO if has_error() else Vector3(components[0], components[1], components[2])
		TYPE_VECTOR3I:
			return Vector3i.ZERO if has_error() else Vector3i(components[0], components[1], components[2])
		TYPE_VECTOR4:
			return Vector4.ZERO if has_error() else Vector4(components[0], components[1], components[2], components[3])
		TYPE_VECTOR4I:
			return Vector4i.ZERO if has_error() else Vector4i(components[0], components[1], components[2], components[3])
		TYPE_QUATERNION:
			return Quaternion.IDENTITY if has_error() else Quaternion(components[0], components[1], components[2], components[3])
		TYPE_COLOR:
			return Color.BLACK if has_error() else Color(components[0], components[1], components[2], components[3])

	_set_error("Unsupported native arraylike type for property '%s'" % prop_name, start_pos)
	return null


func _read_nested_resource(spb: StreamPeerBuffer, prop: Dictionary) -> Object:
	var prop_name: StringName = prop.name
	var nested_class_name: StringName = prop.class_name

	if nested_class_name == &"":
		_set_error(
			"Property '%s' is TYPE_OBJECT but has no class_name hint" % prop_name,
			spb.get_position(),
		)
		return null

	var key: StringName = _normalize(nested_class_name)
	var script: GDScript = _schema.get_type(key)
	var nested_instance: Object

	if script:
		nested_instance = script.new()
	elif ClassDB.can_instantiate(nested_class_name):
		nested_instance = ClassDB.instantiate(nested_class_name)
		if not nested_instance is RefCounted: # Resource extends RefCounted
			_set_error("ClassDB instantiated '%s' for '%s' but it is not a RefCounted" % [nested_class_name, prop_name], spb.get_position())
			return null
	else:
		_set_error("Could not find or instantiate class '%s' for property '%s'" % [nested_class_name, prop_name], spb.get_position())
		return null

	if not _populate_resource_from_bytes(nested_instance, spb):
		if not has_error():
			_set_error("Failed to populate nested resource '%s' of type '%s'" % [prop_name, nested_class_name], spb.get_position())
		return null

	return nested_instance


# --- Generic Deserialization ---
func _get_primitive_reader_from_bsatn_type(bsatn_type_str: StringName) -> Callable:
	match bsatn_type_str:
		&"u8":
			return read_u8
		&"u16":
			return read_u16_le
		&"u32":
			return read_u32_le
		&"u64":
			return read_u64_le
		&"u128":
			return read_u128
		&"i8":
			return read_i8
		&"i16":
			return read_i16_le
		&"i32":
			return read_i32_le
		&"i64":
			return read_i64_le
		&"f32":
			return read_f32_le
		&"f64":
			return read_f64_le
		&"bool":
			return read_bool
		&"string":
			return read_string_with_u32_len
		&"vec_u8":
			return read_vec_u8
		&"identity":
			return read_identity
		&"connection_id":
			return read_connection_id
		&"timestamp":
			return read_timestamp
		&"scheduled_at":
			return read_scheduled_at
		&"transactionupdatemessage":
			return _read_transaction_update_message
		_:
			return Callable()


func _get_reader_callable_for_property(prop: Dictionary, bsatn_type_str: StringName) -> Callable:
	var prop_type: Variant.Type = prop.type

	if prop.class_name == &"Option":
		return _read_option.bind(prop, bsatn_type_str)
	elif prop_type == TYPE_ARRAY:
		return _read_array.bind(prop, bsatn_type_str)
	elif NATIVE_ARRAYLIKE.has(prop_type):
		return _read_native_arraylike.bind(prop, bsatn_type_str)
	else:
		var reader: Callable = Callable()
		if bsatn_type_str != &"":
			reader = _get_primitive_reader_from_bsatn_type(bsatn_type_str)
			if not reader.is_valid() and debug_mode:
				push_warning("Unknown BSATN_TYPES entry '%s' for property '%s'. Falling back to Variant.Type." % [bsatn_type_str, prop.name])
		if not reader.is_valid():
			match prop_type:
				TYPE_BOOL:
					reader = read_bool
				TYPE_INT:
					reader = read_i64_le
				TYPE_FLOAT:
					reader = read_f32_le
				TYPE_STRING:
					reader = read_string_with_u32_len
				TYPE_PACKED_BYTE_ARRAY:
					reader = read_vec_u8
				TYPE_OBJECT:
					reader = _read_nested_resource.bind(prop)
		return reader


func _read_value_from_bsatn_type(spb: StreamPeerBuffer, bsatn_type_str: StringName, context_prop_name: StringName) -> Variant:
	var start_pos: int = spb.get_position()

	# Primitive types
	var primitive_reader: Callable = _get_primitive_reader_from_bsatn_type(bsatn_type_str)
	if primitive_reader.is_valid():
		var value: Variant = primitive_reader.call(spb)
		return null if has_error() else value

	# Vec<T>
	if bsatn_type_str.begins_with("vec_"):
		var element_type: StringName = bsatn_type_str.right(-4)
		var array_length: int = read_u32_le(spb)
		if has_error():
			return null
		if array_length == 0:
			return []
		if array_length > MAX_VEC_LEN:
			_set_error(
				"Array length %d for '%s' exceeds limit %d (context: '%s')" % [array_length, bsatn_type_str, MAX_VEC_LEN, context_prop_name],
				spb.get_position() - 4,
			)
			return null
		var temp_array: Array[Variant] = []
		for i: int in range(array_length):
			if has_error():
				return null
			var element: Variant = _read_value_from_bsatn_type(spb, element_type, "%s[%d]" % [context_prop_name, i])
			if has_error():
				return null
			temp_array.append(element)
		return temp_array

	# Option<T>
	if bsatn_type_str.begins_with("opt_"):
		return _read_option(spb, { "name": context_prop_name }, bsatn_type_str.right(-4))

	# Custom Resource (schema type)
	var schema_key: StringName = bsatn_type_str.replace("_", "")
	if _schema.types.has(schema_key):
		var script: GDScript = _schema.get_type(schema_key)
		if script and script.can_instantiate():
			var nested_instance = script.new()
			if not _populate_resource_from_bytes(nested_instance, spb):
				if not has_error():
					_set_error("Failed to populate nested resource of type '%s' (schema key '%s') for context '%s'" % [bsatn_type_str, schema_key, context_prop_name], start_pos)
				return null
			return nested_instance
		else:
			_set_error("Cannot instantiate schema for BSATN type '%s' (schema key '%s', context: '%s'). Script valid: %s, Can instantiate: %s" % [bsatn_type_str, schema_key, context_prop_name, script != null, script.can_instantiate() if script else "N/A"], start_pos)
			return null

	_set_error("Unsupported BSATN type '%s' for deserialization (context: '%s'). No primitive, vec, or custom schema found." % [bsatn_type_str, context_prop_name], start_pos)
	return null


func _create_deserialization_plan(script: Script) -> Array:
	var bsatn_types: Dictionary = script.get_script_constant_map().get("BSATN_TYPES", { })
	var plan: Array[Dictionary] = []
	var properties: Array[Dictionary] = script.get_script_property_list()
	for prop: Dictionary in properties:
		if not (prop.usage & PROPERTY_USAGE_STORAGE):
			continue

		var prop_name: StringName = prop.name
		var bsatn_type_str: StringName = bsatn_types.get(prop_name, &"")
		var reader_callable: Callable = _get_reader_callable_for_property(prop, bsatn_type_str)

		if not reader_callable.is_valid():
			_set_error("Unsupported property or missing reader for '%s' in script '%s'" % [prop_name, script.resource_path], -1)
			_deserialization_plan_cache[script] = []
			return []

		plan.append(
			{
				"name": prop_name,
				"type": prop.type,
				"reader": reader_callable,
				"prop_dict": prop,
			},
		)

	_deserialization_plan_cache[script] = plan
	return plan


## Populates an existing Resource instance from the buffer based on its exported properties.
func _populate_resource_from_bytes(resource: Object, spb: StreamPeerBuffer) -> bool:
	if not resource:
		_set_error("Cannot populate null or scriptless resource", -1 if not spb else spb.get_position())
		return false

	var script: Variant = resource.get_script()
	if not script:
		_set_error("Cannot populate null or scriptless resource", -1 if not spb else spb.get_position())
		return false

	if resource is RustEnum:
		return _populate_enum_from_bytes(spb, resource, script)

	var plan: Array = _deserialization_plan_cache.get(script, [])
	if plan.is_empty() and not _deserialization_plan_cache.has(script):
		plan = _create_deserialization_plan(script)
		if has_error():
			return false

	for instruction: Dictionary in plan:
		var value_start_pos: int = spb.get_position()
		var value: Variant = instruction.reader.call(spb)

		if _has_error:
			if not _last_error.contains(str(instruction.name)):
				var existing_error := get_last_error()
				_set_error("Failed reading property '%s'. Cause: %s" % [instruction.name, existing_error], value_start_pos)
			return false

		if value != null:
			if instruction.type == TYPE_ARRAY and value is Array:
				var target_array: Variant = resource.get(instruction.name)
				if target_array is Array:
					target_array.assign(value)
				else:
					resource[instruction.name] = value
			else:
				resource[instruction.name] = value
	return true


# #12: ENUM_OPTIONS cached in _deserialization_plan_cache as a single-element Array wrapper
# so get_script_constant_map() is called once per script, not once per enum deserialization
func _populate_enum_from_bytes(spb: StreamPeerBuffer, resource: Object, script: Script) -> bool:
	var cached: Array = _deserialization_plan_cache.get(script, [])
	var enum_options: Array
	if cached.is_empty():
		enum_options = script.get_script_constant_map().get(&"ENUM_OPTIONS", [])
		_deserialization_plan_cache[script] = [enum_options] # wrap so null sentinel still works
	else:
		enum_options = cached[0]
	var enum_variant: int = spb.get_u8()
	resource.value = enum_variant
	var enum_type: StringName = enum_options[enum_variant] if enum_variant < enum_options.size() else &""
	if enum_type != &"":
		var data: Variant = _read_value_from_bsatn_type(spb, enum_type, &"")
		if data != null:
			resource.data = data
	return true


#--- Specific Message/Structure Readers ---
## v2: Reads a single row's BSATN bytes into a Resource of the given schema script.
func _parse_row_bytes(
		row_bytes: PackedByteArray,
		row_schema_script: GDScript,
		table_name: String,
		row_spb: StreamPeerBuffer,
) -> Resource:
	var row_resource: Variant = row_schema_script.new()
	row_spb.data_array = row_bytes
	row_spb.seek(0)
	if not _populate_resource_from_bytes(row_resource, row_spb):
		push_error("Failed to parse row for table '%s'" % table_name)
		return null
	if row_spb.get_position() < row_spb.get_size():
		push_warning(
			"Extra %d bytes after parsing row for table '%s'" % [
				row_spb.get_size() - row_spb.get_position(),
				table_name,
			],
		)
	return row_resource


## v2: Reads a BsatnRowList and deserializes each row into a Resource array.
func _read_bsatn_row_list_as_resources(
		spb: StreamPeerBuffer,
		row_schema_script: GDScript,
		table_name: String,
		row_spb: StreamPeerBuffer,
) -> Array[Resource]:
	var result: Array[Resource] = []
	var raw_rows: Array[PackedByteArray] = read_bsatn_row_list(spb)
	if has_error():
		return result
	for raw_row_bytes: PackedByteArray in raw_rows:
		var row: Resource = _parse_row_bytes(raw_row_bytes, row_schema_script, table_name, row_spb)
		if row == null:
			return []
		result.append(row)
	return result


## v2: TableUpdate { table_name: RawIdentifier (string), rows: Array[TableUpdateRows] }
## TableUpdateRows tag: 0=PersistentTable{inserts,deletes}, 1=EventTable{events}
func _read_table_update_instance(spb: StreamPeerBuffer, resource: TableUpdateData) -> bool:
	resource.table_name = read_string_with_u32_len(spb)
	if has_error():
		return false

	var table_name_lower: StringName = _normalize(resource.table_name)
	var row_schema_script: GDScript = _schema.get_type(table_name_lower)

	var rows_count: int = read_u32_le(spb)
	if has_error():
		return false

	var all_inserts: Array[Resource] = []
	var all_deletes: Array[Resource] = []
	var row_spb: StreamPeerBuffer = StreamPeerBuffer.new()

	for _i: int in range(rows_count):
		if has_error():
			return false
		var tag: int = read_u8(spb)
		if has_error():
			return false

		match tag:
			0: # PersistentTable { inserts: BsatnRowList, deletes: BsatnRowList }
				if row_schema_script:
					var inserts: Array[Resource] = _read_bsatn_row_list_as_resources(spb, row_schema_script, resource.table_name, row_spb)
					if has_error():
						return false
					all_inserts.append_array(inserts)
					var deletes: Array[Resource] = _read_bsatn_row_list_as_resources(spb, row_schema_script, resource.table_name, row_spb)
					if has_error():
						return false
					all_deletes.append_array(deletes)
				else:
					if debug_mode:
						push_warning("No schema for '%s', skipping PersistentTable rows." % resource.table_name)
					read_bsatn_row_list(spb)
					if has_error():
						return false # inserts
					read_bsatn_row_list(spb)
					if has_error():
						return false # deletes
			1: # EventTable { events: BsatnRowList } — treated as inserts
				if row_schema_script:
					var events: Array[Resource] = _read_bsatn_row_list_as_resources(spb, row_schema_script, resource.table_name, row_spb)
					if has_error():
						return false
					all_inserts.append_array(events)
				else:
					if debug_mode:
						push_warning("No schema for '%s', skipping EventTable rows." % resource.table_name)
					read_bsatn_row_list(spb)
					if has_error():
						return false
			_:
				_set_error("Unknown TableUpdateRows tag %d for table '%s'" % [tag, resource.table_name], spb.get_position() - 1)
				return false

	resource.inserts.assign(all_inserts)
	resource.deletes.assign(all_deletes)
	return true


## v2: SubscribeApplied { request_id: u32, query_set_id: QuerySetId{id:u32}, rows: QueryRows }
## QueryRows { tables: Array[SingleTableRows{table:string, rows:BsatnRowList}] }
func _read_subscripton_applied_message(spb: StreamPeerBuffer) -> SubscribeAppliedMessage:
	var resource: SubscribeAppliedMessage = SubscribeAppliedMessage.new()
	resource.request_id = read_u32_le(spb)
	if has_error():
		return null

	resource.query_set_id.id = read_u32_le(spb)
	if has_error():
		return null

	var table_count: int = read_u32_le(spb)
	if has_error():
		return null

	var row_spb: StreamPeerBuffer = StreamPeerBuffer.new()

	for _i: int in range(table_count):
		if has_error():
			return null
		var table_name: String = read_string_with_u32_len(spb)
		if has_error():
			return null

		var table_update: TableUpdateData = TableUpdateData.new()
		table_update.table_name = table_name

		var table_name_lower: StringName = _normalize(table_name)
		var row_schema_script: GDScript = _schema.get_type(table_name_lower)

		if row_schema_script:
			var inserts = _read_bsatn_row_list_as_resources(spb, row_schema_script, table_name, row_spb)
			if has_error():
				return null
			table_update.inserts.assign(inserts)
		else:
			if debug_mode:
				push_warning("No schema for '%s' in SubscribeApplied, skipping rows." % table_name)
			read_bsatn_row_list(spb)
			if has_error():
				return null

		resource.tables.append(table_update)

	return resource


## v2: TransactionUpdate { query_sets: Array[QuerySetUpdate{query_set_id, tables}] }
func _read_transaction_update_message(spb: StreamPeerBuffer) -> TransactionUpdateMessage:
	var tx_update: TransactionUpdateMessage = TransactionUpdateMessage.new()

	var query_set_count: int = read_u32_le(spb)
	if has_error():
		return null

	for _i: int in range(query_set_count):
		if has_error():
			return null
		var dataset: DatabaseUpdateData = DatabaseUpdateData.new()
		tx_update.query_sets.append(dataset)

		dataset.query_id.id = read_u32_le(spb)
		if has_error():
			return null

		var table_count: int = read_u32_le(spb)
		if has_error():
			return null

		for i2: int in range(table_count):
			if has_error():
				return null
			var table: TableUpdateData = TableUpdateData.new()
			dataset.tables.append(table)
			if not _read_table_update_instance(spb, table):
				if not has_error():
					_set_error("Failed reading TableUpdate element %d" % i2)
				return null

	return tx_update


## v2: UnsubscribeApplied { request_id: u32, query_set_id: QuerySetId, rows: Option<QueryRows> }
## Option<QueryRows>: tag 0 = Some(QueryRows), 1 = None
## We parse the rows into TableUpdateData for LocalDatabase compat (same as SubscribeApplied).
func _read_unsubscribe_applied_message(spb: StreamPeerBuffer) -> UnsubscribeAppliedMessage:
	var resource: UnsubscribeAppliedMessage = UnsubscribeAppliedMessage.new()
	resource.request_id = read_u32_le(spb)
	if has_error():
		return null

	resource.query_id.id = read_u32_le(spb)
	if has_error():
		return null

	# Option<QueryRows>: tag 0 = Some, 1 = None
	var option_tag: int = read_u8(spb)
	if has_error():
		return null

	if option_tag == 0: # Some(QueryRows)
		var table_count: int = read_u32_le(spb)
		if has_error():
			return null
		var row_spb: StreamPeerBuffer = StreamPeerBuffer.new()
		for _i: int in range(table_count):
			if has_error():
				return null
			var table_name: String = read_string_with_u32_len(spb)
			if has_error():
				return null
			var table_update: TableUpdateData = TableUpdateData.new()
			table_update.table_name = table_name
			var table_name_lower: StringName = _normalize(table_name)
			var row_schema_script: GDScript = _schema.get_type(table_name_lower)
			if row_schema_script:
				var rows: Array[Resource] = _read_bsatn_row_list_as_resources(spb, row_schema_script, table_name, row_spb)
				if has_error():
					return null
				table_update.inserts.assign(rows)
			else:
				read_bsatn_row_list(spb)
				if has_error():
					return null
			resource.tables.append(table_update)
	elif option_tag != 1:
		_set_error("Invalid Option tag %d in UnsubscribeApplied" % option_tag, spb.get_position() - 1)
		return null

	return resource


## v2: SubscriptionError { request_id: Option<u32>, query_set_id: QuerySetId, error: string }
func _read_subscription_error_message(spb: StreamPeerBuffer) -> SubscriptionErrorMessage:
	var resource: SubscriptionErrorMessage = SubscriptionErrorMessage.new()

	var req_id_tag: int = read_u8(spb)
	if has_error():
		return null
	if req_id_tag == 0:
		resource.request_id = read_u32_le(spb)
	elif req_id_tag == 1:
		resource.request_id = -1
	else:
		_set_error("Invalid Option<u32> tag %d for request_id in SubscriptionError" % req_id_tag, spb.get_position() - 1)
		return null
	if has_error():
		return null

	resource.query_id = read_query_id_data(spb)
	if has_error():
		return null

	resource.error_message = read_string_with_u32_len(spb)
	if has_error():
		return null

	printerr("SubscriptionError received: ", resource.error_message)
	return resource


## v2: ReducerResult { request_id: u32, timestamp: Timestamp, result: ReducerOutcome }
## ReducerOutcome: 0=Ok(ReducerOk{ret_value,transaction_update}), 1=OkEmpty, 2=Err(bytes), 3=InternalError(string)
func _read_reducer_result_message(spb: StreamPeerBuffer) -> ReducerResultMessage:
	var resource: ReducerResultMessage = ReducerResultMessage.new()

	resource.request_id = read_u32_le(spb)
	if has_error():
		return null
	resource.timestamp = read_timestamp(spb)
	if has_error():
		return null

	var outcome_tag: int = read_u8(spb)
	if has_error():
		return null

	var outcome: ReducerOutcomeEnum = ReducerOutcomeEnum.new()
	outcome.value = outcome_tag
	resource.reducer_result = outcome

	match outcome_tag:
		ReducerOutcomeEnum.Options.ok:
			var _ret_value := read_vec_u8(spb) # consume return value bytes
			if has_error():
				return null
			var tx_update := _read_transaction_update_message(spb)
			if has_error():
				return null
			outcome.data = tx_update
		ReducerOutcomeEnum.Options.okEmpty:
			outcome.data = null
		ReducerOutcomeEnum.Options.err:
			outcome.data = read_vec_u8(spb)
			if has_error():
				return null
		ReducerOutcomeEnum.Options.internalError:
			outcome.data = read_string_with_u32_len(spb)
			if has_error():
				return null
		_:
			_set_error("Unknown ReducerOutcome tag: %d" % outcome_tag, spb.get_position() - 1)
			return null

	return resource


## v2: ProcedureResult { status: ProcedureStatus, timestamp: Timestamp, total_host_execution_duration: TimeDuration, request_id: u32 }
## ProcedureStatus: 0=Returned(bytes), 1=InternalError(string)
func _read_procedure_result_message(spb: StreamPeerBuffer) -> ProcedureResultData:
	var resource := ProcedureResultData.new()

	var status_tag: int = read_u8(spb)
	if has_error():
		return null
	resource.status_tag = status_tag

	match status_tag:
		0: # Returned(bytes)
			resource.return_bytes = read_vec_u8(spb)
			if has_error():
				return null
		1: # InternalError(string)
			resource.error_message = read_string_with_u32_len(spb)
			if has_error():
				return null
		_:
			_set_error("Unknown ProcedureStatus tag: %d" % status_tag, spb.get_position() - 1)
			return null

	resource.timestamp = read_timestamp(spb)
	if has_error():
		return null

	resource.duration = read_timestamp(spb) # TimeDuration is also i64 micros
	if has_error():
		return null

	resource.request_id = read_u32_le(spb)
	if has_error():
		return null

	return resource


func _read_generic_server_message(msg_type: int, script_path: String, spb: StreamPeerBuffer) -> SpacetimeDBServerMessage:
	if not ResourceLoader.exists(script_path):
		_set_error("Script not found for message type 0x%02X: %s" % [msg_type, script_path], 1)
		return null
	var script: GDScript = ResourceLoader.load(script_path, "GDScript")
	if not script or not script.can_instantiate():
		_set_error("Failed to load or instantiate script for message type 0x%02X: %s" % [msg_type, script_path], 1)
		return null

	var message: SpacetimeDBServerMessage = script.new()
	if not _populate_resource_from_bytes(message, spb):
		return null
	return message


# --- Top-Level Message Parsing ---
func _parse_message_from_stream(spb: StreamPeerBuffer) -> SpacetimeDBServerMessage:
	clear_error()

	var start_pos: int = spb.get_position()
	if not _check_read(spb, 1):
		return null

	var msg_type: SpacetimeDBServerMessage.Type = read_u8(spb) as SpacetimeDBServerMessage.Type
	if has_error():
		return null

	var result: SpacetimeDBServerMessage = null
	var script_path: String = SpacetimeDBServerMessage.get_script_path(msg_type)

	if script_path == "":
		_set_error("Unknown server message type: 0x%02X" % msg_type, 1)
		return null

	match msg_type:
		SpacetimeDBServerMessage.INITIAL_CONNECTION:
			result = _read_generic_server_message(msg_type, script_path, spb)
		SpacetimeDBServerMessage.SUBSCRIBE_APPLIED:
			result = _read_subscripton_applied_message(spb)
		SpacetimeDBServerMessage.UNSUBSCRIBE_APPLIED:
			result = _read_unsubscribe_applied_message(spb)
		SpacetimeDBServerMessage.SUBSCRIPTION_ERROR:
			result = _read_subscription_error_message(spb)
		SpacetimeDBServerMessage.TRANSACTION_UPDATE:
			result = _read_transaction_update_message(spb)
		SpacetimeDBServerMessage.ONE_OFF_QUERY_RESPONSE:
			_set_error("Reader for OneOffQueryResponse not implemented.", spb.get_position() - 1)
			return null
		SpacetimeDBServerMessage.REDUCER_RESULT:
			result = _read_reducer_result_message(spb)
		SpacetimeDBServerMessage.PROCEDURE_RESULT:
			result = _read_procedure_result_message(spb)
		_:
			_set_error("Unknown server message type: 0x%02X" % msg_type, start_pos)
			return null
	if has_error():
		return null
	var remaining_bytes: int = spb.get_size() - spb.get_position()
	if remaining_bytes > 0:
		push_warning("Bytes remaining after parsing message type 0x%02X: %d" % [msg_type, remaining_bytes])

	return result

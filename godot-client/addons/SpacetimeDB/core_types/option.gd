@tool
class_name Option extends Resource

@export var data: Array = [] :
	set(value):
		if value is Array:
			if value.size() > 0:
				_internal_data = value.slice(0, 1)
			else:
				_internal_data = []
		else:
			push_error("Optional data must be an Array.")
			_internal_data = []
	get():
		return _internal_data

var _internal_data: Array = []

static func some(value: Variant) -> Option:
	var result = Option.new()
	result.set_some(value)
	return result

static func none() -> Option:
	var result = Option.new()
	result.set_none()
	return result

func is_some() -> bool:
	return _internal_data.size() > 0

func is_none() -> bool:
	return _internal_data.is_empty()

func unwrap() -> Variant:
	if is_some():
		return _internal_data[0]
	push_error("Attempted to unwrap a None Optional value!")
	return null

func unwrap_or(default_value: Variant) -> Variant:
	if is_some():
		return _internal_data[0]
	return default_value

func unwrap_or_else(fn: Callable) -> Variant:
	if is_some():
		return _internal_data[0]
	if fn.is_valid():
		return fn.call()
	return null

func expect(type: Variant.Type, err_msg: String = "") -> Variant:
	if is_some():
		if typeof(_internal_data[0]) != type:
			err_msg = "Expected type %s, got %s" % [type, typeof(_internal_data[0])] if err_msg.is_empty() else err_msg
			push_error(err_msg)
			return null
		return _internal_data[0]
	err_msg = "Expected type %s, got None" % type if err_msg.is_empty() else err_msg
	push_error(err_msg)
	return null

func set_some(value: Variant) -> void:
	self.data = [value]

func set_none() -> void:
	self.data = []

func to_string() -> String:
	if is_some():
		return "Some(%s [type: %s])" % [_internal_data[0], typeof(_internal_data[0])]
	else:
		return "None"

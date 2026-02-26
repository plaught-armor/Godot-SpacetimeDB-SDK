@tool
class_name ReducerOutcomeEnum extends RustEnum

## v2 ReducerOutcome enum:
##   Ok(ReducerOk { ret_value: bytes, transaction_update: TransactionUpdate })
##   OkEmpty
##   Err(bytes)
##   InternalError(string)

enum Options {
	ok,
	okEmpty,
	err,
	internalError,
}

## 'ok' data is parsed manually and stored as TransactionUpdateMessage.
## '' means no data for okEmpty. vec_u8 for err bytes. string for internalError.
const ENUM_OPTIONS: Array[StringName] = [&'ReducerOk', &'', &'vec_u8', &'string']

static func parse_enum_name(i: int) -> String:
	match i:
		0: return &'ok'
		1: return &'okEmpty'
		2: return &'err'
		3: return &'internalError'
		_:
			printerr("Enum does not have value for %d. This is out of bounds." % i)
			return &'Unknown'

## Returns the TransactionUpdateMessage from the Ok variant.
func get_ok() -> TransactionUpdateMessage:
	return data

func get_err() -> PackedByteArray:
	return data

func get_internal_error() -> String:
	return data

static func create(p_type: int, p_data: Variant = null) -> ReducerOutcomeEnum:
	var result : ReducerOutcomeEnum = ReducerOutcomeEnum.new()
	result.value = p_type
	result.data = p_data
	return result

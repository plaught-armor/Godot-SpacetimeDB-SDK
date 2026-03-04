class_name SpacetimeDBServerMessage extends SpacetimeDBMessage

## v2 server message type tags (wire values must match protocol exactly)
enum Type {
	INITIAL_CONNECTION = 0x00,
	SUBSCRIBE_APPLIED = 0x01,
	UNSUBSCRIBE_APPLIED = 0x02,
	SUBSCRIPTION_ERROR = 0x03,
	TRANSACTION_UPDATE = 0x04,
	ONE_OFF_QUERY_RESPONSE = 0x05,
	REDUCER_RESULT = 0x06,
	PROCEDURE_RESULT = 0x07,
}

## Back-compat consts so existing code referencing SpacetimeDBServerMessage.SUBSCRIBE_APPLIED etc. still works.
const INITIAL_CONNECTION: int = Type.INITIAL_CONNECTION
const SUBSCRIBE_APPLIED: int = Type.SUBSCRIBE_APPLIED
const UNSUBSCRIBE_APPLIED: int = Type.UNSUBSCRIBE_APPLIED
const SUBSCRIPTION_ERROR: int = Type.SUBSCRIPTION_ERROR
const TRANSACTION_UPDATE: int = Type.TRANSACTION_UPDATE
const ONE_OFF_QUERY_RESPONSE: int = Type.ONE_OFF_QUERY_RESPONSE
const REDUCER_RESULT: int = Type.REDUCER_RESULT
const PROCEDURE_RESULT: int = Type.PROCEDURE_RESULT


const _MSG_PATH := SpacetimePlugin.ADDON_PATH + "/core_types/server_message/"

static func get_script_path(msg_type: int) -> String:
	match msg_type:
		Type.INITIAL_CONNECTION:
			return _MSG_PATH + "initial_connection.gd"
		Type.SUBSCRIBE_APPLIED:
			return _MSG_PATH + "subscribe_applied.gd"
		Type.UNSUBSCRIBE_APPLIED:
			return _MSG_PATH + "unsubscribe_applied.gd"
		Type.SUBSCRIPTION_ERROR:
			return _MSG_PATH + "subscription_error.gd"
		Type.TRANSACTION_UPDATE:
			return _MSG_PATH + "transaction_update.gd"
		Type.ONE_OFF_QUERY_RESPONSE:
			return _MSG_PATH + "one_off_query_response.gd"
		Type.REDUCER_RESULT:
			return _MSG_PATH + "reducer_result.gd"
		Type.PROCEDURE_RESULT:
			return _MSG_PATH + "procedure_result.gd"
		_:
			return ""

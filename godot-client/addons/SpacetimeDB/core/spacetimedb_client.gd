#@tool
class_name SpacetimeDBClient
extends Node

# --- Signals ---
signal connected(identity: PackedByteArray, token: String)
signal disconnected
signal connection_error(code: int, reason: String)
signal database_initialized # Emitted after InitialSubscription is processed
signal database_update(table_update: TableUpdateData) # Emitted for each table update
# From LocalDatabase
signal row_inserted(table_name: StringName, row: Resource)
signal row_updated(table_name: StringName, old_row: Resource, new_row: Resource)
signal row_deleted(table_name: StringName, row: Resource)
signal row_transactions_completed(table_name: StringName)
signal transaction_update_received(update: TransactionUpdateMessage)
# Fired when a ReducerResultMessage arrives — carries request_id + optional tx_update (null if okEmpty/err)
signal reducer_result_received(request_id: int, tx_update: TransactionUpdateMessage)
# Fired when a ProcedureResultData arrives — carries request_id + return bytes (empty if error)
signal procedure_result_received(request_id: int, return_bytes: PackedByteArray)
# --- Reconnection Signals ---
signal reconnecting(attempt: int, max_attempts: int)
signal reconnected
signal reconnect_failed

# --- Configuration ---
@export var base_url: String = "http://127.0.0.1:3000"
@export var database_name: String = "quickstart-chat" # Example
@export var schema_path: String = "res://spacetime_bindings/schema"
@export var auto_connect: bool = false
@export var auto_request_token: bool = true
@export var token_save_path: String = "user://spacetimedb_token.dat" # Use a more specific name
@export var one_time_token: bool = false
@export var compression: SpacetimeDBConnection.CompressionPreference
@export var debug_mode: bool = true
var current_subscriptions: Dictionary[int, SpacetimeDBSubscription]
@export var use_threading: bool = true

var module_name: String = ""
var deserializer_worker: Thread
var connection_options: SpacetimeDBConnectionOptions
var pending_subscriptions: Dictionary[int, SpacetimeDBSubscription]
var _packet_queue: Array[PackedByteArray] = []
var _packet_semaphore: Semaphore
var _result_queue: Array[SpacetimeDBServerMessage] = []
var _result_mutex: Mutex
var _packet_mutex: Mutex
var _thread_should_exit: bool = false
var _message_limit_in_frame: int = 5
# Cache of reducer results that arrived before anyone called wait_for_reducer_response
var _reducer_result_cache: Dictionary[int, TransactionUpdateMessage] = { } # request_id -> TransactionUpdateMessage (or null)
var _pending_reducer_calls: Dictionary[int, SpacetimeDBReducerCall] = {}
var _pending_procedure_calls: Dictionary[int, SpacetimeDBProcedureCall] = {}
var _procedure_result_cache: Dictionary[int, PackedByteArray] = {}
# --- Components ---
var _connection: SpacetimeDBConnection
var _deserializer: BSATNDeserializer
var _serializer: BSATNSerializer
var _local_db: LocalDatabase
var _rest_api: SpacetimeDBRestAPI # Optional, for token/REST calls
# --- State ---
var _connection_id: PackedByteArray
var _identity: PackedByteArray
var _token: String
var _is_initialized: bool = false
var _received_initial_subscription: bool = false
var _next_query_id: int = 0
var _next_request_id: int = 0
# --- Reconnection State ---
enum _ReconnectState { IDLE, RECONNECTING }
var _reconnect_state: _ReconnectState = _ReconnectState.IDLE
var _reconnect_attempt: int = 0
var _intentional_disconnect: bool = false
var _saved_subscription_queries: Array[PackedStringArray] = []
var _reconnect_timer: SceneTreeTimer = null


func _ready() -> void:
	if auto_connect:
		initialize_and_connect()


# --- WebSocket Message Handling ---
func _physics_process(_delta: float) -> void:
	_process_results_asynchronously()


func _exit_tree() -> void:
	_cancel_reconnection()
	if deserializer_worker:
		_thread_should_exit = true
		_packet_semaphore.post()
		deserializer_worker.wait_to_finish()
		deserializer_worker = null


func print_log(log_message: String) -> void:
	if debug_mode:
		print(log_message)


func initialize_and_connect() -> void:
	if _is_initialized:
		return

	print_log("SpacetimeDBClient: Initializing...")

	# 1. Load Schema
	var schema := SpacetimeDBSchema.new(module_name, schema_path, debug_mode)

	# 2. Initialize Parser
	_deserializer = BSATNDeserializer.new(schema, debug_mode)
	_serializer = BSATNSerializer.new(debug_mode)

	# 3. Initialize Local Database
	_local_db = LocalDatabase.new(schema)
	_init_db(_local_db)

	# Connect to LocalDatabase signals to re-emit them
	_local_db.row_inserted.connect(func(tn, r) -> void: row_inserted.emit(tn, r))
	_local_db.row_updated.connect(func(tn, p, r) -> void: row_updated.emit(tn, p, r))
	_local_db.row_deleted.connect(func(tn, r) -> void: row_deleted.emit(tn, r))
	_local_db.row_transactions_completed.connect(func(tn) -> void: row_transactions_completed.emit(tn))
	_local_db.name = "LocalDatabase"
	add_child(_local_db) # Add as child if it needs signals

	# 4. Initialize REST API Handler (optional, mainly for token)
	_rest_api = SpacetimeDBRestAPI.new(base_url, debug_mode)
	_rest_api.token_received.connect(_on_token_received)
	_rest_api.token_request_failed.connect(_on_token_request_failed)
	_rest_api.name = "RestAPI"
	add_child(_rest_api)

	# 5. Initialize Connection Handler
	_connection = SpacetimeDBConnection.new(connection_options, database_name)
	_connection.disconnected.connect(_on_connection_disconnected)
	_connection.connection_error.connect(_on_connection_error)
	_connection.message_received.connect(_on_websocket_message_received)
	_connection.name = "Connection"
	add_child(_connection)

	_is_initialized = true
	print_log("SpacetimeDBClient: Initialization complete.")

	# 6. Get Token and Connect
	_load_token_or_request()


# --- Public API ---
func connect_db(host_url: String, database_name: String, options: SpacetimeDBConnectionOptions = null) -> void:
	_cancel_reconnection()
	if not options:
		options = SpacetimeDBConnectionOptions.new()
	connection_options = options
	self.base_url = host_url
	self.database_name = database_name.to_lower()
	self.compression = options.compression
	self.one_time_token = options.one_time_token
	if not options.token.is_empty():
		self._token = options.token
	self.debug_mode = options.debug_mode
	self.use_threading = options.threading

	if OS.has_feature("web") and use_threading == true:
		push_error("Threads are not supported on Web. Threading has been disabled.")
		use_threading = false

	if use_threading:
		_packet_mutex = Mutex.new()
		_packet_semaphore = Semaphore.new()
		_result_mutex = Mutex.new()
		deserializer_worker = Thread.new()
		deserializer_worker.start(_thread_loop)

	if not _is_initialized:
		initialize_and_connect()
	elif not _connection.is_connected_db():
		# Already initialized, just need token and connect
		_load_token_or_request()


func disconnect_db() -> void:
	_intentional_disconnect = true
	_cancel_reconnection()
	_token = ""
	if _connection:
		_connection.disconnect_from_server()


func is_connected_db() -> bool:
	return _connection and _connection.is_connected_db()


# The untyped local database instance, use the generated .Db property for querying
func get_local_database() -> LocalDatabase:
	return _local_db


func get_local_identity() -> PackedByteArray:
	return _identity


func subscribe(queries: PackedStringArray) -> SpacetimeDBSubscription:
	if not is_connected_db():
		printerr("SpacetimeDBClient: Cannot subscribe, not connected.")
		return SpacetimeDBSubscription.fail(ERR_CONNECTION_ERROR)

	# 1. Generate a request ID
	var request_id: int = _next_request_id
	_next_request_id += 1
	var query_id: int = _next_query_id
	_next_query_id += 1
	# 2. Create the correct payload Resource
	var payload_data: SubscribeMessage = SubscribeMessage.new(request_id, query_id, queries)

	# 3. Serialize the complete ClientMessage using the universal function
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.SUBSCRIBE,
		payload_data,
	)

	if _serializer.has_error():
		printerr("SpacetimeDBClient: Failed to serialize Subscribe message: %s" % _serializer.get_last_error())
		return SpacetimeDBSubscription.fail(ERR_PARSE_ERROR)

	# 4. Create subscription handle
	var subscription: SpacetimeDBSubscription = SpacetimeDBSubscription.create(self, query_id, queries)

	# 5. Send the binary message via WebSocket
	if _connection and _connection._websocket:
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			printerr("SpacetimeDBClient: Error sending Subscribe BSATN message: %s" % error_string(err))
			subscription.error = err
			subscription._ended = true
		else:
			print_log("SpacetimeDBClient: Subscribe request sent successfully (BSATN), Query ID: %d" % query_id)
			pending_subscriptions.set(query_id, subscription)

		return subscription

	printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	subscription.error = ERR_CONNECTION_ERROR
	subscription._ended = true
	return subscription


func unsubscribe(query_id: int) -> Error:
	if not is_connected_db():
		printerr("SpacetimeDBClient: Cannot unsubscribe, not connected.")
		return ERR_CONNECTION_ERROR

	var request_id: int = _next_request_id
	_next_request_id += 1
	# 1. Create the correct payload Resource
	var payload_data: UnsubscribeMessage = UnsubscribeMessage.new(request_id, query_id)

	# 2. Serialize the complete ClientMessage using the universal function
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.UNSUBSCRIBE,
		payload_data,
	)

	if _serializer.has_error():
		printerr("SpacetimeDBClient: Failed to serialize Unsubscribe message: %s" % _serializer.get_last_error())
		return ERR_PARSE_ERROR

	# 3. Send the binary message via WebSocket
	if _connection and _connection._websocket:
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			printerr("SpacetimeDBClient: Error sending Unsubscribe BSATN message: %s" % error_string(err))
			return err

		print_log("SpacetimeDBClient: Unsubscribe request sent successfully (BSATN), Query ID: %d" % query_id)
		return OK

	printerr("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	return ERR_CONNECTION_ERROR


func call_reducer(reducer_name: String, args: Array = [], types: Array = []) -> SpacetimeDBReducerCall:
	if not is_connected_db():
		printerr("SpacetimeDBClient: Cannot call reducer, not connected.")
		return SpacetimeDBReducerCall.fail(ERR_CONNECTION_ERROR)

	var args_bytes: PackedByteArray = _serializer._serialize_arguments(args, types)

	if _serializer.has_error():
		printerr("Failed to serialize args for %s: %s" % [reducer_name, _serializer.get_last_error()])
		return SpacetimeDBReducerCall.fail(ERR_PARSE_ERROR)

	var request_id: int = _next_request_id
	_next_request_id += 1

	var call_data: CallReducerMessage = CallReducerMessage.new(reducer_name, args_bytes, request_id, 0)
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.CALL_REDUCER,
		call_data,
	)

	if _serializer.has_error():
		printerr("SpacetimeDBClient: Failed to serialize CallReducer message: %s" % _serializer.get_last_error())
		return SpacetimeDBReducerCall.fail(ERR_PARSE_ERROR)

	if debug_mode:
		print("DEBUG: call_reducer: Calling reducer '%s' with request id '%d' and message bytes: %s (argument bytes: %s)" % [reducer_name, request_id, message_bytes, args_bytes])

	# Access the internal _websocket peer directly (might need adjustment if _connection API changes)
	if _connection and _connection._websocket: # Basic check
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			print("SpacetimeDBClient: Error sending CallReducer JSON message: ", err)
			return SpacetimeDBReducerCall.fail(err)

		var handle: SpacetimeDBReducerCall = SpacetimeDBReducerCall.create(self, request_id)
		_pending_reducer_calls[request_id] = handle
		return handle

	print("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	return SpacetimeDBReducerCall.fail(ERR_CONNECTION_ERROR)


func call_procedure(procedure_name: String, args: Array = [], types: Array = [], return_bsatn_type: StringName = &"") -> SpacetimeDBProcedureCall:
	if not is_connected_db():
		printerr("SpacetimeDBClient: Cannot call procedure, not connected.")
		return SpacetimeDBProcedureCall.fail(ERR_CONNECTION_ERROR)

	var args_bytes: PackedByteArray = _serializer._serialize_arguments(args, types)
	if _serializer.has_error():
		printerr("Failed to serialize args for %s: %s" % [procedure_name, _serializer.get_last_error()])
		return SpacetimeDBProcedureCall.fail(ERR_PARSE_ERROR)

	var request_id: int = _next_request_id
	_next_request_id += 1

	var call_data := CallProcedureMessage.new(procedure_name, args_bytes, request_id, 0)
	var message_bytes: PackedByteArray = _serializer.serialize_client_message(
		SpacetimeDBClientMessage.CALL_PROCEDURE,
		call_data,
	)

	if _serializer.has_error():
		printerr("SpacetimeDBClient: Failed to serialize CallProcedure message: %s" % _serializer.get_last_error())
		return SpacetimeDBProcedureCall.fail(ERR_PARSE_ERROR)

	if debug_mode:
		print("DEBUG: call_procedure: Calling procedure '%s' with request id '%d'" % [procedure_name, request_id])

	if _connection and _connection._websocket:
		var err: Error = _connection.send_bytes(message_bytes)
		if err != OK:
			print("SpacetimeDBClient: Error sending CallProcedure message: ", err)
			return SpacetimeDBProcedureCall.fail(err)

		var handle := SpacetimeDBProcedureCall.create(self, request_id, return_bsatn_type)
		_pending_procedure_calls[request_id] = handle
		return handle

	print("SpacetimeDBClient: Internal error - WebSocket peer not available in connection.")
	return SpacetimeDBProcedureCall.fail(ERR_CONNECTION_ERROR)


func wait_for_reducer_response(request_id_to_match: int, timeout_seconds: float = 10.0) -> TransactionUpdateMessage:
	if request_id_to_match < 0:
		return null
	# Check if result already arrived before we started waiting
	if _reducer_result_cache.has(request_id_to_match):
		var cached: TransactionUpdateMessage = _reducer_result_cache[request_id_to_match]
		_reducer_result_cache.erase(request_id_to_match)
		print_log("SpacetimeDBClient: Cache hit for Req ID: %d" % request_id_to_match)
		return cached
	var timer: SceneTreeTimer = get_tree().create_timer(timeout_seconds)
	var result_container: Array[TransactionUpdateMessage] = [null]
	var done: bool = false
	var connection: Callable = func(rid: int, tx_update: TransactionUpdateMessage) -> void:
		if rid == request_id_to_match and not done:
			done = true
			result_container[0] = tx_update
			_reducer_result_cache.erase(rid)
			timer.time_left = 0

	reducer_result_received.connect(connection)
	await timer.timeout
	reducer_result_received.disconnect(connection)

	if not done:
		printerr("SpacetimeDBClient: Timeout waiting for response for Req ID: %d" % request_id_to_match)
		return null

	print_log("SpacetimeDBClient: Received matching response for Req ID: %d" % request_id_to_match)
	return result_container[0]


func wait_for_procedure_response(request_id_to_match: int, timeout_seconds: float = 10.0) -> PackedByteArray:
	if request_id_to_match < 0:
		return PackedByteArray()
	if _procedure_result_cache.has(request_id_to_match):
		var cached: PackedByteArray = _procedure_result_cache[request_id_to_match]
		_procedure_result_cache.erase(request_id_to_match)
		print_log("SpacetimeDBClient: Procedure cache hit for Req ID: %d" % request_id_to_match)
		return cached
	var timer: SceneTreeTimer = get_tree().create_timer(timeout_seconds)
	var result_container: Array[PackedByteArray] = [PackedByteArray()]
	var done: bool = false
	var connection: Callable = func(rid: int, ret_bytes: PackedByteArray) -> void:
		if rid == request_id_to_match and not done:
			done = true
			result_container[0] = ret_bytes
			_procedure_result_cache.erase(rid)
			timer.time_left = 0

	procedure_result_received.connect(connection)
	await timer.timeout
	procedure_result_received.disconnect(connection)

	if not done:
		printerr("SpacetimeDBClient: Timeout waiting for procedure response for Req ID: %d" % request_id_to_match)
		return PackedByteArray()

	print_log("SpacetimeDBClient: Received matching procedure response for Req ID: %d" % request_id_to_match)
	return result_container[0]


# virtual func _init_db()
func _init_db(local_db: LocalDatabase) -> void:
	pass


func _load_token_or_request() -> void:
	if _token:
		# If token is already set, use it
		_on_token_received(_token)
		return

	if one_time_token == false:
		# Try loading saved token
		if FileAccess.file_exists(token_save_path):
			var file: FileAccess = FileAccess.open(token_save_path, FileAccess.READ)
			if file:
				var saved_token: String = file.get_as_text().strip_edges()
				file.close()
				if not saved_token.is_empty():
					print_log("SpacetimeDBClient: Using saved token.")
					_on_token_received(saved_token) # Directly use the saved token
					return

	# If no valid saved token, request a new one if auto-request is enabled
	if auto_request_token:
		print_log("SpacetimeDBClient: No valid saved token found, requesting new one.")
		_rest_api.request_new_token()
	else:
		printerr("SpacetimeDBClient: No token available and auto_request_token is false.")
		connection_error.emit(-1, "Authentication token unavailable")


func _generate_connection_id() -> String:
	var random_bytes: PackedByteArray = []
	random_bytes.resize(16)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	for i: int in 16:
		random_bytes[i] = rng.randi_range(0, 255)
	return random_bytes.hex_encode() # Return as hex string


func _on_token_received(received_token: String) -> void:
	print_log("SpacetimeDBClient: Token acquired.")
	self._token = received_token
	_save_token(received_token)
	var conn_id: String = _generate_connection_id()
	# Pass token to components that need it
	_connection.set_token(self._token)
	_rest_api.set_token(self._token) # REST API might also need it

	# Now attempt to connect WebSocket
	_connection.connect_to_database(base_url, database_name, conn_id)


func _on_token_request_failed(error_code: int, response_body: String) -> void:
	printerr("SpacetimeDBClient: Failed to acquire token. Cannot connect.")
	connection_error.emit(error_code, "Failed to acquire authentication token")


func _save_token(token_to_save: String) -> void:
	var dir_path: String = token_save_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		var err: Error = DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			printerr("SpacetimeDBClient: Failed to create directory for token: ", dir_path)
			return
	var file: FileAccess = FileAccess.open(token_save_path, FileAccess.WRITE)
	if file:
		file.store_string(token_to_save)
		file.close()
	else:
		printerr("SpacetimeDBClient: Failed to save token to path: ", token_save_path)


func _on_websocket_message_received(raw_bytes: PackedByteArray) -> void:
	if not _is_initialized:
		return
	if use_threading:
		_packet_mutex.lock()
		_packet_queue.append(raw_bytes)
		_packet_mutex.unlock()
		_packet_semaphore.post()
	else:
		_result_queue.append_array(_parse_packet_and_get_resource(_decompress_and_parse(raw_bytes)))


func _thread_loop() -> void:
	while not _thread_should_exit:
		_packet_semaphore.wait()
		if _thread_should_exit:
			break

		# Drain all pending packets in one lock acquisition
		_packet_mutex.lock()
		if _packet_queue.is_empty():
			_packet_mutex.unlock()
			continue
		var local_packets: Array[PackedByteArray] = []
		local_packets.assign(_packet_queue)
		_packet_queue.clear()
		_packet_mutex.unlock()

		# Parse all packets without holding any lock
		var local_results: Array[SpacetimeDBServerMessage] = []
		for packet: PackedByteArray in local_packets:
			var payload: PackedByteArray = _decompress_and_parse(packet)
			local_results.append_array(_parse_packet_and_get_resource(payload))

		# Flush parsed results in one lock acquisition
		if not local_results.is_empty():
			_result_mutex.lock()
			_result_queue.append_array(local_results)
			_result_mutex.unlock()


func _process_results_asynchronously() -> void:
	if use_threading and not _result_mutex:
		return

	if use_threading:
		_result_mutex.lock()

	if _result_queue.is_empty():
		if use_threading:
			_result_mutex.unlock()
		return

	# Swap entire queue out under the lock, process without holding it
	var batch: Array[SpacetimeDBServerMessage] = []
	batch.assign(_result_queue)
	_result_queue.clear()

	if use_threading:
		_result_mutex.unlock()

	# Respect the per-frame message limit, carry overflow to next frame
	var limit: int = mini(batch.size(), _message_limit_in_frame)
	for i: int in limit:
		_handle_parsed_message(batch[i])

	# Re-queue any overflow (processed first next frame - already ordered)
	if batch.size() > limit:
		if use_threading:
			_result_mutex.lock()
		var overflow: Array[SpacetimeDBServerMessage] = batch.slice(limit)
		overflow.append_array(_result_queue)
		_result_queue = overflow
		if use_threading:
			_result_mutex.unlock()


func _decompress_and_parse(raw_bytes: PackedByteArray) -> PackedByteArray:
	if raw_bytes.size() < 2:
		printerr("SpacetimeDBClient: Received packet too small (%d bytes), ignoring." % raw_bytes.size())
		return PackedByteArray()
	var compression: int = raw_bytes.get(0)
	var payload: PackedByteArray = raw_bytes.slice(1)
	match compression:
		0:
			pass
		1:
			printerr("SpacetimeDBClient (Thread) : Brotli compression not supported!")
		2:
			payload = DataDecompressor.decompress_packet(payload)
	return payload


func _parse_packet_and_get_resource(bsatn_bytes: PackedByteArray) -> Array[SpacetimeDBServerMessage]:
	if not _deserializer:
		return []

	var result: Array[SpacetimeDBServerMessage] = _deserializer.process_bytes_and_extract_messages(bsatn_bytes)

	if _deserializer.has_error():
		printerr("SpacetimeDBClient: Failed to parse BSATN packet: ", _deserializer.get_last_error())
		return []

	return result


func _handle_parsed_message(message: SpacetimeDBServerMessage) -> void:
	if message == null:
		printerr("SpacetimeDBClient: Parser returned null message.")
		return

	# Handle known message types

	if message is IdentityTokenMessage:
		print_log("SpacetimeDBClient: Received Identity Token.")
		_identity = message.identity
		if not _token and message.token:
			_token = message.token
		_connection_id = message.connection_id
		self.connected.emit(_identity, _token)

		# Handle reconnection completion
		if _reconnect_state == _ReconnectState.RECONNECTING:
			print_log("SpacetimeDBClient: Reconnected. Re-subscribing to %d query sets." % _saved_subscription_queries.size())
			_reconnect_state = _ReconnectState.IDLE
			_reconnect_attempt = 0
			if _saved_subscription_queries.is_empty():
				reconnected.emit()
			else:
				_resubscribe_saved_queries()

	elif message is SubscribeAppliedMessage:
		_local_db.apply_database_subscription_applied(message)
		if not _received_initial_subscription:
			_received_initial_subscription = true
			self.database_initialized.emit()
		var qid: int = message.query_set_id.id
		if pending_subscriptions.has(qid):
			var sub: SpacetimeDBSubscription = pending_subscriptions[qid]
			pending_subscriptions.erase(qid)
			current_subscriptions[qid] = sub
			sub.applied.emit()

	elif message is UnsubscribeAppliedMessage:
		if not message.tables.is_empty():
			for table_update: TableUpdateData in message.tables:
				_local_db.apply_table_update(table_update)
		var qid: int = message.query_id.id
		if current_subscriptions.has(qid):
			var sub: SpacetimeDBSubscription = current_subscriptions[qid]
			current_subscriptions.erase(qid)
			sub.end.emit()
		print_log("SpacetimeDBClient: Unsubscribe applied for query_id %d." % qid)

	elif message is SubscriptionErrorMessage:
		printerr("SpacetimeDBClient: Subscription error: %s" % message.error_message)
		if message.has_query_id():
			var qid: int = message.query_id.id
			if pending_subscriptions.has(qid):
				var sub: SpacetimeDBSubscription = pending_subscriptions[qid]
				pending_subscriptions.erase(qid)
				sub.error_message = message.error_message
				sub.end.emit()
			elif current_subscriptions.has(qid):
				var sub: SpacetimeDBSubscription = current_subscriptions[qid]
				current_subscriptions.erase(qid)
				sub.error_message = message.error_message
				sub.end.emit()

	elif message is TransactionUpdateMessage:
		_handle_transaction_update(message)

	elif message is ReducerResultMessage:
		var rid: int = message.request_id
		var outcome: ReducerOutcomeEnum = message.reducer_result
		var tx_update: TransactionUpdateMessage = null
		var handle: SpacetimeDBReducerCall = _pending_reducer_calls.get(rid)
		# Only stamp the handle if it's still PENDING (avoids overwriting a TIMEOUT verdict)
		var can_stamp: bool = handle and handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING
		match outcome.value:
			ReducerOutcomeEnum.Options.ok:
				tx_update = outcome.get_ok()
				if tx_update != null:
					_handle_transaction_update(tx_update)
				if can_stamp:
					handle.outcome = SpacetimeDBReducerCall.Outcome.OK
					handle.transaction_update = tx_update
			ReducerOutcomeEnum.Options.okEmpty:
				if can_stamp:
					handle.outcome = SpacetimeDBReducerCall.Outcome.OK_EMPTY
			ReducerOutcomeEnum.Options.err:
				var err_bytes: PackedByteArray = outcome.get_err()
				var err_msg: String = err_bytes.get_string_from_utf8()
				if err_msg.is_empty() and not err_bytes.is_empty():
					err_msg = "raw error bytes: " + err_bytes.hex_encode()
				print_log("SpacetimeDBClient: Reducer returned error: %s" % err_msg)
				if can_stamp:
					handle.outcome = SpacetimeDBReducerCall.Outcome.ERROR
					handle.error_message = err_msg
			ReducerOutcomeEnum.Options.internalError:
				var err_msg: String = outcome.get_internal_error()
				printerr("SpacetimeDBClient: Reducer internal error: ", err_msg)
				if can_stamp:
					handle.outcome = SpacetimeDBReducerCall.Outcome.INTERNAL_ERROR
					handle.error_message = err_msg
		_pending_reducer_calls.erase(rid)
		_reducer_result_cache[rid] = tx_update
		# Evict oldest entry to prevent unbounded growth from fire-and-forget calls
		while _reducer_result_cache.size() > 256:
			var oldest_key: int
			for k: int in _reducer_result_cache:
				oldest_key = k
				break
			_reducer_result_cache.erase(oldest_key)
		reducer_result_received.emit(rid, tx_update)

	elif message is ProcedureResultData:
		var rid: int = message.request_id
		var handle: SpacetimeDBProcedureCall = _pending_procedure_calls.get(rid)
		var can_stamp: bool = handle and handle.outcome == SpacetimeDBProcedureCall.Outcome.PENDING
		var ret_bytes: PackedByteArray = PackedByteArray()

		match message.status_tag:
			0: # Returned
				ret_bytes = message.return_bytes
				if can_stamp:
					handle.outcome = SpacetimeDBProcedureCall.Outcome.RETURNED
					handle.return_bytes = ret_bytes
			1: # InternalError
				printerr("SpacetimeDBClient: Procedure internal error: ", message.error_message)
				if can_stamp:
					handle.outcome = SpacetimeDBProcedureCall.Outcome.INTERNAL_ERROR
					handle.error_message = message.error_message

		_pending_procedure_calls.erase(rid)
		_procedure_result_cache[rid] = ret_bytes
		while _procedure_result_cache.size() > 256:
			var oldest_key: int
			for k: int in _procedure_result_cache:
				oldest_key = k
				break
			_procedure_result_cache.erase(oldest_key)
		procedure_result_received.emit(rid, ret_bytes)

	else:
		print_log("SpacetimeDBClient: Unhandled message type: " + message.get_class())


func _handle_transaction_update(update_sets: TransactionUpdateMessage) -> void:
	for dataset: DatabaseUpdateData in update_sets.query_sets:
		_local_db.apply_database_update(dataset)
		if not _received_initial_subscription:
			_received_initial_subscription = true
			self.database_initialized.emit()
	# Emit the full transaction update signal regardless of status
	self.transaction_update_received.emit(update_sets)


# --- Reconnection ---

func _on_connection_disconnected() -> void:
	if _intentional_disconnect:
		_intentional_disconnect = false
		disconnected.emit()
		return

	if connection_options and connection_options.auto_reconnect:
		print_log("SpacetimeDBClient: Unintentional disconnect, starting auto-reconnect.")
		_start_reconnection()
	else:
		disconnected.emit()


func _on_connection_error(code: int, reason: String) -> void:
	if _intentional_disconnect:
		_intentional_disconnect = false
		connection_error.emit(code, reason)
		return

	if _reconnect_state == _ReconnectState.RECONNECTING:
		print_log("SpacetimeDBClient: Reconnect attempt %d failed: %s (code %d)" % [_reconnect_attempt, reason, code])
		_schedule_next_reconnect_attempt()
	elif connection_options and connection_options.auto_reconnect:
		print_log("SpacetimeDBClient: Connection error, starting auto-reconnect. Reason: %s" % reason)
		connection_error.emit(code, reason)
		_start_reconnection()
	else:
		connection_error.emit(code, reason)


func _start_reconnection() -> void:
	if _reconnect_state == _ReconnectState.RECONNECTING:
		return

	_reconnect_state = _ReconnectState.RECONNECTING
	_reconnect_attempt = 0

	_saved_subscription_queries.clear()
	for sub: SpacetimeDBSubscription in current_subscriptions.values():
		if sub.queries.size() > 0:
			_saved_subscription_queries.append(sub.queries.duplicate())
	print_log("SpacetimeDBClient: Saved %d subscription query sets for re-subscription." % _saved_subscription_queries.size())

	_schedule_next_reconnect_attempt()


func _schedule_next_reconnect_attempt() -> void:
	var max_attempts: int = connection_options.max_reconnect_attempts

	if max_attempts > 0 and _reconnect_attempt >= max_attempts:
		print_log("SpacetimeDBClient: All %d reconnect attempts exhausted." % max_attempts)
		_reconnect_state = _ReconnectState.IDLE
		_reconnect_attempt = 0
		_saved_subscription_queries.clear()
		reconnect_failed.emit()
		disconnected.emit()
		return

	_reconnect_attempt += 1
	var backoff: float = _calculate_backoff(_reconnect_attempt)
	var max_str: String = str(max_attempts) if max_attempts > 0 else "inf"
	print_log("SpacetimeDBClient: Reconnect attempt %d/%s in %.2f seconds." % [_reconnect_attempt, max_str, backoff])

	reconnecting.emit(_reconnect_attempt, max_attempts)

	var tree: SceneTree = get_tree()
	if not tree:
		printerr("SpacetimeDBClient: Cannot schedule reconnect — not in scene tree.")
		_reconnect_state = _ReconnectState.IDLE
		reconnect_failed.emit()
		disconnected.emit()
		return

	_reconnect_timer = tree.create_timer(backoff)
	if _reconnect_timer:
		_reconnect_timer.timeout.connect(_attempt_reconnect, CONNECT_ONE_SHOT)
	else:
		printerr("SpacetimeDBClient: Failed to create reconnect timer.")
		_reconnect_state = _ReconnectState.IDLE
		reconnect_failed.emit()
		disconnected.emit()


func _calculate_backoff(attempt: int) -> float:
	var base_delay: float = connection_options.reconnect_initial_delay * pow(
		connection_options.reconnect_backoff_multiplier, attempt - 1
	)
	base_delay = minf(base_delay, connection_options.reconnect_max_delay)

	var jitter_range: float = base_delay * connection_options.reconnect_jitter_fraction
	var jitter_offset: float = randf() * jitter_range
	return base_delay - jitter_offset


func _attempt_reconnect() -> void:
	_reconnect_timer = null

	if _reconnect_state != _ReconnectState.RECONNECTING:
		return

	if not _connection or _token.is_empty():
		printerr("SpacetimeDBClient: Cannot reconnect — missing connection or token.")
		_reconnect_state = _ReconnectState.IDLE
		reconnect_failed.emit()
		disconnected.emit()
		return

	_prepare_for_reconnect()

	var conn_id: String = _generate_connection_id()
	_connection.set_token(_token)

	print_log("SpacetimeDBClient: Attempting reconnect (attempt %d)." % _reconnect_attempt)
	_connection.connect_to_database(base_url, database_name, conn_id)


func _prepare_for_reconnect() -> void:
	if _local_db:
		_local_db.clear_all_tables()

	_reducer_result_cache.clear()
	for handle: SpacetimeDBReducerCall in _pending_reducer_calls.values():
		if handle.outcome == SpacetimeDBReducerCall.Outcome.PENDING:
			handle.outcome = SpacetimeDBReducerCall.Outcome.DISCONNECTED
			handle.error_message = "Connection lost during reducer call"
	_pending_reducer_calls.clear()

	_procedure_result_cache.clear()
	for handle: SpacetimeDBProcedureCall in _pending_procedure_calls.values():
		if handle.outcome == SpacetimeDBProcedureCall.Outcome.PENDING:
			handle.outcome = SpacetimeDBProcedureCall.Outcome.DISCONNECTED
			handle.error_message = "Connection lost during procedure call"
	_pending_procedure_calls.clear()

	for sub: SpacetimeDBSubscription in pending_subscriptions.values():
		sub.end.emit()
	for sub: SpacetimeDBSubscription in current_subscriptions.values():
		sub.end.emit()
	pending_subscriptions.clear()
	current_subscriptions.clear()

	_received_initial_subscription = false
	_next_query_id = 0
	_next_request_id = 0

	if use_threading and _packet_mutex:
		_packet_mutex.lock()
		_packet_queue.clear()
		_packet_mutex.unlock()

		_result_mutex.lock()
		_result_queue.clear()
		_result_mutex.unlock()


func _cancel_reconnection() -> void:
	if _reconnect_state == _ReconnectState.IDLE:
		return

	print_log("SpacetimeDBClient: Cancelling reconnection.")
	_reconnect_state = _ReconnectState.IDLE
	_reconnect_attempt = 0
	_saved_subscription_queries.clear()

	if _reconnect_timer and _reconnect_timer.time_left > 0:
		if _reconnect_timer.timeout.is_connected(_attempt_reconnect):
			_reconnect_timer.timeout.disconnect(_attempt_reconnect)
	_reconnect_timer = null


func _resubscribe_saved_queries() -> void:
	var total_sets: int = _saved_subscription_queries.size()
	var applied_count: Array[int] = [0]

	for queries: PackedStringArray in _saved_subscription_queries:
		var sub: SpacetimeDBSubscription = subscribe(queries)
		if sub.error != OK:
			printerr("SpacetimeDBClient: Failed to re-subscribe during reconnection: %s" % error_string(sub.error))
			applied_count[0] += 1
			if applied_count[0] >= total_sets:
				_saved_subscription_queries.clear()
				reconnected.emit()
			continue

		sub.applied.connect(func() -> void:
			applied_count[0] += 1
			print_log("SpacetimeDBClient: Re-subscription applied (%d/%d)." % [applied_count[0], total_sets])
			if applied_count[0] >= total_sets:
				_saved_subscription_queries.clear()
				reconnected.emit()
		, CONNECT_ONE_SHOT)

	if total_sets == 0:
		reconnected.emit()

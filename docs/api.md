# API Reference

## `SpacetimeDBClient` class

**Inherits:** Node

A connection to a SpacetimeDB database is controlled by the `SpacetimeDBClient` class. All generated [`ModuleClient`](#generated-moduleclient-class) classes extend this class.

### Connect to a database

#### `connect_db()` method

```gdscript
class SpacetimeDBClient:
    func connect_db(
        host_url: String,
        database_name: String,
        options: SpacetimeDBConnectionOptions = null
    ) -> void
```

Connects to a SpacetimeDB database.

| Name | Description |
| --- | --- |
| host_url | The base HTTP URL of the SpacetimeDB instance (e.g. `"http://127.0.0.1:3000"`). |
| database_name | The name or identity of the remote database. |
| options | Client connection options, see the [`SpacetimeDBConnectionOptions`](#spacetimedbconnectionoptions-resource) documentation. |

#### `disconnect_db()` method

```gdscript
class SpacetimeDBClient:
    func disconnect_db() -> void
```

Disconnects from the SpacetimeDB database.

#### `is_connected_db()` method

```gdscript
class SpacetimeDBClient:
    func is_connected_db() -> bool
```

Returns `true` if the client is currently connected to a SpacetimeDB database.

### Query the local database cache

#### `get_local_database()` method

```gdscript
class SpacetimeDBClient:
    func get_local_database() -> LocalDatabase
```

Get the untyped [`LocalDatabase`](#localdatabase-class) instance by calling `SpacetimeDBClient.get_local_database()`.

### Get the identity of the current connection

#### `get_local_identity()` method

```gdscript
class SpacetimeDBClient:
    func get_local_identity() -> PackedByteArray
```

Get the SpacetimeDB identity of the current connection by calling `SpacetimeDBClient.get_local_identity()`.

### Subscribe to queries

#### `subscribe()` method

```gdscript
class SpacetimeDBClient:
    func subscribe(queries: PackedStringArray) -> SpacetimeDBSubscription
```

| Name    | Description                              |
| ------- | ---------------------------------------- |
| queries | An array of SQL queries to subscribe to. |

Subscribe to queries by calling `subscribe(queries)`, which returns a [`SpacetimeDBSubscription`](#spacetimedbsubscription-class) instance.

See the [SpacetimeDB SQL Reference](https://spacetimedb.com/docs/sql#subscriptions) for information on the queries SpacetimeDB supports.

#### `unsubscribe()` method

```gdscript
class SpacetimeDBClient:
    func unsubscribe(query_id: int) -> Error
```

| Name     | Description                             |
| -------- | --------------------------------------- |
| query_id | The query id of an active subscription. |

Close a subscription by calling `unsubscribe(query_id)` with the query id of an existing query. A Godot `Error` is returned to indicate success or failure. The subscription's `end` signal will fire when the server confirms the unsubscribe.

### Call reducers

#### `call_reducer()` method

```gdscript
class SpacetimeDBClient:
    func call_reducer(reducer_name: String, args: Array = [], types: Array = []) -> SpacetimeDBReducerCall
```

| Name         | Description                                              |
| ------------ | -------------------------------------------------------- |
| reducer_name | The name of the reducer to call.                         |
| args         | The arguments to pass to the reducer.                    |
| types        | The BSATN types of the arguments to pass to the reducer. |

Call a reducer with `call_reducer(reducer_name, args, types)` a [`SpacetimeDBReducerCall`](#spacetimedbreducercall-class) instance is returned which contains the request id or an error.

It is recommended you use the auto-generated reducer methods rather than calling `call_reducer` directly. See [Calling reducers](#calling-reducers).

#### `wait_for_reducer_response()` method

```gdscript
class SpacetimeDBClient:
    async func wait_for_reducer_response(request_id: int, timeout_seconds: float = 10.0) -> TransactionUpdateMessage
```

| Name            | Description                                                       |
| --------------- | ----------------------------------------------------------------- |
| request_id      | The id of the reducer call request to wait for.                   |
| timeout_seconds | The number of seconds to wait for the response before timing out. |

Waits for the reducer call response and returns the received `TransactionUpdateMessage`, or returns `null` if there is an error or it times out.

### Call procedures

#### `call_procedure()` method

```gdscript
class SpacetimeDBClient:
    func call_procedure(procedure_name: String, args: Array = [], types: Array = [], return_bsatn_type: StringName = &"") -> SpacetimeDBProcedureCall
```

| Name              | Description                                                 |
| ----------------- | ----------------------------------------------------------- |
| procedure_name    | The name of the procedure to call.                          |
| args              | The arguments to pass to the procedure.                     |
| types             | The BSATN types of the arguments.                           |
| return_bsatn_type | The BSATN type string for decoding the return value.        |

Call a procedure with `call_procedure()`, which returns a [`SpacetimeDBProcedureCall`](#spacetimedbprocedurecall-class) instance. It is recommended you use the auto-generated procedure methods. See [Calling procedures](#calling-procedures).

#### `wait_for_procedure_response()` method

```gdscript
class SpacetimeDBClient:
    async func wait_for_procedure_response(request_id: int, timeout_seconds: float = 10.0) -> PackedByteArray
```

| Name            | Description                                                       |
| --------------- | ----------------------------------------------------------------- |
| request_id      | The id of the procedure call request to wait for.                 |
| timeout_seconds | The number of seconds to wait for the response before timing out. |

Waits for the procedure call response and returns the raw BSATN-encoded return bytes, or returns an empty `PackedByteArray` if there is an error or it times out.

### Signals

| Signal | Description |
| --- | --- |
| `connected(identity: PackedByteArray, token: String)` | Emitted when the connection is established. |
| `disconnected` | Emitted when the connection is closed. |
| `connection_error(code: int, reason: String)` | Emitted when a connection error occurs. |
| `database_initialized` | Emitted when the first subscription is applied and the local DB is populated. |
| `row_inserted(table_name: StringName, row: Resource)` | Emitted when a row is inserted. |
| `row_updated(table_name: StringName, old_row: Resource, new_row: Resource)` | Emitted when a row is updated. |
| `row_deleted(table_name: StringName, row: Resource)` | Emitted when a row is deleted. |
| `row_transactions_completed(table_name: StringName)` | Emitted when all row changes for a table update are applied. |
| `transaction_update_received(update: TransactionUpdateMessage)` | Emitted when a transaction update is received. |
| `reducer_result_received(request_id: int, tx_update: TransactionUpdateMessage)` | Emitted when a reducer result arrives. |
| `procedure_result_received(request_id: int, return_bytes: PackedByteArray)` | Emitted when a procedure result arrives. |
| `reconnecting(attempt: int, max_attempts: int)` | Emitted before each reconnection attempt. |
| `reconnected` | Emitted after a successful reconnection and all subscriptions are restored. |
| `reconnect_failed` | Emitted when all reconnection attempts are exhausted. |

## Generated `ModuleClient` class

**Inherits:** [SpacetimeDBClient](#spacetimedbclient-class) < Node

This class is generated per module and contains information about the types, tables, reducers, and procedures defined by your module.

### Access tables, reducers, and procedures

#### `db` property

```gdscript
class ModuleClient:
    var db: ModuleDb
```

The `db` property provides access to the subscribed view of the database's tables. See [Access the local database](#access-the-local-database).

#### `reducers` property

```gdscript
class ModuleClient:
    const reducers: ModuleReducers
```

The `reducers` property provides access to reducers exposed by the module. See [Calling reducers](#calling-reducers).

#### `procedures` property

```gdscript
class ModuleClient:
    const procedures: ModuleProcedures
```

The `procedures` property provides access to procedures exposed by the module. See [Calling procedures](#calling-procedures).

### Access the local database

Each table defined by your module has a property, whose name is the table name converted to `snake_case`. The table properties are [`ModuleTable`](#moduletable-class) instances which have methods for accessing rows and registering `on_insert`, `on_update` and `on_delete` listeners.

#### `count` method

```gdscript
class ModuleTable:
    func count() -> int
```

Returns the number of rows of the table in the local database, i.e. the total number of rows which match any of the subscribed queries.

#### `iter` method

```gdscript
class ModuleTable:
    func iter() -> Array[Row]
```

An array of all of the subscribed rows in the local database, i.e. those which match any of the subscribed queries.

The `Row` type will be the auto-generated type which matches the row type defined in the module.

#### `on_insert` listener

```gdscript
class ModuleTable:
    func on_insert(listener: Callable) -> void

    func remove_on_insert(listener: Callable) -> void

# Listener function signature
func(row: Row) -> void
```

The `on_insert` listener runs whenever a new row is inserted into the local database.

The `Row` type will be the auto-generated type which matches the row type defined in the module.

Call `remove_on_insert` to un-register a previously registered listener.

#### `on_update` listener

```gdscript
class ModuleTable:
    func on_update(listener: Callable) -> void

    func remove_on_update(listener: Callable) -> void

# Listener function signature
func(old_row: Row, new_row: Row) -> void
```

The `on_update` listener runs whenever a row already in the local database is updated.

The `Row` type will be the auto-generated type which matches the row type defined in the module.

Call `remove_on_update` to un-register a previously registered listener.

#### `on_delete` listener

```gdscript
class ModuleTable:
    func on_delete(listener: Callable) -> void

    func remove_on_delete(listener: Callable) -> void

# Listener function signature
func(row: Row) -> void
```

The `on_delete` listener runs whenever a row already in the local database is deleted.

The `Row` type will be the auto-generated type which matches the row type defined in the module.

Call `remove_on_delete` to un-register a previously registered listener.

#### Query helpers

```gdscript
class ModuleTable:
    func find_where(predicate: Callable) -> Array
    func first_where(predicate: Callable) -> Row
    func find_by(field: StringName, value: Variant) -> Array
    func first_by(field: StringName, value: Variant) -> Row
    func count_where(predicate: Callable) -> int
```

| Method | Description |
| --- | --- |
| `find_where` | Returns all rows matching the predicate. |
| `first_where` | Returns the first row matching the predicate, or `null`. |
| `find_by` | Returns all rows where `field` equals `value`. |
| `first_by` | Returns the first row where `field` equals `value`, or `null`. |
| `count_where` | Returns the count of rows matching the predicate. |

#### Unique index access

For each unique constraint on a table, its table class has a property whose name is the unique column name. This property is a `ModuleTableUniqueIndex` which has a `find` method.

```gdscript
class ModuleTableUniqueIndex:
    func find(col_val: Col) -> Row | null
```

Where `Col` is the column data type and `Row` is the table row type. If a row with the `col_val` exists in the local database, the method returns that row, otherwise it returns `null`.

#### BTree index access

This SDK does not currently support non-unique BTree indexes.

### Calling reducers

Each public reducer defined by your module has a method on the `.reducers` property. The method name is the reducer name converted to `snake_case`. Each reducer method takes the arguments defined by the reducer and returns a [`SpacetimeDBReducerCall`](#spacetimedbreducercall-class) handle.

```gdscript
func example_reducer(arg1: String, arg2: int) -> SpacetimeDBReducerCall
```

### Calling procedures

Each public procedure defined by your module has a method on the `.procedures` property. The method name is the procedure name converted to `snake_case`. Each procedure method takes the arguments defined by the procedure and returns a [`SpacetimeDBProcedureCall`](#spacetimedbprocedurecall-class) handle.

```gdscript
func example_procedure(arg1: String) -> SpacetimeDBProcedureCall
```

## `SpacetimeDBQuery` class

**Inherits:** RefCounted

A fluent query builder for constructing SQL subscription queries with input validation.

```gdscript
var query := SpacetimeDBQuery.table("players").where("online", true).to_sql()
# => "SELECT * FROM players WHERE online = true"
```

#### Static constructors

```gdscript
class SpacetimeDBQuery:
    static func table(name: String) -> SpacetimeDBQuery
    static func from(t: _ModuleTable) -> SpacetimeDBQuery
```

#### WHERE conditions

All conditions are AND'd together. Field names are validated to prevent SQL injection (alphanumeric and underscores only).

```gdscript
class SpacetimeDBQuery:
    func where(field: StringName, value: Variant) -> SpacetimeDBQuery
    func where_ne(field: StringName, value: Variant) -> SpacetimeDBQuery
    func where_gt(field: StringName, value: Variant) -> SpacetimeDBQuery
    func where_lt(field: StringName, value: Variant) -> SpacetimeDBQuery
    func where_gte(field: StringName, value: Variant) -> SpacetimeDBQuery
    func where_lte(field: StringName, value: Variant) -> SpacetimeDBQuery
```

#### Output

```gdscript
class SpacetimeDBQuery:
    func to_sql() -> String
```

#### Helpers

```gdscript
# Format a PackedByteArray identity for use in queries
SpacetimeDBQuery.identity(bytes: PackedByteArray) -> String
```

## `SpacetimeDBConnection` class

**Inherits:** Node

Holds and listens to the websocket connection to the SpacetimeDB server.

#### `CompressionPreference` enum

```gdscript
class SpacetimeDBConnection:
    enum CompressionPreference { NONE = 0, BROTLI = 1, GZIP = 2 }
```

The compression preference for the connection.

| Name   | Description                                                                  |
| ------ | ---------------------------------------------------------------------------- |
| NONE   | No compression.                                                              |
| BROTLI | Not supported. If set, the SDK warns and automatically falls back to GZIP.   |
| GZIP   | GZIP compression (recommended).                                              |

## `SpacetimeDBConnectionOptions` resource

**Inherits:** Resource

#### `compression` property

```gdscript
class SpacetimeDBConnectionOptions:
    var compression: CompressionPreference
```

The [`CompressionPreference`](#compressionpreference-enum) for the connection.

#### `threading` property

```gdscript
class SpacetimeDBConnectionOptions:
    var threading: bool = true
```

Whether to use threading for processing database update messages.

#### `one_time_token` property

```gdscript
class SpacetimeDBConnectionOptions:
    var one_time_token: bool = true
```

Whether to use a one-time token for the connection.

#### `token` property

```gdscript
class SpacetimeDBConnectionOptions:
    var token: String = ""
```

The token to use for the connection, `one_time_token` determines whether this token is saved to disk.

#### `debug_mode` property

```gdscript
class SpacetimeDBConnectionOptions:
    var debug_mode: bool = false
```

Enables verbose logging.

#### `inbound_buffer_size` property

```gdscript
class SpacetimeDBConnectionOptions:
    var inbound_buffer_size: int = 1024 * 1024 * 2
```

The maximum size of the inbound buffer.

#### `outbound_buffer_size` property

```gdscript
class SpacetimeDBConnectionOptions:
    var outbound_buffer_size: int = 1024 * 1024 * 2
```

#### `set_all_buffer_size()` method

Sets the inbound and outbound buffer sizes:

```gdscript
class SpacetimeDBConnectionOptions:
    func set_all_buffer_size(size: int) -> void
```

| Name | Description                                             |
| ---- | ------------------------------------------------------- |
| size | The size of the inbound and outbound buffers, in bytes. |

#### `monitor_mode` property

```gdscript
class SpacetimeDBConnectionOptions:
    var monitor_mode: bool = false
```

When enabled, registers custom Godot Performance monitors for tracking network statistics (packets/bytes sent and received per second and total).

#### Reconnection options

```gdscript
class SpacetimeDBConnectionOptions:
    var auto_reconnect: bool = false
    var max_reconnect_attempts: int = 10       # 0 = infinite
    var reconnect_initial_delay: float = 1.0   # seconds
    var reconnect_max_delay: float = 30.0      # seconds (cap)
    var reconnect_backoff_multiplier: float = 2.0
    var reconnect_jitter_fraction: float = 0.5 # 0.0–1.0
```

| Name | Description |
| --- | --- |
| `auto_reconnect` | Whether to automatically reconnect on disconnect. Must be `true` for reconnection to work. |
| `max_reconnect_attempts` | Maximum number of reconnection attempts. Set to 0 for infinite retries. |
| `reconnect_initial_delay` | Initial delay before the first reconnection attempt, in seconds. |
| `reconnect_max_delay` | Maximum delay between reconnection attempts, in seconds. |
| `reconnect_backoff_multiplier` | Multiplier applied to the delay after each failed attempt. |
| `reconnect_jitter_fraction` | Random jitter applied to each delay (0.0 = none, 1.0 = full delay range). Prevents thundering herd on reconnect. |

## `SpacetimeDBSubscription` class

**Inherits:** RefCounted

A handle to a subscription to the SpacetimeDB database. The handle does not contain or provide access to the subscribed data, all subscribed rows are available via the module's [`LocalDatabase`](#localdatabase-class). See [Access the local database](#access-the-local-database).

#### `query_id` property

```gdscript
class SpacetimeDBSubscription:
    var query_id: int
```

The id of the subscription.

#### `queries` property

```gdscript
class SpacetimeDBSubscription:
    var queries: PackedStringArray
```

The SQL queries that were subscribed to.

#### `error` property

```gdscript
class SpacetimeDBSubscription:
    var error: Error
```

A Godot `Error` that is either `OK` if the subscription request was sent successfully, or an error if it failed to send.

#### `error_message` property

```gdscript
class SpacetimeDBSubscription:
    var error_message: String
```

A human-readable error message from the server if the subscription failed. Empty string if no error.

#### `active` property

```gdscript
class SpacetimeDBSubscription:
    var active: bool
```

Indicates whether this subscription has been applied and has not yet been unsubscribed.

#### `ended` property

```gdscript
class SpacetimeDBSubscription:
    var ended: bool
```

Indicates if this subscription has been terminated due to an unsubscribe confirmation, a server error, or a disconnect.

#### `unsubscribe()` method

```gdscript
class SpacetimeDBSubscription:
    func unsubscribe() -> Error
```

Sends an unsubscribe request to the server. The `end` signal fires when the server confirms the unsubscribe via `UnsubscribeAppliedMessage`.

Returns `ERR_DOES_NOT_EXIST` if the subscription has already ended.

#### `wait_for_applied()` method

```gdscript
class SpacetimeDBSubscription:
    async func wait_for_applied(timeout_sec: float = 5) -> Error
```

| Name | Description |
| --- | --- |
| timeout_sec | The number of seconds to wait for the subscription to be applied before timing out. |

Waits for the subscription to be applied, or until it times out.

Returns:
- `OK` if the subscription was applied successfully.
- `ERR_TIMEOUT` if the timeout was reached.
- `ERR_DOES_NOT_EXIST` if the subscription ended or errored before being applied. Check `error_message` for details.

#### `wait_for_end()` method

```gdscript
class SpacetimeDBSubscription:
    async func wait_for_end(timeout_sec: float = 5) -> Error
```

| Name | Description |
| --- | --- |
| timeout_sec | The number of seconds to wait for the subscription to be terminated before timing out. |

Waits for the subscription to be terminated, or until it times out.

Returns `ERR_TIMEOUT` if the timeout is reached, `OK` otherwise.

#### `applied` signal

```gdscript
class SpacetimeDBSubscription:
    signal applied
```

Emitted when the server confirms the subscription is active (`SubscribeAppliedMessage`).

#### `end` signal

```gdscript
class SpacetimeDBSubscription:
    signal end
```

Emitted when the subscription ends. This happens when:
- The server confirms an unsubscribe (`UnsubscribeAppliedMessage`).
- The server reports a subscription error (`SubscriptionErrorMessage`) — check `error_message` for details.
- The client disconnects or reconnects — all existing subscription handles are ended.

## `SpacetimeDBReducerCall` class

**Inherits:** RefCounted

A handle to a reducer call to the SpacetimeDB database.

#### `Outcome` enum

```gdscript
class SpacetimeDBReducerCall:
    enum Outcome { PENDING, OK, OK_EMPTY, ERROR, INTERNAL_ERROR, TIMEOUT, DISCONNECTED }
```

| Value | Description |
| --- | --- |
| `PENDING` | Waiting for server response. |
| `OK` | Reducer succeeded with a transaction update. |
| `OK_EMPTY` | Reducer succeeded but produced no database changes. |
| `ERROR` | Reducer returned an error (check `error_message`). |
| `INTERNAL_ERROR` | Server-side internal error. |
| `TIMEOUT` | Response timed out. |
| `DISCONNECTED` | Connection was lost while waiting. |

#### `request_id` property

```gdscript
class SpacetimeDBReducerCall:
    var request_id: int
```

The id of the reducer call request.

#### `error` property

```gdscript
class SpacetimeDBReducerCall:
    var error: Error
```

A Godot `Error` that is `OK` if the request was sent, or an error if it failed to send.

#### `outcome` property

```gdscript
class SpacetimeDBReducerCall:
    var outcome: Outcome
```

The outcome of the reducer call. Initially `PENDING`, updated when the server responds.

#### `error_message` property

```gdscript
class SpacetimeDBReducerCall:
    var error_message: String
```

A human-readable error message if the reducer call failed.

#### `transaction_update` property

```gdscript
class SpacetimeDBReducerCall:
    var transaction_update: TransactionUpdateMessage
```

The `TransactionUpdateMessage` from the server when the outcome is `OK`. `null` for other outcomes.

#### `is_ok()` / `is_error()` / `is_completed()` methods

```gdscript
class SpacetimeDBReducerCall:
    func is_ok() -> bool          # outcome == OK or OK_EMPTY
    func is_error() -> bool       # outcome is ERROR, INTERNAL_ERROR, or DISCONNECTED
    func is_completed() -> bool   # outcome != PENDING
```

#### `wait_for_response()` method

```gdscript
class SpacetimeDBReducerCall:
    async func wait_for_response(timeout_sec: float = 10) -> TransactionUpdateMessage
```

| Name        | Description                                                       |
| ----------- | ----------------------------------------------------------------- |
| timeout_sec | The number of seconds to wait for the response before timing out. |

Waits for the reducer call response, or until it times out.

Returns the received `TransactionUpdateMessage`, or `null` if there was an error or it timed out. Check `outcome` and `error_message` after awaiting.

## `SpacetimeDBProcedureCall` class

**Inherits:** RefCounted

A handle to a procedure call to the SpacetimeDB database.

#### `Outcome` enum

```gdscript
class SpacetimeDBProcedureCall:
    enum Outcome { PENDING, RETURNED, ERROR, INTERNAL_ERROR, TIMEOUT, DISCONNECTED }
```

| Value | Description |
| --- | --- |
| `PENDING` | Waiting for server response. |
| `RETURNED` | Procedure returned successfully. |
| `ERROR` | Procedure returned an error (check `error_message`). |
| `INTERNAL_ERROR` | Server-side internal error. |
| `TIMEOUT` | Response timed out. |
| `DISCONNECTED` | Connection was lost while waiting. |

#### `request_id` property

```gdscript
class SpacetimeDBProcedureCall:
    var request_id: int
```

The id of the procedure call request.

#### `error` property

```gdscript
class SpacetimeDBProcedureCall:
    var error: Error
```

A Godot `Error` that is `OK` if the request was sent, or an error if it failed to send.

#### `outcome` property

```gdscript
class SpacetimeDBProcedureCall:
    var outcome: Outcome
```

The outcome of the procedure call. Initially `PENDING`, updated when the server responds.

#### `error_message` property

```gdscript
class SpacetimeDBProcedureCall:
    var error_message: String
```

A human-readable error message if the procedure call failed.

#### `return_bytes` property

```gdscript
class SpacetimeDBProcedureCall:
    var return_bytes: PackedByteArray
```

The raw BSATN-encoded return value from the procedure. Use `decode()` to get the typed value.

#### `wait_for_response()` method

```gdscript
class SpacetimeDBProcedureCall:
    async func wait_for_response(timeout_sec: float = 10) -> PackedByteArray
```

| Name        | Description                                                       |
| ----------- | ----------------------------------------------------------------- |
| timeout_sec | The number of seconds to wait for the response before timing out. |

Waits for the procedure response, or until it times out. Returns the raw return bytes.

#### `decode()` method

```gdscript
class SpacetimeDBProcedureCall:
    func decode() -> Variant
```

Decodes the raw `return_bytes` using the BSATN type information provided at call time. Returns `null` if the return bytes are empty or no return type was specified.

#### `is_ok()` / `is_error()` / `is_completed()` methods

```gdscript
class SpacetimeDBProcedureCall:
    func is_ok() -> bool          # outcome == RETURNED
    func is_error() -> bool       # outcome is ERROR, INTERNAL_ERROR, or DISCONNECTED
    func is_completed() -> bool   # outcome != PENDING
```

## `LocalDatabase` class

**Inherits:** Node

The underlying local database cache for a module.

### Subscribe to inserts

```gdscript
class LocalDatabase:
    func subscribe_to_inserts(table_name: StringName, callable: Callable) -> void

    func unsubscribe_from_inserts(table_name: StringName, callable: Callable) -> void
```

The `callable` runs whenever a new row is inserted into the table with the given `table_name`.

You can call `unsubscribe_from_inserts` with a `callable` that was previously registered.

### Subscribe to updates

```gdscript
class LocalDatabase:
    func subscribe_to_updates(table_name: StringName, callable: Callable) -> void

    func unsubscribe_from_updates(table_name: StringName, callable: Callable) -> void
```

The `callable` runs whenever an existing row in the table with the given `table_name` receives an update.

You can call `unsubscribe_from_updates` with a `callable` that was previously registered.

### Subscribe to deletes

```gdscript
class LocalDatabase:
    func subscribe_to_deletes(table_name: StringName, callable: Callable) -> void

    func unsubscribe_from_deletes(table_name: StringName, callable: Callable) -> void
```

The `callable` runs whenever an existing row in the table with the given `table_name` is deleted.

You can call `unsubscribe_from_deletes` with a `callable` that was previously registered.

### Subscribe to transactions completed

```gdscript
class LocalDatabase:
    func subscribe_to_transactions_completed(table_name: StringName, callable: Callable) -> void

    func unsubscribe_from_transactions_completed(table_name: StringName, callable: Callable) -> void
```

The `callable` runs after all row changes for a table update batch have been applied to the table with the given `table_name`. Useful for batching UI updates rather than reacting to each individual row change.

### Access untyped data in the local database

#### `get_row_by_pk()` method

```gdscript
class LocalDatabase:
    func get_row_by_pk(table_name: StringName, primary_key_value: Variant) -> _ModuleTableType
```

Returns the row in the table with the given `table_name` that has the given `primary_key_value`.

If a table with the given `table_name` does not exist or no row with the given `primary_key_value` exists, the method returns `null`.

#### `get_all_rows()` method

```gdscript
class LocalDatabase:
    func get_all_rows(table_name: StringName) -> Array[_ModuleTableType]
```

Returns all subscribed rows in the table with the given `table_name`, if the table does not exist an empty array is returned.

#### `count_all_rows()` method

```gdscript
class LocalDatabase:
    func count_all_rows(table_name: StringName) -> int
```

Returns the number of subscribed rows in the table with the given `table_name`.

#### Query helpers

```gdscript
class LocalDatabase:
    func find_where(table_name: StringName, predicate: Callable) -> Array[_ModuleTableType]
    func first_where(table_name: StringName, predicate: Callable) -> _ModuleTableType
    func find_by(table_name: StringName, field: StringName, value: Variant) -> Array[_ModuleTableType]
    func first_by(table_name: StringName, field: StringName, value: Variant) -> _ModuleTableType
    func count_where(table_name: StringName, predicate: Callable) -> int
```

# Rust Enums in Godot

There is full support for rust enum sumtypes when derived from SpacetimeType.

The following is fully supported syntax:

```rs
#[derive(spacetimedb::SpacetimeType, Debug, Clone)]
pub enum CharacterClass {
    Warrior(Vec<i32>),
    Mage(CharacterMageData),
    Archer(ArcherOptions),
}

#[derive(SpacetimeType, Debug, Clone)]
pub struct CharacterMageData {
    mana: u32,
    spell_power: u32,
    other: Vec<u8>,
}

#[derive(SpacetimeType, Debug, Clone)]
pub enum ArcherOptions {
    None,
    Bow(BowOptions),
    Crossbow,
}

#[derive(SpacetimeType, Debug, Clone)]
pub enum BowOptions {
    None,
    Longbow,
    Shortbow,
}
```

This will codegen the following for `CharacterClass`: ![image](https://github.com/user-attachments/assets/cdd5cddd-8a15-4da2-a0bb-ef0a1e446883)

There are static functions to create specific enum variants in godot as well as getters to return the variant as the specific type. The following is how to create and match through and enum:

```gdscript
var cc = SpacetimeDB.MyModule.Types.CharacterClass.create_warrior([1,2,3,4,5])
match cc.value:
	cc.Warrior:
		var warrior: = cc.get_warrior()
		var first: = warrior[0]
		print_debug("Warrior:", first)
```

With this you will have full support for code completion due to strong types being returned. ![image](https://github.com/user-attachments/assets/ddfeab8b-1423-41b0-84ca-52af19c96015)

![image](https://github.com/user-attachments/assets/3bb7cac8-78d4-40b7-90f8-20e19274d94a)

Since BowOptions in rust is not being used as a sumtype in godot it becomes just a standard enum.

![image](https://github.com/user-attachments/assets/0c4b4c00-c479-47cc-a459-394b917457c1)

# Technical Details

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/plaught-armor/Godot-SpacetimeDB-SDK)

## Type System & Serialization

The SDK handles serialization between Godot types and SpacetimeDB's BSATN format based on your schema Resources.

-   **Default Mappings:**

    -   `bool` <-> `bool`
    -   `int` <-> `i64` (Signed 64-bit integer)
    -   `float` <-> `f64` (Double-precision float)
    -   `String` <-> `String` (UTF-8)
    -   `Vector2`/`Vector2i` <-> Matching server struct (f32/i32 fields)
    -   `Vector3`/`Vector3i` <-> Matching server struct (f32/i32 fields)
    -   `Vector4`/`Vector4i` <-> Matching server struct (f32/i32 fields)
    -   `Quaternion` <-> Matching server struct (f32 fields)
    -   `Color` <-> Matching server struct (f32 fields)
    -   `Plane` <-> Matching server struct (f32 fields: normal.x, normal.y, normal.z, d)
    -   `PackedByteArray` <-> `Vec<u8>` (Default) OR `Identity` OR `ConnectionId`
    -   `Array[T]` <-> `Vec<T>` (Requires typed array hint, e.g., `@export var scores: Array[int]`)
    -   `Option` <-> `Option<T>` (Rust Option type)
    -   Nested `Resource` <-> `struct` (Fields serialized inline)

-   **Deep Nesting:** Arbitrary nesting of `Option<T>` and `Vec<T>` is supported: `Option<Option<T>>`, `Vec<Vec<T>>`, `Option<Vec<Option<T>>>`, etc.

-   **Metadata for Specific Types:** Use `set_meta("bsatn_type_fieldname", "type_string")` in your schema's `_init()` for:

    -   Integers other than `i64` (e.g., `"u8"`, `"i16"`, `"u32"`).
    -   Floats that are `f64` (use `"f64"`).

-   **Reducer Type Hints:** The `types` array in `call_reducer` helps serialize arguments correctly, especially important for non-default integer/float types.

### Supported Data Types

-   **Primitives:** `bool`, `int` (maps to `i8`-`i64`, `u8`-`u64` via metadata/hints), `float` (maps to `f32`, `f64` via metadata/hints), `String`
-   **Godot Types:** `Vector2`, `Vector2i`, `Vector3`, `Vector3i`, `Vector4`, `Vector4i`, `Quaternion`, `Color`, `Plane` (require compatible server structs)
-   **Byte Arrays:** `PackedByteArray` (maps to `Vec<u8>`, `Identity`, or `ConnectionId`)
-   **Collections:** `Array[T]` (requires typed `@export` hint), `Vec<T>` with deep nesting
-   **Options:** `Option` class wrapping `Option<T>` with deep nesting
-   **Custom Resources:** Nested `Resource` classes defined in your schema path.
-   **Rust Enums:** Code generator creates a RustEnum class in Godot

## Compression

-   **Client -> Server:** Not currently implemented. Messages sent from the client (like reducer calls) are uncompressed.
-   **Server -> Client:**
    -   **None (0x00):** Fully supported.
    -   **Gzip (0x02):** Supported.
    -   **Brotli (0x01):** Not supported. If `CompressionPreference.BROTLI` is set, the SDK automatically falls back to GZIP and logs a warning.

---

### Other documentation

-   [Installation](installation.md)
-   [Generate module bindings](codegen.md)
-   [Quick Start guide](quickstart.md)
-   [Migration guide (0.2.x to 1.0)](migrations/1.0.md)

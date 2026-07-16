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

#### `get_stats()` method

```gdscript
class SpacetimeDBClient:
    func get_stats() -> SpacetimeDBStats
```

Returns the [`SpacetimeDBStats`](#spacetimedbstats-class) tracking per-request round-trip latency (reducer / procedure / one-off / subscribe). Read-only diagnostics; always-on.

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
    func call_reducer(reducer_name: String, args: Array = [], types: Array = [], ret_bsatn_type: StringName = &"") -> SpacetimeDBReducerCall
```

| Name           | Description                                                       |
| -------------- | ---------------------------------------------------------------- |
| reducer_name   | The name of the reducer to call.                                 |
| args           | The arguments to pass to the reducer.                            |
| types          | The BSATN types of the arguments to pass to the reducer.         |
| ret_bsatn_type | Optional BSATN type for decoding the reducer's ok return value via [`decode()`](#decode-method). Empty for reducers that return nothing. |

Call a reducer with `call_reducer(reducer_name, args, types)` a [`SpacetimeDBReducerCall`](#spacetimedbreducercall-class) instance is returned which contains the request id or an error.

It is recommended you use the auto-generated reducer methods rather than calling `call_reducer` directly. See [Calling reducers](#calling-reducers).

#### `wait_for_reducer_response()` method

```gdscript
class SpacetimeDBClient:
    async func wait_for_reducer_response(request_id_to_match: int, timeout_seconds: float = 10.0) -> TransactionUpdateMessage
```

| Name            | Description                                                       |
| --------------- | ----------------------------------------------------------------- |
| request_id_to_match | The id of the reducer call request to wait for.               |
| timeout_seconds | The number of seconds to wait for the response before timing out. |

Waits for the reducer call response and returns the received `TransactionUpdateMessage`, or returns `null` if there is an error or it times out.

### One-off queries

#### `query_sql()` method

```gdscript
class SpacetimeDBClient:
    async func query_sql(query: String, timeout_seconds: float = 10.0) -> Array[TableUpdateData]
```

| Name            | Description                                                       |
| --------------- | ----------------------------------------------------------------- |
| query           | A single SQL `SELECT` statement to execute.                       |
| timeout_seconds | The number of seconds to wait for the response before timing out. |

Executes a single SQL query without creating a subscription. Returns an array of `TableUpdateData` with the result rows (inserts only), or an empty array on error or timeout.

```gdscript
var results: Array[TableUpdateData] = await SpacetimeDB.MyModule.query_sql("SELECT * FROM player WHERE level > 10")
for table in results:
    print("Table: %s, rows: %d" % [table.table_name, table.inserts.size()])
```

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
    async func wait_for_procedure_response(request_id_to_match: int, timeout_seconds: float = 10.0) -> PackedByteArray
```

| Name            | Description                                                       |
| --------------- | ----------------------------------------------------------------- |
| request_id_to_match | The id of the procedure call request to wait for.             |
| timeout_seconds | The number of seconds to wait for the response before timing out. |

Waits for the procedure call response and returns the raw BSATN-encoded return bytes, or returns an empty `PackedByteArray` if there is an error or it times out.

### Signals

| Signal | Description |
| --- | --- |
| `connected(identity: PackedByteArray, token: String)` | Emitted when the connection is established. |
| `disconnected` | Emitted when the connection is closed. |
| `connection_error(code: int, reason: String)` | Emitted when a connection error occurs. |
| `database_initialized` | Emitted once when the local DB receives its first server data (the first `SubscribeApplied`, or the first transaction update if one arrives first). |
| `row_inserted(table_name: StringName, row: Resource)` | Emitted when a row is inserted. |
| `row_updated(table_name: StringName, old_row: Resource, new_row: Resource)` | Emitted when a row is updated. |
| `row_before_delete(table_name: StringName, row: Resource)` | Emitted just before a row is removed — the row is still queryable in the cache. |
| `row_deleted(table_name: StringName, row: Resource)` | Emitted when a row is deleted. |
| `row_transactions_completed(table_name: StringName)` | Emitted when all row changes for a table update are applied. |
| `transaction_update_received(update: TransactionUpdateMessage)` | Emitted when a transaction update is received. |
| `reducer_result_received(request_id: int, tx_update: TransactionUpdateMessage)` | Emitted when a reducer result arrives. |
| `procedure_result_received(request_id: int, return_bytes: PackedByteArray)` | Emitted when a procedure result arrives. |
| `one_off_query_received(request_id: int, tables: Array[TableUpdateData], error_message: String)` | Emitted when a one-off query result arrives. |
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
    var reducers: ModuleReducers
```

The `reducers` property provides access to reducers exposed by the module. See [Calling reducers](#calling-reducers).

#### `procedures` property

```gdscript
class ModuleClient:
    var procedures: ModuleProcedures
```

The `procedures` property provides access to procedures exposed by the module. See [Calling procedures](#calling-procedures).

#### `subscribe_all_tables()` method

```gdscript
class ModuleClient:
    func subscribe_all_tables() -> SpacetimeDBSubscription
```

Subscribes to every table in the module (`SELECT * FROM <table>` for each) with a
single [`SpacetimeDBSubscription`](#spacetimedbsubscription-class) handle. Returns
a failed handle if called before the client's database is initialized.

### Access the local database

Each table defined by your module has a property, whose name is the table name converted to `snake_case`. The table properties are [`ModuleTable`](#access-the-local-database) instances which have methods for accessing rows and registering `on_insert`, `on_update` and `on_delete` listeners.

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

#### `on_before_delete` listener

```gdscript
class ModuleTable:
    func on_before_delete(listener: Callable) -> void

    func remove_on_before_delete(listener: Callable) -> void

# Listener function signature
func(row: Row) -> void
```

The `on_before_delete` listener runs just before a row is removed from the local
database — the row (and related rows) are still queryable from the cache when it
fires. Use it to read pre-delete state that `on_delete` could no longer see.

Call `remove_on_before_delete` to un-register a previously registered listener.

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

#### Typed per-field finders

For every value-typed scalar field (`int` / `float` / `String` / `bool` /
`StringName` / `PackedByteArray`), the table wrapper also generates a typed
`find_by_<field>(value)` / `first_by_<field>(value)` pair — a compile-checked field
name, value type, and return type, instead of the stringly-typed `find_by(&"field",
value)`. Nested / Resource fields and the `scheduled_at` column are skipped.

```gdscript
class ModuleTable:
    func find_by_<field>(value: Col) -> Array[Row]
    func first_by_<field>(value: Col) -> Row
```

The lookup routes through the field's index when one exists: a **unique** index gives
an O(1) `find()`; a **btree** index gives an O(1)+O(k) `filter()`. Non-indexed fields
fall back to the linear `find_by` scan.

#### Typed change signals

Each table wrapper exposes change signals typed to the concrete `Row` class — a
table-scoped, editor-discoverable parallel to the `on_insert` / `on_update` /
`on_delete` callbacks.

```gdscript
class ModuleTable:
    signal inserted(row: Row)
    signal updated(old_row: Row, new_row: Row)
    signal deleted(row: Row)
```

#### Unique index access

For each unique constraint on a table, its table class has a property whose name is the unique column name. This property is a `ModuleTableUniqueIndex` which has a `find` method.

```gdscript
class ModuleTableUniqueIndex:
    func find(col_val: Col) -> Row | null
```

Where `Col` is the column data type and `Row` is the table row type. If a row with the `col_val` exists in the local database, the method returns that row, otherwise it returns `null`.

#### BTree index access

For each single-column non-unique BTree index on a table, its table class has a
property whose name is the indexed column name. This property is a
`ModuleTableBTreeIndex` with a `filter` method returning all matching rows.

```gdscript
class ModuleTableBTreeIndex:
    func filter(col_val: Col) -> Array[Row]
```

Where `Col` is the column data type and `Row` is the table row type. Columns
already covered by the primary key or a unique constraint expose
[`find`](#unique-index-access) instead. `filter` is a per-value bucket cache
(`Dictionary[value, Array[Row]]`) maintained live by insert/update/delete listeners,
so a lookup is a dictionary get plus the *k* matching rows — not an *N*-row scan.

For an index over an **orderable** column (`int` / `float` / `String`), the wrapper
also generates range and one-sided bound accessors backed by a sorted-key mirror, so
they binary-search the window (O(log d + k) over *d* distinct keys):

```gdscript
class ModuleTableBTreeIndex:
    func filter_range(from_val: Col, to_val: Col) -> Array[Row]  # inclusive [from, to]
    func filter_gte(col_val: Col) -> Array[Row]
    func filter_gt(col_val: Col) -> Array[Row]
    func filter_lte(col_val: Col) -> Array[Row]
    func filter_lt(col_val: Col) -> Array[Row]
```

Non-orderable keys keep exact-match `filter()` only: `PackedByteArray`-backed columns
(`Identity`, `u128` / `u256`) and `bool` — `Array.bsearch` has no ordering to
binary-search on them. The range/bound accessors are generated only for `int` /
`float` / `String` columns.

### Calling reducers

Each public reducer defined by your module has a method on the `.reducers` property. The method name is the reducer name as defined in your module (already `snake_case` in the schema). Each reducer method takes the arguments defined by the reducer and returns a [`SpacetimeDBReducerCall`](#spacetimedbreducercall-class) handle.

```gdscript
func example_reducer(arg1: String, arg2: int) -> SpacetimeDBReducerCall
```

### Calling procedures

Each public procedure defined by your module has a method on the `.procedures` property. The method name is the procedure name as defined in your module (already `snake_case` in the schema). Each procedure method takes the arguments defined by the procedure and returns a [`SpacetimeDBProcedureCall`](#spacetimedbprocedurecall-class) handle.

```gdscript
func example_procedure(arg1: String) -> SpacetimeDBProcedureCall
```

## `SpacetimeDBQuery` class

**Inherits:** RefCounted

A fluent query builder for constructing SQL subscription queries with input validation.

```gdscript
var query: String = SpacetimeDBQuery.table("players").where("online", true).to_sql()
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
    func where(field: String, value: Variant) -> SpacetimeDBQuery
    func where_ne(field: String, value: Variant) -> SpacetimeDBQuery
    func where_gt(field: String, value: Variant) -> SpacetimeDBQuery
    func where_lt(field: String, value: Variant) -> SpacetimeDBQuery
    func where_gte(field: String, value: Variant) -> SpacetimeDBQuery
    func where_lte(field: String, value: Variant) -> SpacetimeDBQuery
    func where_in(field: String, values: Array) -> SpacetimeDBQuery
    func where_any(pairs: Array) -> SpacetimeDBQuery
```

`where_in` adds `field IN (v1, v2, ...)` (empty `values` is a no-op). `where_any`
adds an OR group of equality checks ANDed with the other conditions —
`where_any([["kind", 1], ["kind", 2]])` produces `(kind = 1 OR kind = 2)`.

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

#### Signals

| Signal | Description |
| --- | --- |
| `connected` | Emitted when the websocket opens. |
| `disconnected` | Emitted when the websocket closes. |
| `connection_error(code: int, reason: String)` | Emitted on a connection error. |
| `connection_stalled(code: int)` | Emitted instead of `connection_error` when an abnormal close is classified as caused by a local main-thread stall (poll gap ≥ `heartbeat_interval`) rather than a network drop — the client reconnects immediately with no backoff ramp. |

The connection also emits `message_received`, `total_messages`, and `total_bytes` — internal transport/monitor plumbing; prefer the `SpacetimeDBClient` signals for application code.

#### `CompressionPreference` enum

```gdscript
class SpacetimeDBConnection:
    enum CompressionPreference { NONE = 0, BROTLI = 1, GZIP = 2 }
```

The compression preference for the connection.

| Name   | Description                                                                  |
| ------ | ---------------------------------------------------------------------------- |
| NONE   | No compression.                                                              |
| BROTLI | Brotli compression, decoded via Godot's built-in Brotli decoder.             |
| GZIP   | GZIP compression (recommended).                                              |

## `SpacetimeDBConnectionOptions` resource

**Inherits:** Resource

#### `compression` property

```gdscript
class SpacetimeDBConnectionOptions:
    var compression: CompressionPreference = CompressionPreference.NONE
```

The [`CompressionPreference`](#compressionpreference-enum) for the connection.

#### `light_mode` property

```gdscript
class SpacetimeDBConnectionOptions:
    var light_mode: bool = false
```

When `true`, subscribes in "light" mode — the server sends only the row deltas
needed to keep the cache current, reducing bandwidth.

#### `confirmed_reads` property

```gdscript
class SpacetimeDBConnectionOptions:
    var confirmed_reads: bool = false
```

When `true`, the server waits for each transaction to be durably committed before
sending its update (read-after-commit). Higher latency, stronger durability. The
default `false` matches SpacetimeDB's default.

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

When `true` (the default), the connection requests a fresh anonymous-style token each time instead of reusing a persisted one. Set to `false` (paired with `save_token`) to resume the same identity across runs.

#### `save_token` property

```gdscript
class SpacetimeDBConnectionOptions:
    var save_token: bool = true
```

Whether the connection's auth token is written to disk so the next connect can reload it (resuming the same identity). Typically paired with `one_time_token = false`.

#### `token` property

```gdscript
class SpacetimeDBConnectionOptions:
    var token: String = ""
```

An explicit auth token to use for the connection. `save_token` controls whether it is persisted to disk.

#### `debug_mode` property

```gdscript
class SpacetimeDBConnectionOptions:
    var debug_mode: bool = false
```

Enables verbose logging.

#### `heartbeat_interval_seconds` property

```gdscript
class SpacetimeDBConnectionOptions:
    var heartbeat_interval_seconds: float = 15.0
```

Interval at which the client sends WebSocket pings to keep the socket alive and surface a dead/half-open connection. A main-thread stall longer than this makes Godot's `WebSocketPeer` miss a pong and close the socket — detected and surfaced as [`connection_stalled`](#signals-1). Set to `0.0` to disable keepalive.

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

#### Frame-budget and drain options

```gdscript
class SpacetimeDBConnectionOptions:
    var frame_budget_us: int = 4000
    var max_messages_per_frame: int = 256
    var auto_tune_frame_budget: bool = true
    var frame_budget_min_us: int = 1000
    var frame_budget_max_us: int = 8000
    var auto_tune_target_fps: int = 0          # 0 = use Engine.physics_ticks_per_second
```

| Name | Description |
| --- | --- |
| `frame_budget_us` | Per-frame time budget in microseconds for applying parsed server messages. Higher drains bursts (initial subscription, mass updates) faster at the cost of frame time; lower keeps frames smoother but backlogs longer. When `auto_tune_frame_budget` is enabled this is the seed value. |
| `max_messages_per_frame` | Hard ceiling on messages applied per frame, regardless of the time budget. Safety backstop against unbounded drain. |
| `auto_tune_frame_budget` | When `true`, `frame_budget_us` is auto-tuned at runtime by an fps feedback loop: ramp up while a backlog drains and fps stays healthy, back off when fps dips. |
| `frame_budget_min_us` | Lower clamp for the auto-tuned budget, in microseconds. |
| `frame_budget_max_us` | Upper clamp for the auto-tuned budget, in microseconds. |
| `auto_tune_target_fps` | Target fps the auto-tuner defends. `0` uses `Engine.physics_ticks_per_second`. |

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

#### `ret_value` property

```gdscript
class SpacetimeDBReducerCall:
    var ret_value: PackedByteArray
```

Raw BSATN-encoded return value from the reducer. Populated when the outcome is `OK`. Empty for other outcomes or reducers with no return value.

#### `decode()` method

```gdscript
class SpacetimeDBReducerCall:
    func decode() -> Variant
```

Decodes [`ret_value`](#ret_value-property) into the typed ok return value, using the BSATN type the generated reducer method passed at call time. Returns `null` if the reducer returned nothing (unit) or no return type was provided (e.g. a hand-written `call_reducer` without `ret_bsatn_type`).

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
    async func wait_for_response(timeout_sec: float = 10) -> SpacetimeDBReducerCall
```

| Name        | Description                                                       |
| ----------- | ----------------------------------------------------------------- |
| timeout_sec | The number of seconds to wait for the response before timing out. |

Waits for the reducer call response, or until it times out, then returns this handle (`self`) so the result is available in one step. Inspect [`outcome`](#outcome-property), [`transaction_update`](#transaction_update-property), [`error_message`](#error_message-property-1), and [`decode()`](#decode-method) on the returned handle. On timeout `outcome` is set to `TIMEOUT`.

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
    async func wait_for_response(timeout_sec: float = 10) -> SpacetimeDBProcedureCall
```

| Name        | Description                                                       |
| ----------- | ----------------------------------------------------------------- |
| timeout_sec | The number of seconds to wait for the response before timing out. |

Waits for the procedure response, or until it times out, then returns this handle (`self`). Inspect `outcome`, `return_bytes`, `error_message`, and [`decode()`](#decode-method-1) on the returned handle. On timeout `outcome` is set to `TIMEOUT`.

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

## `SpacetimeDBStats` class

**Inherits:** RefCounted

Per-request round-trip latency tracker, read via [`SpacetimeDBClient.get_stats()`](#get_stats-method). Records the microsecond gap between sending a request and receiving its response, bucketed by category. Main-thread only, always-on (one `Time.get_ticks_usec` plus two dict ops per request), with a bounded pending set so a never-answered request can't leak.

#### `Category` enum

```gdscript
class SpacetimeDBStats:
    enum Category { REDUCER, PROCEDURE, ONE_OFF, SUBSCRIBE }
```

#### Methods

```gdscript
class SpacetimeDBStats:
    func get_tracker(category: Category) -> Tracker   # live stats for one category (read-only)
    func summary() -> String                          # one line per category, latencies in ms
    func reset() -> void                              # clear all counters and pending sends
```

#### `Tracker` (per-category stats)

```gdscript
class Tracker:
    var count: int
    var min_usec: int
    var max_usec: int
    var total_usec: int
    var last_usec: int
    var in_flight: int       # outstanding (unanswered) requests
    func avg_usec() -> int
```

```gdscript
var stats: SpacetimeDBStats = SpacetimeDB.MyModule.get_stats()
print(stats.summary())
var reducer_avg: int = stats.get_tracker(SpacetimeDBStats.Category.REDUCER).avg_usec()
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

### Subscribe to before-deletes

```gdscript
class LocalDatabase:
    func subscribe_to_before_deletes(table_name: StringName, callable: Callable) -> void

    func unsubscribe_from_before_deletes(table_name: StringName, callable: Callable) -> void
```

The `callable` runs just before a row is removed from the table — the row is still queryable in the cache when it fires (see [`on_before_delete`](#on_before_delete-listener)).

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

## `SpacetimeAuth` class

**Inherits:** Node

Exchanges a provider credential for a SpacetimeDB token via the SpacetimeAuth OIDC token endpoint. Thin `HTTPRequest` glue over an exponential-backoff retry loop; provider-agnostic — the `grant_type` and credential fields are caller-supplied. Add it to the tree before calling [`exchange()`](#exchange-method).

#### Exports

```gdscript
class SpacetimeAuth:
    @export var token_url: String = "https://auth.spacetimedb.com/oidc/token"
    @export var debug_mode: bool = false
    @export var request_timeout_seconds: float = 15.0
    @export var max_attempts: int = 4              # transient failures retried up to this many times
    @export var base_retry_delay_seconds: float = 0.5
    @export var max_retry_delay_seconds: float = 4.0
    @export var redact_fields: PackedStringArray   # request fields masked in debug logs
```

#### `exchange()` method

```gdscript
class SpacetimeAuth:
    func exchange(
        grant_type: String,
        extra_fields: Dictionary[String, Variant],
        client_id: String,
    ) -> SpacetimeAuthResult
```

Coroutine — `await` it for the [`SpacetimeAuthResult`](#spacetimeauthresult-class), or connect [`exchange_completed`](#signals-1); the same result is delivered both ways. `extra_fields` carries the provider-specific credential fields. Transient failures (submit error, no response, 5xx) are retried with exponential backoff; a 2xx/4xx is authoritative and returned immediately.

#### Signals

```gdscript
signal exchange_completed(result: SpacetimeAuthResult)
```

```gdscript
var auth: SpacetimeAuth = SpacetimeAuth.new()
add_child(auth)
var result: SpacetimeAuthResult = await auth.exchange(
    "urn:spacetimeauth:steam-ticket",
    {"steam_ticket": ticket_hex, "steam_app_id": app_id},
    "my-client-id",
)
auth.queue_free()
if not result.is_successful():
    push_error("auth failed: %s" % result.error)
    return

# Feed the id_token to the connection as its token, then connect as usual.
var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
options.token = result.id_token
SpacetimeDB.MyModule.connect_db("https://your-host:3000", "my_module", options)
```

## `SpacetimeAuthResult` class

**Inherits:** RefCounted

POD outcome of a [`SpacetimeAuth.exchange()`](#exchange-method) call.

```gdscript
class SpacetimeAuthResult:
    var id_token: String = ""    # the SpacetimeDB token, on success
    var expires_in: int = 0      # token lifetime in seconds, if provided
    var error: String = ""       # non-empty on failure
    func is_successful() -> bool  # true when id_token is set and error is empty
```

## `SpacetimeAuthProtocol` class

**Inherits:** RefCounted

Pure, network-free transforms behind [`SpacetimeAuth`](#spacetimeauth-class) — form-encode, retry decision, backoff math, response classification, credential redaction. Static functions only; unit-testable without a live server or the scene tree.

```gdscript
class SpacetimeAuthProtocol:
    static func build_form_body(client_id: String, grant_type: String, extra_fields: Dictionary[String, Variant]) -> String
    static func is_transient(code: int) -> bool                       # retryable HTTP status?
    static func backoff_delay(attempt: int, base: float, cap: float) -> float
    static func transport_result_name(rc: int) -> String              # HTTPRequest.Result -> label
    static func classify(...) -> SpacetimeAuthResult                  # HTTP response -> result
    static func redact(body: String, fields: PackedStringArray) -> String
```

## `JwtHelper` class

**Inherits:** RefCounted

Unverified client-side JWT payload decode — reads claims (e.g. `login_method`) for local bookkeeping. **Not a security boundary**; the signature is not checked. Trust the token only via the server.

```gdscript
class JwtHelper:
    static func decode_payload(jwt: String) -> Dictionary   # the JWT claims, unverified
    static func login_method(jwt: String) -> String         # the `login_method` claim, or ""
    static func summarize(jwt: String) -> String            # one-line human summary
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
var cc: MyModuleCharacterClass = SpacetimeDB.MyModule.Types.CharacterClass.create_warrior([1, 2, 3, 4, 5])
match cc.value:
	cc.Warrior:
		var warrior: Array[int] = cc.get_warrior()
		var first: int = warrior[0]
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
    -   **Brotli (0x01):** Supported, decoded via Godot's built-in Brotli decoder.

---

### Other documentation

-   [Installation](installation.md)
-   [Generate module bindings](codegen.md)
-   [Quick Start guide](quickstart.md)

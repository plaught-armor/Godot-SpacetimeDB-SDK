# SpacetimeDB SDK Quick Start Guide

## Prerequisites

> Requires **SpacetimeDB 2.2.0+** (v3 BSATN protocol, schema v10) and **Godot 4.6+**. Tested with Godot `4.6-stable`, `4.7-stable` and `4.8.dev`.

-   A SpacetimeDB server running version `2.2.0` or later
-   A Godot 4.6+ project
-   [Install the SpacetimeDB SDK addon](installation.md)
-   [Generate module bindings](codegen.md)

## Configure and Connect to SpacetimeDB

All of your generated modules can be accessed via the `SpacetimeDB` singleton. The following is a basic example of connecting to a SpacetimeDB server and subscribing to data using a module called `MyModule`:

```gdscript
# In your main scene script or another Autoload

func _ready() -> void:
    # Connect to signals BEFORE connecting to the DB
    SpacetimeDB.MyModule.connected.connect(_on_spacetimedb_connected)
    SpacetimeDB.MyModule.disconnected.connect(_on_spacetimedb_disconnected)
    SpacetimeDB.MyModule.connection_error.connect(_on_spacetimedb_connection_error)

    var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()

    options.compression = SpacetimeDBConnection.CompressionPreference.NONE # Default
    # OR
    # options.compression = SpacetimeDBConnection.CompressionPreference.GZIP

    options.one_time_token = true # default; fresh anonymous-like token each connect.
    # To resume the same identity across runs: one_time_token = false + save_token = true
    options.debug_mode = false # Default, set to true for verbose logging
    # Increase buffer size. In general, you don't need this.
    # options.set_all_buffer_size(1024 * 1024 * 2) # Defaults to 2MB

    # Disable threading (e.g., for web builds)
    # options.threading = false

    # Enable auto-reconnection
    # options.auto_reconnect = true

    SpacetimeDB.MyModule.connect_db(
        "http://127.0.0.1:3000", # Base HTTP URL
        "my_module",             # Database name
        options
    )

func _on_spacetimedb_connected(identity: PackedByteArray, token: String) -> void:
    print("Game: Connected to SpacetimeDB!")
    # Good place to subscribe to initial data
    var queries: PackedStringArray = ["SELECT * FROM PlayerData", "SELECT * FROM GameState"]
    var subscription: SpacetimeDBSubscription = SpacetimeDB.MyModule.subscribe(queries)
    if subscription.error != OK:
        printerr("Subscription failed!")
        return

    subscription.applied.connect(_on_subscription_applied)

func _on_subscription_applied() -> void:
    print("Game: Initial subscription applied.")
    # Safe to query the local DB for initially subscribed data
    var initial_players: Array[PlayerData] = SpacetimeDB.MyModule.db.player_data.iter()
    print("Initial players found: %d" % initial_players.size())
    var identity: PackedByteArray = SpacetimeDB.MyModule.get_local_identity()
    var current_player: PlayerData = SpacetimeDB.MyModule.db.player_data.identity.find(identity)
    # ... setup initial game state ...

func _on_spacetimedb_disconnected() -> void:
    print("Game: Disconnected.")

func _on_spacetimedb_connection_error(code: int, reason: String) -> void:
    printerr("Game: Connection Error (Code: %d): %s" % [code, reason])

# listening for the game closing/crashing to disconnect cleanly from the server.
func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_CRASH:
        SpacetimeDB.MyModule.disconnect_db()
```

## Surviving a Disconnect

Set `options.auto_reconnect = true` and the SDK rides out a dropped socket for you: it retries with exponential backoff, restores every subscription the caller still holds, and reports each stage.

```gdscript
func _ready() -> void:
    SpacetimeDB.MyModule.reconnecting.connect(_on_reconnecting)
    SpacetimeDB.MyModule.reconnected.connect(_on_reconnected)
    SpacetimeDB.MyModule.reconnect_failed.connect(_on_reconnect_failed)

    var options: SpacetimeDBConnectionOptions = SpacetimeDBConnectionOptions.new()
    options.auto_reconnect = true
    # The pacing knobs, shown at their defaults.
    options.max_reconnect_attempts = 10      # 0 = keep trying forever
    options.reconnect_initial_delay = 1.0    # seconds before the first retry
    options.reconnect_max_delay = 30.0       # ceiling the backoff climbs to
    options.reconnect_backoff_multiplier = 2.0
    options.reconnect_jitter_fraction = 0.5  # 0.0-1.0, spreads a reconnect storm
    # A backgrounded app's frame loop stalls the backoff timer, so regaining focus
    # fires a waiting attempt immediately. On by default.
    options.reconnect_on_app_resume = true

func _on_reconnecting(attempt: int, max_attempts: int) -> void:
    print("Reconnecting (%d/%d)..." % [attempt, max_attempts])

func _on_reconnected() -> void:
    print("Back online; subscriptions restored.")

func _on_reconnect_failed() -> void:
    printerr("Gave up reconnecting.")
```

**Keep your subscription handles across the drop.** A `SpacetimeDBSubscription` is *suspended* by a disconnect, not ended — the reconnect re-registers that same handle under a fresh query set id, so `applied` fires again and `unsubscribe()` keeps working:

```gdscript
var subscription: SpacetimeDBSubscription

func _on_spacetimedb_connected(identity: PackedByteArray, token: String) -> void:
    subscription = SpacetimeDB.MyModule.subscribe(["SELECT * FROM PlayerData"])
    subscription.end.connect(_on_subscription_ended)

func _leave_the_area() -> void:
    # Works whether the socket is up or the handle is mid-reconnect: offline the
    # request is honoured locally, and the reconnect will not bring the query back.
    subscription.unsubscribe()

func _on_subscription_ended() -> void:
    # Not a drop — that suspends. This is the query really being over.
    print("Subscription ended: %s" % subscription.error_message)
```

`suspended`, `active` and `ended` are mutually exclusive — at most one is true at a time (all three are false for a subscribe the server has not confirmed yet). `subscription.suspended` is true only while a reconnect is in flight and this handle has not been re-registered.

Do **not** call `subscribe()` again in response to `reconnected` — the SDK has already restored the query, and subscribing a second time duplicates the query set on the server. `end` fires only when a subscription really is over: an unsubscribe, a server-side subscription error, a terminal `disconnect_db()` or exhausted reconnect, or a re-subscribe whose send failed.

The mirror is wiped and re-filled across a reconnect, so every row is reported deleted and then inserted again. Row listeners see that as ordinary traffic; code that caches a row object should re-read it rather than hold it.

## Listen for Data Changes

There are three ways to listen for data changes:

### Using the `RowReceiver` node (Recommended for specific tables)

1.  Add a `RowReceiver` node to your scene.
2.  In the Inspector, set `Table To Receive` to your schema resource via the dropdown menu (e.g., `PlayerData`).
3.  Connect to the node's `insert(row)`, `update(previous_row, new_row)` and `delete(row)` signals.

```gdscript
# Script needing player updates
@export var player_receiver: RowReceiver # Assign in editor

func _ready() -> void:
    if player_receiver:
        player_receiver.insert.connect(_on_player_receiver_insert)
        player_receiver.update.connect(_on_player_receiver_update)
        player_receiver.delete.connect(_on_player_receiver_delete)
    else:
        printerr("Player receiver not set!")

func _on_player_receiver_insert(player: PlayerData) -> void:
    # Player inserted
    print("Receiver Insert: Player %s ; Health: %d" % [player.name, player.health])
    # ... spawn player visual ...

func _on_player_receiver_update(previous_row: PlayerData, player: PlayerData) -> void:
    # Player updated
    print("Receiver Update: Player %s ; Health: %d" % [player.name, player.health])
    print("Receiver Previous Value: Player %s ; Health: %d" % [previous_row.name, previous_row.health])
    # ... update player visual ...

func _on_player_receiver_delete(player: PlayerData) -> void:
    # Player deleted
    print("Receiver Delete: Player %s" % player.name)
    # ... despawn player visual ...
```

### Using generated table on_xxx methods (Alternative to `RowReceiver` node)

Add listeners to a table via the `on_insert`, `on_update` and `on_delete` methods.

```gdscript
# Script needing player updates

# Somewhere in your script
SpacetimeDB.MyModule.db.player_data.on_insert(_on_player_receiver_insert)
SpacetimeDB.MyModule.db.player_data.on_update(_on_player_receiver_update)
SpacetimeDB.MyModule.db.player_data.on_delete(_on_player_receiver_delete)

func _on_player_receiver_insert(player: PlayerData) -> void:
    # Player inserted
    print("Receiver Insert: Player %s ; Health: %d" % [player.name, player.health])
    # ... spawn player visual ...

func _on_player_receiver_update(previous_row: PlayerData, player: PlayerData) -> void:
    # Player updated
    print("Receiver Update: Player %s ; Health: %d" % [player.name, player.health])
    print("Receiver Previous Value: Player %s ; Health: %d" % [previous_row.name, previous_row.health])
    # ... update player visual ...

func _on_player_receiver_delete(player: PlayerData) -> void:
    # Player deleted
    print("Receiver Delete: Player %s" % player.name)
    # ... despawn player visual ...
```

### Using Global signals

Connect directly to the module's signals for broader updates across all tables.

```gdscript
# In your main script's _ready() or where signals are connected:
SpacetimeDB.MyModule.row_inserted.connect(_on_global_row_inserted)
SpacetimeDB.MyModule.row_updated.connect(_on_global_row_updated)
SpacetimeDB.MyModule.row_deleted.connect(_on_global_row_deleted)

func _on_global_row_inserted(table_name: StringName, row: Resource) -> void:
    if row is PlayerData: # Check the type of the inserted row
        print("Global Insert: New PlayerData row!")
        _spawn_player(row) # Your function
    elif row is GameState:
        print("Global Insert: GameState updated!")
        # ... update game state UI ...

func _on_global_row_updated(table_name: StringName, old_row: Resource, new_row: Resource) -> void:
    if new_row is PlayerData:
        print("Global Update: PlayerData updated!")
        _update_player(new_row) # Your function

func _on_global_row_deleted(table_name: StringName, row: Resource) -> void:
    if row is PlayerData:
        print("Global Delete: PlayerData deleted!")
        _despawn_player(row)
```

## Call Reducers

Use the generated module bindings to trigger server-side logic.

```gdscript
func move_player(direction: Vector2) -> void:
    if not SpacetimeDB.MyModule.is_connected_db(): return

    # Fire and forget
    SpacetimeDB.MyModule.reducers.move_user(direction, global_position)

    # Or await the result using the SpacetimeDBReducerCall handle
    var call: SpacetimeDBReducerCall = SpacetimeDB.MyModule.reducers.move_user(direction, global_position)
    await call.wait_for_response()  # returns the same handle; inspect `call` below
    if call.is_ok():
        print("Reducer succeeded")
    elif call.is_error():
        printerr("Reducer failed: ", call.error_message)
    elif call.outcome == SpacetimeDBReducerCall.Outcome.TIMEOUT:
        printerr("Reducer timed out")

    # Reducers that return a value decode it through the handle. `null` alone is
    # ambiguous — a unit reducer, no declared return type, and bytes that failed to
    # parse all produce it — so ask which one it was.
    var returned: Variant = call.decode()
    if call.has_decode_error():
        printerr("Return value did not parse: ", call.decode_error_message)
    elif call.has_return_value():
        print("Reducer returned: ", returned)
```

## Query Local Database

Access the cached data synchronously at any time.

```gdscript
func get_player_health(identity: PackedByteArray) -> int:
    if SpacetimeDB.MyModule.db:
        # Get a row via any unique index in a table
        var player: PlayerData = SpacetimeDB.MyModule.db.player_data.identity.find(identity)
        if player:
            return player.health
    return -1 # Indicate not found or error

func get_all_cached_players() -> Array[PlayerData]:
    if SpacetimeDB.MyModule.db:
        return SpacetimeDB.MyModule.db.player_data.iter()
    return []
```

## Next Steps

This guide covers the core path. The SDK also provides:

-   **Subscribe to everything** — `SpacetimeDB.MyModule.subscribe_all_tables()` instead of listing queries.
-   **Fluent SQL builder** — `SpacetimeDBQuery.table("user").where("online", true).to_sql()` for subscription/query strings.
-   **One-off SQL queries** — `SpacetimeDB.MyModule.query_sql(sql)` plus the `one_off_query_received` signal, for ad-hoc reads without a standing subscription.
-   **Procedures** — `SpacetimeDB.MyModule.procedures.<name>(...)` returns a `SpacetimeDBProcedureCall` handle (same await pattern as reducers).
-   **Auto-reconnect signals** — when `options.auto_reconnect = true`, listen to `reconnecting(attempt, max_attempts)`, `reconnected`, and `reconnect_failed`.
-   **Typed per-table signals** — each generated table exposes `inserted` / `updated` / `deleted` signals as a typed alternative to the global `row_inserted` / `row_updated` / `row_deleted`.
-   **Typed finders & indexes** — generated `find_by_<field>(value)` helpers, plus btree index `filter()` / `filter_range()` / `filter_gte()` / `filter_lte()` for range scans.
-   **Namespaced submodules** — a module that registers submodules exposes each namespace as an inner facade: `SpacetimeDB.MyModule.db.lib.lib_data`, `SpacetimeDB.MyModule.reducers.lib.lib_insert(...)`. See [Submodules](submodules.md).
-   **Compression** — `CompressionPreference.BROTLI` is supported alongside `NONE` and `GZIP`.

---

### Continue reading

-   [API Reference](api.md)

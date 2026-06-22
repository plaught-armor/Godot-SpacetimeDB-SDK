# SpacetimeDB SDK Quick Start Guide

## Prerequisites

> Requires **SpacetimeDB 2.2.0+** (v3 BSATN protocol, schema v10). Tested with `Godot 4.4.1-stable` to `Godot 4.7-stable`.

-   A SpacetimeDB server running version `2.2.0` or later
-   A Godot 4.4.1+ project
-   [Install the SpacetimeDB SDK addon](installation.md)
-   [Generate module bindings](codegen.md)

## Configure and Connect to SpacetimeDB

All of your generated modules can be accessed via the `SpacetimeDB` singleton. The following is a basic example of connecting to a SpacetimeDB server and subscribing to data using a module called `MyModule`:

```gdscript
# In your main scene script or another Autoload

func _ready():
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

func _on_spacetimedb_connected(identity: PackedByteArray, token: String):
    print("Game: Connected to SpacetimeDB!")
    # Good place to subscribe to initial data
    var queries: PackedStringArray = ["SELECT * FROM PlayerData", "SELECT * FROM GameState"]
    var subscription: SpacetimeDBSubscription = SpacetimeDB.MyModule.subscribe(queries)
    if subscription.error:
        printerr("Subscription failed!")
        return

    subscription.applied.connect(_on_subscription_applied)

func _on_subscription_applied():
    print("Game: Initial subscription applied.")
    # Safe to query the local DB for initially subscribed data
    var initial_players: Array[PlayerData] = SpacetimeDB.MyModule.db.player_data.iter()
    print("Initial players found: %d" % initial_players.size())
    var identity: PackedByteArray = SpacetimeDB.MyModule.get_local_identity()
    var current_player: PlayerData = SpacetimeDB.MyModule.db.player_data.identity.find(identity)
    # ... setup initial game state ...

func _on_spacetimedb_disconnected():
    print("Game: Disconnected.")

func _on_spacetimedb_connection_error(code: int, reason: String):
    printerr("Game: Connection Error (Code: %d): %s" % [code, reason])

# listening for the game closing/crashing to disconnect cleanly from the server.
func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_CRASH:
        SpacetimeDB.MyModule.disconnect_db()
```

## Listen for Data Changes

There are three ways to listen for data changes:

### Using the `RowReceiver` node (Recommended for specific tables)

1.  Add a `RowReceiver` node to your scene.
2.  In the Inspector, set `Table To Receive` to your schema resource via the dropdown menu (e.g., `PlayerData`).
3.  Connect to the node's `insert(row)`, `update(previous_row, new_row)` and `delete(row)` signals.

```gdscript
# Script needing player updates
@export var player_receiver: RowReceiver # Assign in editor

func _ready():
    if player_receiver:
        player_receiver.insert.connect(_on_player_receiver_insert)
        player_receiver.update.connect(_on_player_receiver_update)
        player_receiver.delete.connect(_on_player_receiver_delete)
    else:
        printerr("Player receiver not set!")

func _on_player_receiver_insert(player: PlayerData):
    # Player inserted
    print("Receiver Insert: Player %s ; Health: %d" % [player.name, player.health])
    # ... spawn player visual ...

func _on_player_receiver_update(previous_row: PlayerData, player: PlayerData):
    # Player updated
    print("Receiver Update: Player %s ; Health: %d" % [player.name, player.health])
    print("Receiver Previous Value: Player %s ; Health: %d" % [previous_row.name, previous_row.health])
    # ... update player visual ...

func _on_player_receiver_delete(player: PlayerData):
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

func _on_player_receiver_insert(player: PlayerData):
    # Player inserted
    print("Receiver Insert: Player %s ; Health: %d" % [player.name, player.health])
    # ... spawn player visual ...

func _on_player_receiver_update(previous_row: PlayerData, player: PlayerData):
    # Player updated
    print("Receiver Update: Player %s ; Health: %d" % [player.name, player.health])
    print("Receiver Previous Value: Player %s ; Health: %d" % [previous_row.name, previous_row.health])
    # ... update player visual ...

func _on_player_receiver_delete(player: PlayerData):
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

func _on_global_row_inserted(table_name: StringName, row: Resource):
    if row is PlayerData: # Check the type of the inserted row
        print("Global Insert: New PlayerData row!")
        _spawn_player(row) # Your function
    elif row is GameState:
        print("Global Insert: GameState updated!")
        # ... update game state UI ...

func _on_global_row_updated(table_name: StringName, old_row: Resource, new_row: Resource):
    if new_row is PlayerData:
        print("Global Update: PlayerData updated!")
        _update_player(new_row) # Your function

func _on_global_row_deleted(table_name: StringName, row: Resource):
    if row is PlayerData:
        print("Global Delete: PlayerData deleted!")
        _despawn_player(row)
```

## Call Reducers

Use the generated module bindings to trigger server-side logic.

```gdscript
func move_player(direction: Vector2):
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
-   **Compression** — `CompressionPreference.BROTLI` is supported alongside `NONE` and `GZIP`.

---

### Continue reading

-   [API Reference](api.md)

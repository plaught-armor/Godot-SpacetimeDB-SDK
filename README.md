<p align="center">
  <img src="https://github.com/user-attachments/assets/41dd6587-9f3c-45cd-b6b4-e144dc4338ac" alt="godot-spacetimedb_128" width="128">
</p>

## SpacetimeDB Godot SDK

> Requires **SpacetimeDB 2.0.0+** (v2 BSATN protocol). Tested with `Godot 4.4.1-stable` to `Godot 4.6.beta3`.

A GDScript SDK for integrating Godot Engine with [SpacetimeDB](https://spacetimedb.com), enabling real-time data synchronization and server interaction directly from your Godot client. Built on the v2 BSATN binary protocol with full codegen support.

## Documentation

-   [How to install the SpacetimeDB SDK addon](docs/installation.md)
-   [Quick Start guide](docs/quickstart.md)
-   [API Reference](docs/api.md)
-   [Migration guide (0.2.x to 1.0)](docs/migrations/1.0.md)
-   [Migration guide (0.1.x to 0.2.0)](docs/migrations/0.2.0.md)

## Features

### Subscriptions

-   **Subscribe / Unsubscribe:** `subscribe()` returns a `SpacetimeDBSubscription` handle with `applied` and `end` signals. `unsubscribe()` sends the request; the `end` signal fires when the server confirms via `UnsubscribeAppliedMessage`.
-   **Subscription Error Handling:** Server-side subscription errors (`SubscriptionErrorMessage`) are propagated to the subscription handle — `error_message` is set, `end` signal fires, and `wait_for_applied()` resolves immediately with `ERR_DOES_NOT_EXIST` instead of timing out.
-   **Await Helpers:** `wait_for_applied()` and `wait_for_end()` with configurable timeouts. Both resolve immediately if the subscription is already in the target state or if an error/end occurs during the wait.

### Reducers & Procedures

-   **Structured Reducer Error Handling:** `SpacetimeDBReducerCall` with typed `Outcome` enum (OK, OK_EMPTY, ERROR, INTERNAL_ERROR, TIMEOUT, DISCONNECTED). Generated reducers return the handle directly for inspection.
-   **Procedures:** Full support for SpacetimeDB 2.0 procedures. `SpacetimeDBProcedureCall` with `decode()` for typed return values. Generated wrappers via codegen.

### Data & Queries

-   **PK-less Table Storage:** Tables without a primary key are stored in the local DB with hash-based batch delete. `get_all_rows()`, `count_all_rows()`, and RowReceiver work on PK-less tables.
-   **Query Builder:** `SpacetimeDBQuery.table("user").where("online", true).to_sql()` — fluent API with SQL identifier validation and auto-escaping for strings, booleans, and identities.
-   **Local DB Query Helpers:** `find_where()`, `first_where()`, `find_by()`, `first_by()`, `count_where()` on table wrappers with typed returns and short-circuit evaluation.

### Connection & Reliability

-   **Auto-Reconnection:** Exponential backoff with jitter, configurable via `SpacetimeDBConnectionOptions`. Signals: `reconnecting`, `reconnected`, `reconnect_failed`. Subscription queries are automatically restored on reconnect. Existing subscription/reducer/procedure handles are properly invalidated on disconnect.
-   **Compression:** GZIP and None supported. Brotli is not implemented — if requested, the SDK warns and falls back to GZIP automatically.

### Serialization

-   **Deep Nesting:** Arbitrary nesting of `Option<T>` and `Vec<T>` types: `Option<Option<T>>`, `Vec<Vec<T>>`, `Option<Vec<Option<T>>>`, etc. Recursive BSATN prefix-based serialization/deserialization.
-   **Native GDScript Types:** Vector2, Vector2i, Vector3, Vector3i, Vector4, Vector4i, Quaternion, Color, and Plane are serialized as native GDScript types via codegen. Rust enums map to `RustEnum` with generated constants.

## Contributing

Code of Conduct: Adhere to the Godot [Code of Conduct](https://godotengine.org/code-of-conduct/) and [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html). As a contributor, it is important to respect and follow these to maintain positive collaboration and clean code.

## License

This project is licensed under the MIT License.

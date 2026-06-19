<p align="center">
  <img src="https://github.com/user-attachments/assets/41dd6587-9f3c-45cd-b6b4-e144dc4338ac" alt="godot-spacetimedb_128" width="128">
</p>

## SpacetimeDB Godot SDK

> Requires **SpacetimeDB 2.2.0+** (v3 BSATN protocol, schema v10). Tested with `SpacetimeDB 2.2.0` to `2.6.0`, and `Godot 4.4.1-stable` to `Godot 4.7-stable`. The legacy v2 sub-protocol was dropped in 2.0; for servers below 2.2.0 use an SDK `1.x` release.

A GDScript SDK for integrating Godot Engine with [SpacetimeDB](https://spacetimedb.com), enabling real-time data synchronization and server interaction directly from your Godot client. Built on the BSATN binary protocol (v3 with batched framing, requires server 2.2.0+) with full codegen support.

## Documentation

-   [How to install the SpacetimeDB SDK addon](docs/installation.md)
-   [Quick Start guide](docs/quickstart.md)
-   [Codegen guide](docs/codegen.md)
-   [API Reference](docs/api.md)
-   [Changelog](CHANGELOG.md)

## Features

### Subscriptions

-   **Subscribe / Unsubscribe:** `subscribe()` returns a `SpacetimeDBSubscription` handle with `applied` and `end` signals. `unsubscribe()` sends the request; the `end` signal fires when the server confirms via `UnsubscribeAppliedMessage`.
-   **Subscribe to all tables:** generated module clients expose `subscribe_all_tables()`, which subscribes to every table in the module with a single handle.
-   **Subscription Error Handling:** Server-side subscription errors (`SubscriptionErrorMessage`) are propagated to the subscription handle — `error_message` is set, `end` signal fires, and `wait_for_applied()` resolves immediately with `ERR_DOES_NOT_EXIST` instead of timing out.
-   **Await Helpers:** `wait_for_applied()` and `wait_for_end()` with configurable timeouts. Both resolve immediately if the subscription is already in the target state or if an error/end occurs during the wait.

### Reducers & Procedures

-   **Structured Reducer Error Handling:** `SpacetimeDBReducerCall` with typed `Outcome` enum (OK, OK_EMPTY, ERROR, INTERNAL_ERROR, TIMEOUT, DISCONNECTED). Generated reducers return the handle directly for inspection.
-   **Reducer Return Values:** Reducers that return values expose the raw BSATN bytes via `SpacetimeDBReducerCall.ret_value`, or the typed value via `SpacetimeDBReducerCall.decode()` (generated reducer methods pass the ok-return type automatically).
-   **Procedures:** Full support for SpacetimeDB 2.0 procedures. `SpacetimeDBProcedureCall` with `decode()` for typed return values. Generated wrappers via codegen.

### Data & Queries

-   **One-Off Queries:** `query_sql()` executes a single SQL query without creating a subscription. Returns result rows directly or use the `one_off_query_received` signal.
-   **PK-less Table Storage:** Tables without a primary key are stored in the local DB with hash-based batch delete. `get_all_rows()`, `count_all_rows()`, and RowReceiver work on PK-less tables.
-   **Query Builder:** `SpacetimeDBQuery.table("user").where("online", true).to_sql()` — fluent API with SQL identifier validation and auto-escaping for strings, booleans, and identities. Also `where_in(field, values)` for `IN (...)` and `where_any([[f, v], ...])` for OR groups.
-   **Local DB Query Helpers:** `find_where()`, `first_where()`, `find_by()`, `first_by()`, `count_where()` on table wrappers with typed returns and short-circuit evaluation.
-   **Typed per-field finders:** each table wrapper also generates `find_by_<field>(value)` / `first_by_<field>(value)` for every scalar field — a compile-checked field name and value type and a typed return, instead of the stringly-typed `find_by(&"field", value)`. A finder for a field backed by a **unique index** routes through that index's O(1) cache; other fields use the linear scan.
-   **Indexed lookups:** unique indexes expose a typed `find(value)` (single row); non-unique btree indexes expose a typed `filter(value)` (all matching rows), generated as named accessors on the table wrapper.
-   **Row callbacks:** `on_insert`, `on_update`, `on_delete`, and `on_before_delete` (fires while the row is still in the cache, before removal), plus the matching `row_inserted` / `row_updated` / `row_before_delete` / `row_deleted` signals on the client.
-   **Typed table signals:** each table wrapper also exposes `inserted(row)` / `updated(old_row, new_row)` / `deleted(row)` signals typed to the concrete row class — a table-scoped, editor-discoverable parallel to the `on_*` callbacks.

### Connection & Reliability

-   **Auto-Reconnection:** Exponential backoff with jitter, configurable via `SpacetimeDBConnectionOptions`. Signals: `reconnecting`, `reconnected`, `reconnect_failed`. Subscription queries are automatically restored on reconnect. Existing subscription/reducer/procedure handles are properly invalidated on disconnect.
-   **Compression:** None, GZIP, and Brotli supported (Brotli decoded via Godot's built-in decoder). Set via `SpacetimeDBConnectionOptions.compression`.
-   **Light mode & confirmed reads:** `SpacetimeDBConnectionOptions.light_mode` requests minimal subscription updates; `confirmed_reads` waits for durable commit before the server sends an update.
-   **Frame-Budgeted Apply:** Incoming row updates are applied under an adaptive per-frame time budget (fps-aware auto-tune, with a hard message ceiling), so large bursts — initial subscriptions, mass updates — drain across frames instead of stalling one. Tunable via `SpacetimeDBConnectionOptions` (`frame_budget_us`, `max_messages_per_frame`, `auto_tune_frame_budget`). BSATN parsing runs on a background thread by default (`threading`).

### Serialization

-   **Deep Nesting:** Arbitrary nesting of `Option<T>` and `Vec<T>` types: `Option<Option<T>>`, `Vec<Vec<T>>`, `Option<Vec<Option<T>>>`, etc. Recursive BSATN prefix-based serialization/deserialization.
-   **Native GDScript Types:** Vector2, Vector2i, Vector3, Vector3i, Vector4, Vector4i, Quaternion, Color, and Plane are serialized as native GDScript types via codegen. Rust enums map to `RustEnum` with generated constants.
-   **Tagged-sum (enum-with-payload) columns:** Rust enums with per-variant data round-trip as `RustEnum` values (`value` = tag, `data` = payload), read and write. Anonymous inline `Result<T, E>` columns are supported too — codegen synthesizes a named `RustEnum` type per distinct `Result<T, E>`. Verified end-to-end against a live server (see [`integration-tests/`](integration-tests/)).
-   **Extended scalar types:** `i128` / `u256` / `i256` (raw `PackedByteArray`), `Uuid` (reuses the `u128` wire path), and `ScheduleAt` (the `Interval | Time` tagged union on `#[scheduled]` tables, exposed as a `ScheduleAt` resource). Verified byte-exact end-to-end against a live SpacetimeDB 2.6.0 server (see [`integration-tests/`](integration-tests/)).

## Known Limitations & Caveats

-   **`TimeDuration` and `Timestamp` surface as `int` microseconds — by design.** Both are an `i64` micro count on the wire, and both come through as a plain `int` (a `Timestamp` is micros since the unix epoch, a `TimeDuration` is an elapsed span). Wrapping either in a distinct `Resource` would allocate one object per value — per row, per reducer result — to encode a distinction that is a *transform* concern (how you format or compare the number), not a *data-shape* one (the bytes are already correct). That is a net-negative trade: heap churn on the hot path for zero wire benefit. Convert at the call site if you want a typed view; the SDK keeps the data POD. (The one place the variant actually matters on the wire — a `#[scheduled]` table's `Interval` vs `Time` — *is* modeled, by `ScheduleAt`, because there the tag is real data, not a label.)
-   **WebSocket keepalive default is 15s:** a main-thread stall longer than the configured `heartbeat_interval_seconds` makes Godot's `WebSocketPeer` miss a pong and close the socket (the close happens in the engine; the SDK cannot prevent it). The SDK *detects* this — a poll-gap at or beyond the heartbeat window arms a guard, and an abnormal close inside that window is classified as stall-induced and emitted as `connection_stalled` instead of `connection_error`, so it reconnects immediately with no backoff ramp rather than treating it as a network drop. Tune the interval, or set it to `0` to disable keepalive entirely, via `SpacetimeDBConnectionOptions`.
-   **Deferred schema-v10 details:** the schema parser does not surface column `default_values` or module namespaces — neither has a functional consumer yet (`default_values` is verified harmless: `auto_inc` tables deserialize fine; namespaces are unused). Implemented when a module needs them. (Canonical/case naming via `ExplicitNames` and fallible-reducer return values + error messages *are* handled.)

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the local workflow — running the test suite (`godot-client/run_tests.sh`), enabling the pre-push gate, and regenerating codegen golden files.

Code of Conduct: Adhere to the Godot [Code of Conduct](https://godotengine.org/code-of-conduct/) and [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html). As a contributor, it is important to respect and follow these to maintain positive collaboration and clean code.

## License

MIT. This is a hard fork of the original [SpacetimeDB Godot SDK by flametime](https://github.com/flametime/Godot-SpacetimeDB-SDK), maintained independently; the original copyright is retained in [`LICENSE`](LICENSE).

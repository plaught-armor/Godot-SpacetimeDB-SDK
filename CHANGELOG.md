# Changelog

All notable changes to the SpacetimeDB Godot SDK will be documented in this file.

## [1.6.0] - 2026-06-17

Client-cache and reconnect correctness pass, broader BSATN type coverage, WebSocket
keepalive, and tagged-sum (enum-with-payload / `Result`) column support. The new
serialization types and behaviors are verified end-to-end against a live SpacetimeDB
2.6.0 server — see [`integration-tests/`](integration-tests/).

### Added
- **WebSocket keepalive.** `SpacetimeDBConnectionOptions.heartbeat_interval_seconds`
  (default `15.0`) sends WS pings and surfaces a dead/half-open socket as a close
  (triggering auto-reconnect) within ~2 intervals, instead of waiting out the OS TCP
  timeout. `0.0` disables.
- **Wide BSATN integers** `i128`, `u256`, `i256` (raw `PackedByteArray`, little-endian),
  and **`Uuid`** columns (wire-identical to `u128`).
- **`ScheduleAt`.** New `ScheduleAt` resource (`Interval | Time` + microseconds) with
  full serialize/deserialize; codegen maps `#[scheduled]`-table `scheduled_at` columns
  to it (previously a lossy `i64` that discarded the variant tag).
- **Tagged-sum (enum-with-payload) columns.** Rust enums with per-variant data
  round-trip as `RustEnum` values (`value` = tag, `data` = payload), read and write.
- **Anonymous inline `Result<T, E>` columns.** Codegen synthesizes a named `RustEnum`
  type per distinct `Result<T, E>`.

### Fixed
- **Overlapping-subscription cache correctness.** Rows are now refcounted: a row shared
  by multiple subscriptions fires `on_insert` once (0→1) and `on_delete` only when the
  last holder drops it (1→0). Previously a shared row produced spurious updates/deletes.
  Covers both primary-key tables (keyed by PK) and PK-less tables (keyed by row value,
  multiplicity-counted).
- **Unsubscribe now prunes the cache.** `unsubscribe()` requests dropped rows
  (`SendDroppedRows`) and removes only rows no longer held by another subscription;
  previously a query's rows lingered indefinitely.
- **Event tables.** Event-table rows fire `on_insert` but are no longer stored in the
  cache (`count()` / `iter()` stay empty).
- **`ConnectionId` byte order.** Deserialization now reverses to canonical order,
  matching `Identity` and the serializer (was asymmetric → round-trip mismatch).
- **Fallible-reducer error messages.** The `err` payload (a BSATN length-prefixed
  string for `Result<_, String>`) is now decoded; previously it came through empty.
- **`SubscriptionError` on an applied subscription is now pruned precisely.** The SDK
  tracks per-query row membership, so on an error it drops exactly that query's rows
  (decrementing refcounts; rows still held by another subscription survive) — no
  disconnect or full rebuild, and it works regardless of `auto_reconnect`. Previously
  it reset the connection (reconnect on) or left stale rows (reconnect off).
- **Reducer/procedure `wait_for_response()` returns the handle.** `await
  reducers.foo(args).wait_for_response()` now yields the `SpacetimeDBReducerCall` /
  `SpacetimeDBProcedureCall` itself, so the unambiguous `outcome` (OK / OK_EMPTY / ERROR /
  INTERNAL_ERROR / TIMEOUT / DISCONNECTED), `decode()`, and result are available in one
  step — instead of a bare `TransactionUpdateMessage`/bytes that was `null`/empty on
  timeout, okEmpty, error, and disconnect alike.
- **Removed a per-call array allocation** from the `find_where` / `first_where` /
  `find_by` / `first_by` / `count_where` cache-query helpers (they iterated
  `Dictionary.values()`); they now iterate keys directly, and the `first_*` variants no
  longer allocate the whole table to return a single row.
- **Disconnect no longer blocks pending waits.** `query_sql()` and the
  `wait_for_reducer_response()` / `wait_for_procedure_response()` helpers return
  empty/`null` immediately on disconnect rather than waiting out their timeout.
- **One-off query cache** is cleared on reconnect (a post-reconnect request id could
  otherwise read a stale cached result).
- **Spurious "Bytes remaining" warnings removed.** Under v3 WebSocket message batching
  a single packet carries several concatenated messages; after parsing each one the
  parser saw the next as "trailing bytes" and logged a warning per message (hundreds of
  thousands under load). The framing loop already consumes batched frames correctly, so
  the warning was always bogus.

### Performance
- **Apply hot path.** `LocalDatabase` insert/update/delete now applies primary-key
  tables in a single pass (was a delta dictionary plus a second pass), skips
  update-detection for pure insert/delete batches, and keys per-query subscription
  membership by row hash. Behavior-unchanged; lower per-row cost under load.
- **Deserializer.** Dropped redundant per-read endian sets and hoisted the per-row
  deserialization-plan lookup out of the row loop. (Profiling confirms parse is ~85% of
  the inbound pipeline; the remaining cost is intrinsic to per-row `Resource`
  construction — see `godot-client/benchmark/`.)

### Docs
- README **Known Limitations & Caveats** section; documented the new types and behaviors.
- **`integration-tests/`** — live-server verification modules + headless harnesses
  (wide ints / `Uuid` / `ScheduleAt`, the cache trio, enum-with-payload and `Result`
  columns), with run instructions.
- **`godot-client/benchmark/`** — in-process apply micro-bench, real-workload replay
  from a captured Blackholio packet stream, and a parse-vs-apply deserializer profiler.

## [1.5.0] - 2026-06-17

Client feature-parity pass against the official C# and TypeScript SDKs, plus a
fix to make the Blackholio example actually build and run.

### Added
- **BTree index accessors.** Each single-column non-unique btree index gets a
  typed `filter(value) -> Array[Row]` accessor on its table wrapper (columns
  already covered by the primary key or a unique constraint keep `find()`).
- **`subscribe_all_tables()`** on generated module clients — subscribes to every
  table in the module with a single handle.
- **Brotli decompression** via Godot's built-in decoder. `CompressionPreference.BROTLI`
  now works instead of falling back to GZIP.
- **Light mode & confirmed reads.** `SpacetimeDBConnectionOptions.light_mode` and
  `confirmed_reads` (the latter was previously hardcoded `false`).
- **`on_before_delete` row callback** + `row_before_delete` signal — fires while
  the row is still queryable in the cache, before removal.
- **Query builder** `where_in(field, values)` (`IN (...)`) and
  `where_any(pairs)` (OR group).
- **Typed reducer return values.** `SpacetimeDBReducerCall.decode()` returns the
  typed ok value; codegen threads each reducer's `ok_return_type` automatically.

### Fixed
- **Blackholio example server** depended on `spacetimedb = { git = master }`,
  which drifts and breaks against a released server. Pinned to the released crate
  and resynced the client bindings (adds the `consume_entity_event` event table).
- Removed dead v1-vestigial `ReducerCallInfoData` / `UpdateStatusData` classes
  (the v2 wire `TransactionUpdate` carries only `query_sets`).

### Docs
- Documented all the above; corrected a version contradiction (tested floor is
  2.1.0, matching the schema-v10 requirement) and stale "Brotli not supported"
  notes. Committed missing `.uid` sidecars for the bench scripts.

## [1.4.0] - 2026-06-16

Rolls up everything since `1.3.1` (which was never tagged; feature work landed
after it, so this is published as a minor release).

### Added
- v3 WebSocket protocol negotiation and parsing of view primary keys.
- Headless codegen CLI entry point (generate bindings without opening the editor).
- UI logging toggle; schema generation flow refactored.

### Fixed
- **Serializer crash on first serialize of a struct.** `_serialize_resource_fields`
  read its plan with `_serialization_plan_cache.get(script)` (no default), which
  returns `null` on a cache miss; assigning that to the typed `Array` raised a
  runtime error the first time any struct/Resource reducer argument was serialized.
  Now mirrors the deserializer's `.get(script, [])` + `has()` guard.
- Robust message framing and a reconnect race in the deserializer/client.
- Subscription state machine: `ENDED` is now terminal — a late/out-of-order
  `applied` can no longer resurrect a subscription to `ACTIVE`.
- Drain limits from connection options are clamped (message ceiling, time-budget
  floor) so a misconfigured budget can't starve the apply loop.
- Critical, high, and medium defects from a wire/async audit pass.

### Performance
- **Adaptive per-frame message drain** — fixed 5-messages/frame replaced by an
  fps-aware AIMD time-budget controller plus a hard ceiling.
- **Cursor-based drain** — a backlog drains via an advancing cursor instead of
  re-slicing/re-queuing the unprocessed tail every frame (O(1)/frame vs
  O(remaining); ~80x less re-queue overhead clearing a large burst).
- **In-place row deserialization** — rows parsed directly from the message buffer
  (seek to per-row offset) instead of slicing each into its own buffer + a scratch
  `StreamPeerBuffer`. Over-read is now a hard error (schema/wire mismatch).
- **Typed (de)serialization plans** — per-field plans use a typed record instead
  of a `Dictionary`, dropping a hash lookup per field per row on both read and
  write paths.
- **Gzip decompression** feeds/drains in 64 KiB chunks instead of 4 KiB
  (~13% on ~1 MiB payloads).

### Tests
- Added coverage (previously absent) for: BSATN row-list deserialization (both
  encodings + over-read), gzip decompress round-trip, serializer round-trip,
  per-frame drain stop rule + cross-frame cursor, drain-budget clamps + AIMD
  controller, and the subscription state machine.

### Internal
- Explicit static typing and a formatting pass across the addon.

## [1.3.1] - Never tagged (rolled into 1.4.0)

These changes were prepared as `1.3.1` but never released under that tag; they
shipped as part of [1.4.0](#140---2026-06-16).

### Changed
- Added type annotations across core files (`local_database.gd`, `schema_parser.gd`, `spacetime.gd`, `row_receiver.gd`, `ui.gd`)
- Encapsulated WebSocket access behind `is_websocket_active()` in `spacetimedb_client.gd`
- Schema parser: extracted `_find_type_index()` helper, removed redundant blank lines
- Removed outdated migration guides (0.2.0, 1.0), kept only 1.3.0

## [1.3.0] - 2026-03-24

### Breaking
- **Requires SpacetimeDB 2.1.0+** — schema v9 support has been completely removed. The codegen now exclusively uses schema v10 (`?version=10`), which is only available in SpacetimeDB 2.1.0 and later. Users on SpacetimeDB 2.0.x must upgrade. See [migration guide](docs/migrations/1.3.md).

### Changed
- Schema parser reads v10 section-based format natively instead of normalizing to v9 shape
- Codegen string templates hoisted to top-level constants for Godot 4.7 compatibility
- Removed PK-less table debug noise (`print_debug` for event/PK-less tables)
- Blackholio example: typed dictionaries, removed dead code, deduplicated circle removal

## [1.2.0] - 2026-03-22

### Added
- One-off queries: `query_sql()` method and `one_off_query_received` signal for executing SQL without subscriptions
- Reducer return values: `SpacetimeDBReducerCall.ret_value` exposes BSATN-encoded return bytes from reducers
- Schema v10 support: codegen fetches the v10 module definition format when available, with section-based structure, `is_event` table flag, explicit name mappings, and separated lifecycle/schedule sections. Falls back to v9 for older servers (2.0.x).

### Changed
- `OneOffQueryMessage` now includes `request_id` field matching the v2 protocol
- Schema fetch now tries `?version=10` first, falls back to `?version=9` automatically

## [1.1.1] - 2026-03-12

### Added
- Blackholio example client (agar.io clone) replacing the previous test example
- GDScript documentation comments to all SDK classes

### Fixed
- Subscribe message serializing `query_id` as `i64` instead of `u32`
- BSATN type warning now appears after fallback instead of before
- Added `SubscribeApplied` debug log

## [1.1.0] - 2026-03-04

### Added
- Codegen enum deduplication: automatically reuses matching project enums instead of generating duplicates
- Query helpers on `ModuleTable`: `find_where()`, `first_where()`, `find_by()`, `first_by()`, `count_where()`
- Return types on `Option` methods

### Changed
- Moved plugin config to addon folder, consolidated hardcoded paths
- Replaced unnecessary `StringName` usage with `String` where not used as dictionary keys
- Reverted typed `Array` returns in `ModuleTable` base class

### Fixed
- Naming typos, extracted cache helper, removed dead signal
- Cleaned up debug prints, stale comments, and duplicated logic
- Removed commented-out code

## [1.0.0] - 2026-03-03

### Added
- **SpacetimeDB 2.0 support** with v2 BSATN binary protocol
- **Procedures**: full support for SpacetimeDB 2.0 procedures with `SpacetimeDBProcedureCall` handle, `wait_for_response()`, and `decode()`
- **Deep nesting**: arbitrary nesting of `Option<T>` and `Vec<T>` types (`Option<Option<T>>`, `Vec<Vec<T>>`, etc.)
- **Subscription lifecycle**: `end` signal fires on unsubscribe confirmation, error propagation via `error_message`, handles invalidated on disconnect/reconnect
- **Subscription error handling**: `wait_for_applied()` resolves immediately with `ERR_DOES_NOT_EXIST` on error instead of timing out
- **Structured reducer errors**: `SpacetimeDBReducerCall` with typed `Outcome` enum
- **Query builder**: `SpacetimeDBQuery` with fluent API, SQL identifier validation, and auto-escaping
- **Auto-reconnection**: exponential backoff with jitter, configurable via `SpacetimeDBConnectionOptions`
- **PK-less table storage**: hash-based batch delete for tables without a primary key
- Migration guide from 0.2.x to 1.0

### Changed
- `SpacetimeDBSubscription` is now `RefCounted` instead of `Node`
- Query builder validates identifiers (alphanumeric and underscores only)

### Removed
- `reducer_call_response` and `reducer_call_timeout` signals (replaced by `SpacetimeDBReducerCall` handle)

## [0.2.5] - 2025

### Fixed
- BSATN Deserializer `Array[Vector2i]` parsing
- Subscription messages now fully update the local DB before firing callbacks
- Plugin UI signal hookup for config changes
- Read-only dictionary fix
- Missing `plugin_config` file

## [0.2.4] - 2025

### Added
- Plugin UI and GDScript-based codegen

## [0.2.3] - 2025

### Added
- Rust sum type enum support for serialization
- Nested struct deserialization
- Array deserialization
- Web compatibility and default web export

### Changed
- Massive refactoring of core serialization

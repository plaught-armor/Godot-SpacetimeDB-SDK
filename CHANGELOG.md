# Changelog

All notable changes to the SpacetimeDB Godot SDK will be documented in this file.

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

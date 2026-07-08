# Integration tests (live server)

The unit tests under `godot-client/tests/` cover BSATN
serialization in isolation. This directory holds an **end-to-end** check that runs
the SDK against a real running SpacetimeDB server, to verify the extended scalar
types (`u128` / `i128` / `u256` / `i256`, `Uuid`, and `ScheduleAt`) survive the full
client → server → client round-trip.

These are **not** run automatically (they need a server + the `spacetime` CLI +
a Rust/wasm toolchain). Run them manually when touching BSATN wire code.

## Contents

- `verify_types_module/` — a minimal SpacetimeDB module declaring one table per
  extended type (`one_u128`, `one_i128`, `one_u256`, `one_i256`, `one_uuid`) plus a
  `#[scheduled]` table (`my_schedule`), with one insert reducer each. Table/reducer
  names deliberately include letter→digit boundaries to exercise the
  `source_name` vs `canonical_name` distinction.
- `verify_live.gd` — a headless Godot harness: connects, subscribes, calls each
  insert reducer with a known value (tests serialize), reads the row back from the
  cache (tests deserialize), and asserts the round-trip is byte-exact.

## Running

```sh
# 1. Start a local server
spacetime start &

# 2. Publish the module (point Cargo.toml's spacetimedb dep at your checkout first)
spacetime publish -p integration-tests/verify_types_module -s http://127.0.0.1:3000 vtypes --yes

# 3. Generate bindings for `vtypes` into godot-client/spacetime_bindings/
#    Set the plugin config module to `vtypes` (addons/SpacetimeDB/plugin_config.tres),
#    then run codegen:
cd godot-client
<godot> --headless --path . --script addons/SpacetimeDB/cli.gd

# 4. Run the harness (copy verify_live.gd into godot-client/ alongside the vtypes bindings)
<godot> --headless --path . --script verify_live.gd
# Expect: ALL PASS (6/6)
```

Restore the example's bindings (`git checkout godot-client/spacetime_bindings
addons/SpacetimeDB/plugin_config.tres`) and remove `verify_live.gd` from the Godot
project afterward — a script referencing the `vtypes` bindings won't parse once
those bindings are gone.

## Behavior suite (`verify_types_module2` + `verify_live2.gd`)

A second module + harness covering behaviors the SDK changed or deferred:

- **G1 refcount** — a row shared by two overlapping subscriptions fires `on_insert` once.
- **G2 unsubscribe prune** — unsubscribing one of two overlapping subs keeps the shared row; the last unsubscribe evicts it and fires `on_delete`.
- **G3 event tables** — event-table rows fire `on_insert` but are never stored (`count()==0`).
- **TimeDuration** — a `TimeDuration` column round-trips as `int` micros.
- **default_values** — an `auto_inc` pk table (whose `default_values` the parser drops) still deserializes.
- **fallible reducer** — a reducer returning `Err` surfaces as `Outcome.ERROR` with the decoded message.

Run identically (publish `verify_types_module2` as `vtypes2`, codegen, run `verify_live2.gd`).

## Reconnect / identity persistence (`verify_live_reconnect.gd`)

Uses the `blackholio` module (the example's committed bindings already cover it —
no codegen needed). With `one_time_token = false` + `save_token = true` the SDK
saves the auth token and reloads it on the next connect, so a client resumes the
**same identity** — the basis for the example's auto-rejoin. The harness connects
twice and asserts the identity matches. Copy it into `godot-client/` and run as
above (publish `blackholio`, then `--script verify_live_reconnect.gd`).

## Last verified

Against SpacetimeDB **2.7.0** (CLI 2.7.0), schema v10:

- Types suite: 6/6 — `u128`/`i128`/`u256`/`i256` (byte-exact), `Uuid` (byte-exact, reuses the `u128` wire path), `ScheduleAt` (Interval + micros).
- Behavior suite: 15/15 — cache trio (G1/G2/G3), TimeDuration, default_values, fallible-reducer error message.

## Enum-with-payload column suite (`verify_enum_column_module` + `verify_live_enum.gd`)

Verifies a **named** tagged-sum (enum-with-payload) column. Module `vsum` declares
`enum Shape { Circle(u32), Square(u32), Nothing }` as a `shape_row.shape` column.
The harness subscribes, calls `add_shape`, and confirms `shape` deserializes to a
`RustEnum` (`value`=tag, `data`=payload). Passing required `RustEnum` to be a
`Resource` (so the generated `@export var shape: VsumShape` field is legal and the
type instantiates for the nested-resource → is-RustEnum read path).

**Last verified (2.7.0):** `shape` → `value=0` (Circle), `data=7`. Write path
(enum reducer args / client inserts) covered by the `test_rust_enum_roundtrip` unit test.

The same module's `res_row.r: Result<i32, String>` covers **anonymous inline
Result<T, E> columns** (`verify_live_result.gd`). The parser synthesizes a named
`VsumResultI32String` RustEnum type per distinct `Result<T, E>` (Options `{ok, err}`,
`ENUM_OPTIONS [i32, string]`), so it rides the same enum path. **Last verified (2.7.0):**
`Ok(42)` → `value=0, data=42`; `Err("bad")` → `value=1, data="bad"`. Parser synthesis
guarded by the `test_result_synthesis` unit test.

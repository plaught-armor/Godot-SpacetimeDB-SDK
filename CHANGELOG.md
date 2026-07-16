# Changelog

All notable changes to the SpacetimeDB Godot SDK will be documented in this file.

## [Unreleased]

### Added
- **Deterministic binding UIDs + reproducible codegen output.** Generated
  bindings now get a stable `.uid` derived from an FNV-1a-64 hash of their
  `res://` path (masked to 63 bits, always positive), written and registered
  at generation time — so a fresh clone or regen keeps the same UIDs and
  scene/`.tres` references don't break. Schema sections that arrive from the
  server in HashMap order (modules, tables, reducers, procedures, and both
  unique and btree indexes) are sorted by a stable name key before emission,
  so the generated files are byte-for-byte reproducible. A boot-time collision
  scan reports any two bindings that hash to the same UID (astronomically
  unlikely, but deterministic if it ever happened).

### Added
- **SpacetimeAuth OIDC token exchange.** A `SpacetimeAuth` node (thin
  `HTTPRequest` glue with an exponential-backoff retry loop) exchanges a
  provider credential for a SpacetimeDB token. Provider-agnostic — the
  `grant_type` and request fields are caller-supplied — with the endpoint,
  `grant_type`, Steam fields, and `id_token`/`expires_in` contract verified
  against the official SpacetimeDB 2.7.0 docs. Ships alongside
  `SpacetimeAuthProtocol` (pure, network-free transforms: form-encode, retry
  decision, backoff math, response classify, credential redaction),
  `SpacetimeAuthResult` (POD outcome), and a `JwtHelper` for unverified
  client-side JWT payload decode (reading claims such as `login_method` for
  local bookkeeping — not a security boundary).

### Fixed
- Keep the BSATN deserializer worker thread on **threaded** Web exports.
  The guard now gates on `OS.has_feature("threads")` instead of
  `OS.has_feature("web")`, so cross-origin-isolated (SharedArrayBuffer /
  COOP-COEP) Web builds keep the background deserializer instead of being
  forced onto the slower main-thread path; genuinely non-threaded builds
  still fall back cleanly.

### Changed
- Verified the SDK end-to-end against **SpacetimeDB 2.7.0**; tested range is now
  `2.2.0`–`2.7.0`. No code change — the v3 WS sub-protocol, schema v10, and the
  BSATN wire format are unchanged from 2.6.0. Live integration suites
  (extended scalars, cache behaviors, reconnect, enum/`Result` columns) all pass.

## [2.3.3] - 2026-06-21

### Added
- MIT `LICENSE` inside `addons/SpacetimeDB/` so the packaged addon ships its own
  license file, as required by the Godot Asset Store. Same MIT terms as the
  repo-root license (flametime + plaught-armor); no license change.

### Changed
- Inbound apply-path performance (no API or runtime-behavior change): skip
  duplicating an empty listener array when applying a row, coalesce per-packet
  statistics signals into one emission per frame, and order incoming-message
  dispatch hottest-case first.

## [2.3.2] - 2026-06-19

### Changed
- Renamed the plugin to **SpacetimeDB Godot SDK** (was "SpacetimeDB Client SDK")
  in `plugin.cfg`, matching the README heading and the asset listing.
- Code-quality cleanup, no API or runtime-behavior change: value-only `match`
  statements converted to `if/elif` (cheaper dispatch in interpreted GDScript),
  emptiness checks moved to `.is_empty()`, and single-argument `range(n)` loops
  replaced with direct `for i in n` (no intermediate array allocation). The
  codegen template emits the same `if/elif` form for the generated
  `parse_enum_name`; generated output is behavior-identical (goldens updated).

### Added
- Brand logo lockup and a 1920×1080 Asset Store thumbnail under `docs/images/`.
  The README now self-hosts a theme-adaptive logo (`<picture>`) instead of an
  external image attachment.

## [2.3.1] - 2026-06-19

### Fixed
- **Index-listener crash on an update for an uncached row.** A delete+insert of
  the same primary key (the server's "update" encoding) for a pk not currently in
  the local cache fired `row_updated` with a null `prev`; the unique/btree index
  cache listeners dereference `prev` and crashed. Such updates now take the insert
  path (null `prev` = no prior row), so listeners never receive a null.
- **Stall detection silently off after a retry-while-connecting.** Reconnecting
  while a previous attempt was still in progress recreated the `WebSocketPeer` but
  re-applied only the buffer sizes, not `heartbeat_interval` — the retried socket
  ran with keepalive disabled. Heartbeat is now re-applied on the recreate.
- **`u64` values ≥ 2^63 could not be serialized.** `write_u64_le` rejected a
  negative i64, but a u64 with the high bit set arrives as a negative i64 — large
  ids / hashes / `u64` columns were un-encodable. The guard is removed (`put_u64`
  writes the correct 8 bytes for the full u64 range).

### Security / robustness
- **Bounded the row-list deserializer against malformed input.** Row counts
  (`num_rows` / `num_offsets`) are capped before the backing `PackedInt64Array`
  resize (an unchecked u32 could force a multi-GiB allocation), and the row-data
  block is validated against the buffer — a `data_len` past the buffer now yields
  NEEDS_MORE (the framer keeps the tail) instead of seeking past EOF and silently
  dropping every subsequent message.
- **Bounded gzip/Brotli decompression.** The gzip decode loop had no output
  ceiling (a decompression bomb never terminated); added a 128 MiB cap (well above
  any real frame) and applied it to the Brotli buffer. The serializer no longer
  emits zero-filled bytes on a fixed-size mismatch, and `_wait_for_response` guards
  `is_instance_valid(self)` after its `await`.

### Changed
- Internal code-quality cleanup, no API or generated-output change: codegen builds
  each file with a `PackedStringArray` accumulator instead of repeated string
  concatenation; the schema parser and the index/listener code gain consistent
  typing and drop inline lambdas. The codegen golden suite confirms byte-identical
  output.

## [2.3.0] - 2026-06-19

### Added
- **Btree range and bound lookups.** A btree (non-unique) index over an
  *orderable* column (`int` / `float` / `String`) now generates `filter_range(from,
  to)` (inclusive `[from, to]`) plus the one-sided `filter_gte` / `filter_gt` /
  `filter_lte` / `filter_lt`, alongside the existing exact-match `filter(value)`.
  All ride a sorted-key mirror maintained at the index's bucket create/empty edges,
  so a range binary-searches the window (O(log d + k) over d distinct keys) instead
  of scanning. Bytes-backed keys (`Identity`, `u128` / `u256`) keep exact-match
  `filter()` only — `Array.bsearch` has no defined ordering for them. Regenerate
  bindings to pick this up.
- **Per-request latency stats.** `SpacetimeDBClient.get_stats()` returns a
  `SpacetimeDBStats` tracking round-trip time bucketed by request category (reducer
  / procedure / one-off / subscribe): count, min / max / avg / last latency, and an
  in-flight gauge. `get_stats().summary()` dumps all four categories; `.get_tracker(
  SpacetimeDBStats.Category.REDUCER)` reads one. Always-on (one
  `Time.get_ticks_usec` plus two dictionary ops per request), main-thread, with a
  bounded pending set so a never-answered request can't leak. No codegen or wire
  change — works with existing bindings.

### Changed
- **The btree (non-unique) index is now a real multimap cache.** Its `filter()`
  was a linear `find_by` scan of the whole table; it now keeps a per-value bucket
  cache (`Dictionary[value, Array[Row]]`) maintained live by insert/update/delete
  listeners, so a `filter()` is a dictionary lookup plus the *k* matching rows
  instead of an *N*-row scan. The per-field finders for a btree-indexed field now
  route through it (`find_by_<field>` → `filter()`, `first_by_<field>` returns the
  bucket's first row directly); previously they used the linear fallback.
  Regenerate bindings to pick this up.

### Documentation
- **`docs/design-decisions.md`** records the June 2026 four-SDK parity audit: what
  this SDK builds, what's blocked by the v2/v3 wire (caller identity, energy,
  out-of-energy, reducer flags — removed from the wire at the v1 → v2 cut, so no
  client SDK can surface them), and what's deliberately out of scope with the
  trigger that would justify reopening each. Linked from both doc indexes.
- **README "Known Limitations & Caveats"** gains the wire-blocked entries above and
  is split by kind: genuine user-facing limitations stay in the README; design
  choices (`Timestamp` / `TimeDuration` as `int` micros; deferred schema-v10
  `default_values` / namespaces) move to `docs/design-decisions.md`.

## [2.2.0] - 2026-06-18

### Changed
- **Unique-indexed finders are now O(1).** The generated `find_by_<field>` /
  `first_by_<field>` for a field backed by a *unique* index now routes through that
  index's `find()` — a constant-time lookup against the live `Dictionary` cache —
  instead of the linear `find_by` scan. For a table of N rows, a lookup by a
  unique-indexed field drops from N comparisons to a single dictionary get.
  `first_by_<field>` returns the row directly; `find_by_<field>` wraps it in a
  0-or-1 array. Non-unique (btree) and non-indexed fields keep the linear path —
  the btree index's `filter()` is itself a linear `find_by`, so routing there would
  add a hop for no gain. Regenerate bindings to pick this up.

## [2.1.0] - 2026-06-18

Codegen developer-experience release. Generated table classes gain typed change
signals and typed per-field finders. Pure additions to the generated text — no
base-class, runtime, or wire change; regenerate bindings to pick them up.

### Added
- **Typed table change signals.** Each generated table wrapper now exposes
  `inserted(row)`, `updated(old_row, new_row)`, and `deleted(row)` signals typed to
  the concrete row class, wired to the base `on_insert` / `on_update` / `on_delete`
  listeners. A table-scoped, editor-discoverable parallel to the existing Callable
  API.
- **Typed per-field finders.** Each table wrapper generates `find_by_<field>(value)`
  and `first_by_<field>(value)` for every scalar field — a compile-checked field name
  and value type and a typed return, replacing the stringly-typed
  `find_by(&"field", value)`. Generated for non-nested, non-arraylike fields only.

### Notes
- The committed Blackholio example bindings (`godot-client/spacetime_bindings/`) are
  regenerated against a live module and demonstrate the new signals and finders;
  the regenerated bindings compile as part of the project.

## [2.0.0] - 2026-06-18

**Breaking.** The legacy WebSocket v2 sub-protocol is dropped; the client now
advertises only v3. This raises the minimum server to **SpacetimeDB 2.2.0** (the
first release that speaks v3). Connecting an SDK 2.0 client to a server below
2.2.0 fails the handshake — stay on an SDK `1.x` release for those servers.

### Changed
- **WebSocket handshake advertises `[v3.bsatn.spacetimedb]` only.** Previously the
  client offered `[v3, v2]` and let pre-2.2.0 servers negotiate v2. v3 reuses the
  v2 message schema (a single frame may carry several concatenated BSATN messages,
  which the receive path already drains), so this is a transport-advertise change
  only — no message-format, deserializer, or codegen change.

### Removed
- The `BSATN_PROTOCOL` (`v2.bsatn.spacetimedb`) constant and the v2 entry in the
  advertised sub-protocol list.

### Migration
- Server on 2.2.0+: no action — the client already preferred v3, so the negotiated
  protocol is unchanged.
- Server below 2.2.0: upgrade the server to 2.2.0+, or pin the SDK to the latest
  `1.x` release.

## [1.9.0] - 2026-06-18

Connection-robustness release. Hardens auto-reconnect against main-thread stalls
and a set of reconnect/resubscribe edge cases. No breaking changes.

### Added
- **Stall-aware reconnect.** A main-thread stall longer than `heartbeat_interval`
  makes Godot's `WebSocketPeer` miss a pong and close the socket (`code -1`) — the
  close is engine-side and unavoidable, but its cause is local, not a network drop.
  The connection now measures the wall-clock gap between polls; a gap at or beyond
  the heartbeat window arms a short guard, and an abnormal close inside it is
  surfaced on a new `connection_stalled` signal instead of `connection_error`. The
  client reconnects immediately (backoff skipped on the first attempt), reusing the
  existing save/restore-subscriptions path, so a stall recovers near-instantly and
  quietly rather than ramping a multi-second backoff.

### Fixed
- **Re-drop mid-resubscribe could lose subscriptions and double-fire `reconnected`.**
  Queries from an interrupted resubscribe cycle sit in `pending_subscriptions` (not
  yet applied), so rebuilding the saved set from `current_subscriptions` alone
  dropped them; and a superseded cycle's late `applied`/`end` still ran. A
  per-cycle epoch now bails stale settle callbacks, and the saved set is rebuilt
  (from both current and pending subscriptions) only when empty.
- **`_resubscribe_saved_queries` mutated the list it was iterating.** The saved
  array is now snapshotted up front and the clear+emit deferred until after the
  loop.
- **`disconnect_db()` on an already-closed socket emitted nothing.** When cancelled
  mid-backoff during a reconnect, `disconnect_from_server()` was a no-op, leaving
  callers waiting on `disconnected` forever and the intentional-disconnect flag
  stuck. It now self-emits `disconnected` and clears the flag when not connected.
- A stall during an in-flight reconnect now keeps the no-backoff fast path.

## [1.8.0] - 2026-06-18

Test-gate and codegen-coverage release. No runtime SDK behavior change — this
release adds the infrastructure to keep the SDK from regressing: a local test
runner, a pre-push gate, and golden-file coverage that locks the exact text
codegen emits.

### Added
- **Local test runner** (`godot-client/run_tests.sh`). Runs every `test_*.gd`
  headless, one Godot process per test (each `extends SceneTree` and exits with
  its failure count, so the runner's exit code is the signal). Takes a single
  test name, honors `GODOT_BIN` and `VERBOSE`, and builds the import cache on
  first run. Exits `0` on all-green, `1` on any failure.
- **Pre-push hook** (`.githooks/pre-push`). Runs the suite and blocks the push
  on failure. Committed but inert until enabled with
  `git config core.hooksPath .githooks`; override a run with `git push --no-verify`.
- **Codegen golden tests** (`test_codegen_golden.gd`). Parses the captured v10
  schema fixtures, runs the generator, and diffs every emitted file against a
  committed golden (49 files across three modules — types, tables, unique
  indexes, scheduled and event tables, wide ints, `Uuid`, `Result` and sum
  types). Catches both changed output and dropped files; regenerate
  intentionally with `STDB_REGEN_GOLDEN=1`. Codegen *behavior* was already
  covered by roundtrip tests; the generated *source text* was not.
- **`CONTRIBUTING.md`** documenting the test, pre-push, and golden-regen workflow.

### Docs
- The `TimeDuration` / `Timestamp` "surfaced as `int` microseconds" caveat is
  reframed as a deliberate data-oriented choice rather than a missing feature:
  both are an `i64` micro count on the wire, and wrapping either in a per-value
  `Resource` would add heap churn on the hot path to encode a distinction that
  is a transform concern, not a data-shape one. `ScheduleAt` still models the
  one case where the variant tag is real wire data.

## [1.7.0] - 2026-06-18

Inbound-parse performance pass. The BSATN deserializer's per-row hot path is
reworked across four orthogonal layers — no public API change, no codegen change,
behavior unchanged, full suite green. On a captured Blackholio replay
(`godot-client/benchmark/profile_deser.gd`):

- **parse-only** 47,496 → 69,618 rows/s (**1.47x**)
- **parse + apply** 40,738 → 55,197 rows/s (**1.36x**)

### Performance
- **Inlined fixed-width reads.** A decomposition of generic per-row parse showed the
  cost is GDScript function-call depth, not read logic (the `read_*_le → _check_read →
  has_error()` chain was ~32% of parse). Each fixed-width reader (`i8`–`i64`, `u8`–`u64`,
  `f32`/`f64`) now does its bounds compare inline and calls the native `get_*` directly;
  the underflow path moves to a shared `_read_underflow_int` helper so the happy path is
  just compare + read. Standalone: parse-only 1.19x, parse+apply 1.17x. Applies to every
  primitive field of every row.
- **if-elif type-code plan executor.** The plan's per-field `step.reader.call(spb)`
  Callable dispatch (~44% of parse) is replaced by a frequency-ordered if-elif on a
  per-field `type_code` resolved once at plan-build; the 10 fixed-width primitives read
  inline (no `Callable.call`, no per-field re-check). A fair dispatch bench
  (`bench_dispatch_mechanism.gd`) confirmed there is no real jump table in interpreted
  GDScript and that `match` is *slower* than the Callable it would replace (~0.83x) —
  if-elif + inline read is the win (1.44x).
- **Nested-resource plan hoist.** `_read_nested_resource` re-resolved the nested type
  every row (a `_schema.get_type()` + `_get_or_build_plan()` + `_normalize()` per row).
  `_PlanStep` now carries a pre-resolved `nested_script` + lazily-built `nested_plan`;
  the row loop runs it directly. ~1.26x on nested-resource rows, ~1.13x on saturated
  bulk ingest. Gated to the exact generic path it replaces — `ScheduleAt`, `Identity`,
  `RustEnum`, and other custom-reader types keep their own paths.
- **Value-only `match` → if-elif.** A GDScript `match` arm costs ~10 bytecode ops
  (typeof + value compare + bool materialize + branch) vs ~2 for an if branch, so it's
  the wrong construct for pure value dispatch. Four hot-path matches (native vector/color
  field dispatch, primitive reader/writer resolution) plus ~23 cold ones across 8 files
  are converted. On a native-vector schema (4 `Vector3` fields/row): READ 1.36x,
  WRITE 1.27x. Computed subjects are hoisted to a typed local once (as `match` did);
  error semantics, arm order, and bodies unchanged.

### Fixed
- **WebSocket URL scheme rewrite.** `base_url.replace("http","ws")` could rewrite a
  stray `"http"` anywhere in the URL (e.g. in a host, path, or query segment), not just
  the scheme; the trailing `.replace("https","wss")` was also dead (the first replace
  already consumed it). The rewrite now matches only the leading scheme via
  `begins_with` (`https://` checked first, as `http` is a prefix), leaving any later
  `http://` substring untouched.

### Internal
- Removed dead `_call_writer_callable` (zero callers, superseded by the pre-bound
  `CONTEXT_WRITERS` plan dispatch).
- New benches + tests for the above: `bench_dispatch_mechanism`, `bench_native_vector`,
  `bench_vec_ctx`, `bench_e2e_receive`, `bench_specialized_parser`, plus
  `test_inline_reader_bounds`, `test_nested_plan_hoist`, and `test_nested_hoist_fuzz`
  (32/32) — the prior nested tests used a null schema, so the hoist branch never engaged
  and would have masked corruption.

### Docs
- Bumped the tested SpacetimeDB range to 2.6.0.

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
- **Requires SpacetimeDB 2.1.0+** — schema v9 support has been completely removed. The codegen now exclusively uses schema v10 (`?version=10`), which is only available in SpacetimeDB 2.1.0 and later. Users on SpacetimeDB 2.0.x must upgrade.

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

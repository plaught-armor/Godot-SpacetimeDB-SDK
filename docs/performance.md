# Performance Notes

How the inbound path spends time, what's already optimized, and the optimizations
deliberately *not* taken yet — each with a measured number and a trigger threshold,
so the call can be revisited from data rather than re-derived.

> **Numbers are machine-relative.** All ns/op figures below were measured on one
> dev machine (a custom Godot 4.8.dev editor build, headless), except the
> [editor vs exported game](#editor-vs-exported-game) comparison. An exported release
> build spends 12–39% less time than an editor on the same benches, so editor numbers
> are conservative for a shipped game. Treat the **ratios and
> shares** as the signal, not the absolute nanoseconds. Re-run the benches in
> `godot-client/tests/bench_*.gd` on the target before acting on any threshold.

## The inbound pipeline

A message goes through three stages from socket to game state:

1. **Poll** — `SpacetimeDBConnection._physics_process` calls `_websocket.poll()`,
   drains available packets, hands each to the client via `message_received`.
2. **Parse** — when `use_threading` (default on; auto-disabled on any build whose
   `OS.has_feature("threads")` is false, which includes non-isolated Web exports but
   *not* cross-origin-isolated ones), a background thread
   (`_thread_loop`) decompresses + BSATN-decodes packets into typed
   `SpacetimeDBServerMessage`s, epoch-guarded against reconnect, flushed to
   `_result_queue`. Heavy decode never touches the main thread.
3. **Apply** — `_process_results_asynchronously` (main thread, `_physics_process`)
   drains `_result_queue` under an AIMD time budget into `LocalDatabase`, firing
   row signals.

### Why the work runs at ~60 Hz (it is NOT a render-fps cap)

Both poll and drain live in `_physics_process`, so they fire at
`Engine.physics_ticks_per_second` — **default 60 Hz → a 16.6 ms per-tick budget**.
This is the *physics tick rate*, not a render-frame-rate cap. Render fps is
independent (uncapped / vsync-bound per project settings).

Consequences:
- The "16.6 ms frame budget" used in every threshold below is `1 / physics_ticks`.
  Raise `Engine.physics_ticks_per_second` → poll/drain run more often, each tick's
  budget shrinks, inbound latency drops. The AIMD drain auto-tunes to whatever the
  tick rate is (`_auto_tune_budget` defaults its target to `physics_ticks_per_second`).
- Physics tick is chosen over `_process` deliberately: a DB-sync SDK wants a
  *fixed, render-independent* poll cadence, so network drain stays steady when
  render fps swings under scene load.
- The AIMD budget means a flood **spreads across ticks** (added latency) rather than
  blowing a single tick (dropped frame).

### Does the tick rate change the analysis? (60 / 120 / 144 / 240 Hz)

`Engine.physics_ticks_per_second` is configurable, so it's natural to ask whether the
benches should sweep it. Mostly **no** — most of the cost is tick-invariant:

- **Per-row apply cost is tick-invariant.** A Variant dict insert is ~110 ns whether
  the tick is 60 or 240 Hz. The tick rate changes *when* the drain runs, not how long
  GDScript ops take. Sweeping the apply / component micro-benches across tick rates
  returns identical ns/row — no point.
- **Throughput is tick-invariant.** Rows arrive at a network-driven rows/**sec**,
  independent of tick rate. Higher ticks = the same rows spread over more ticks = fewer
  rows/tick *and* a proportionally smaller budget/tick. Budget-*per-row* is constant.
  Raising ticks does **not** reduce sustainable rows/sec.
- **Fixed per-tick overhead** is the only thing that scales with tick rate (paid
  `ticks/sec` times), and it's negligible. Measured idle-tick drain proxy
  (`bench_tick_overhead.gd`): **~35 ns/tick** → fixed overhead per second:

  | tick rate | fixed drain overhead | share of one core |
  |---|---|---|
  | 60 Hz | 2.1 µs/sec | 0.00021% |
  | 120 Hz | 4.1 µs/sec | 0.00041% |
  | 144 Hz | 5.0 µs/sec | 0.00050% |
  | 240 Hz | 8.3 µs/sec | 0.00083% |

  Idle ticks early-out (mutex pair + `is_empty`) before any allocation or budget
  compute, so raising the tick rate is effectively free on the SDK-overhead side.

**The two things raising the tick rate actually does:**
1. **Lowers inbound latency** (smaller batches, drained sooner) — the reason to do it.
2. **Shrinks the absolute tick budget** the AIMD drain shares with *your game's own*
   `_physics_process`. At 240 Hz the whole tick is 4.16 ms, so a drain budget + heavy
   game physics contend harder. This is a tuning concern (cap `_frame_budget_us` /
   `_max_msgs_per_frame` lower at high tick rates), not a per-row perf concern.

So: bench apply once (tick-invariant); express headroom as rows/**sec** (below); only
revisit tick rate when tuning the *latency vs game-physics-budget* trade, not throughput.

## Already shipped

All measured, and test-verified against a green suite:

- **Dispatch reorder** — `_handle_parsed_message` `is`-chain ordered hottest-first
  (`TransactionUpdate`/`ReducerResult` first, one-shot `IdentityToken` last). Steady-
  state messages stop walking past 4 setup arms. Behavior-neutral (type-disjoint).
- **Per-packet stat-emit → per-frame** — `total_messages`/`total_bytes` are cumulative
  counters; emit once after draining a tick's packets, not per packet. N→1 emit pairs.
- **Skip empty listener-array duplication** — `apply_table_update` no longer
  `.duplicate()`s empty listener arrays (the no-listener common case); shared read-only
  empty sentinel, zero alloc. The duplicate **is** load-bearing when non-empty (a
  listener may unsubscribe mid-dispatch — verified: erasing during `for` shifts
  indices and silently skips a sibling). Kept exactly there.
- **Typed row comparison** — codegen emits `_eq` / `_row_eq`, so update detection on a
  generated row skips the generic column walk (~40% off an update; see "Update cost is
  dominated by value equality").

## Measured apply-path baseline

`LocalDatabase.apply_table_update`, saturated (N=100k, best-of-7, median of 5 runs,
re-measured 2026-09-11), `tests/bench_apply_profile.gd`:

| wave | prim row (6 primitive fields) | entity row (nested record field) | circle row (nested record + float) |
|---|---|---|---|
| insert | ~535 ns/row | ~545 ns/row | ~548 ns/row |
| update (detect) | ~2260 ns/row | ~2010 ns/row | ~2100 ns/row |
| delete | ~586 ns/row | ~613 ns/row | ~628 ns/row |

The prim row is declared inside the bench, so it has no generated `_row_eq` and its update
detection runs the generic walk. The entity and circle rows are generated bindings and run
the typed comparison codegen emits (next section), which is why the nested rows now update
faster than the flat one.

The bench prints these per-row numbers directly. It previously printed only
`update+setup` / `delete+setup` totals, and the doc quoted a subtraction the reader
had to guess at; the arithmetic now lives in the bench.

Per-row insert attributed via `tests/bench_apply_components.gd` (component ns/op):

| component | ns/op | share of insert |
|---|---|---|
| Variant-keyed dict set (×2: refcount + table) | ~110 each | ~40% |
| Variant-keyed dict get (refcount lookup) | ~100 | ~17% |
| per-row signal emit (1 listener) | ~142 | ~25% |
| `Resource.get(StringName)` (pk fetch) | ~44 | ~8% |

On signal cost, mind which zero-listener number you use: a signal that has **never**
been connected emits at ~150 ns, while the same signal after one connect+disconnect
cycle emits at ~78 ns (the connection slot is allocated lazily on first connect). It
is not a warmup artifact — a discard pass before timing doesn't close the gap. The
SDK's row signals always carry the client forwarder, so the 1-listener figure is the
one that describes production.

### Update cost is dominated by value equality

`update (detect)` costs about 4× an insert because change detection compares every
column **by value**: a nested record column compares by its own columns, not by Object
identity. That is a correctness requirement, not overhead. Every delivered row is a
fresh `.new()` with no interning, so an identity compare reported structurally-equal
rows as changed and fired spurious `row_updated` (fixed in `d3c8db2`).

Codegen emits that comparison typed to each row's own columns. Every generated record
type gets a static `_eq`, and every generated row type overrides
`_ModuleTableType._row_eq`, the call LocalDatabase makes to decide whether a re-delivered
row changed and to match a row in a table without a primary key. The override reads each
column directly with a check chosen for its type: `!=` for ints, strings and bytes, an
inline `is_nan` test for floats, `_nan_components_equal` for float vectors, the nested
record's own `_eq` for a record column, and `_values_equal` for Option, arrays and sum
types. It answers exactly what the generic `LocalDatabase._rows_equal` walk answers;
`tests/test_typed_row_equality.gd` holds the two together, NaN and null included. A row
script without the override falls back to the walk. That includes bindings generated
before the override existed.

Per call, generated override against the walk (4.8.dev editor, N=300k, best-of-7, median
of 5 runs, `tests/bench_rows_equal.gd`):

| row shape | equal: walk / generated | one column differs: walk / generated |
|---|---|---|
| config (int, int) | 366 / 183 ns (2.0×) | 371 / 178 ns, last int (2.1×) |
| player (bytes, int, String) | 542 / 221 ns (2.5×) | 609 / 215 ns, last String (2.8×) |
| entity (int, DbVector2, int) | 1469 / 423 ns (3.5×) | 1170 / 367 ns, nested float (3.2×) |
| circle (int, int, DbVector2, float, int) | 1725 / 490 ns (3.5×) | 1724 / 478 ns, last int (3.6×) |

The gain grows with nested records, where the walk looks up every nested column. On the
update wave (`tests/bench_apply_profile.gd`, same binary and method, main before the
change against after):

| row | before | after |
|---|---|---|
| entity (generated) | 3333 ns/row | 2012 ns/row (−40%) |
| circle (generated) | 3436 ns/row | 2098 ns/row (−39%) |
| prim (no override, falls back) | 2136 ns/row | 2261 ns/row (+6%) |

The 4.7 release template shows the same shape: entity 3044 → 1679 (−45%), circle 3038 →
1831 (−40%), prim 1770 → 1869 (+6%). The fallback costs a row without the override one
extra call, ~95 ns per comparison, so a project that updates the SDK without regenerating
its bindings updates about 6% slower until it regenerates. Detecting the override per table
would avoid that, but it adds a branch to every update to protect stale bindings, and
regenerating removes the cost and brings the gain.

The walk itself keeps two earlier wins: the per-`Script` BSATN_TYPES column list is
memoized, and primitive columns compare inline instead of through a `_values_equal` call.

A row that really changed ends its walk on the values-differ path, and that path
carries the NaN check: `NAN == NAN` is false, so a float or float-vector column needs
one to compare equal to itself. The check is gated by column type inline — an int
column returns unequal with no call, a float column tests `is_nan` in place, and only
the float-vector types call `_nan_components_equal`. The ungated form called it for
every differing column. `tests/bench_rows_equal.gd`, differing case, is what shows it:
an int change measured 1035 → 896 ns/call gated, a float change 849 → 788. The equal
case never reaches that path, which is why timing only the equal case missed it.

The generated override applies the same gate inline, per column type.

**Headroom** (tick-invariant — see tick-rate analysis above): sustained pure
main-thread apply tops out at ~**1.87M inserts/sec**, ~**0.50M updates/sec** on a
generated row (~**0.44M/sec** on a row without a generated `_row_eq`), ~**1.71M
deletes/sec** (1 sec ÷ per-row cost). The AIMD drain budget caps the per-tick slice below
a full tick, so exceeding these becomes latency (backlog drained over more ticks), not a
dropped frame. Expressed per 60 Hz tick that's ~31k inserts or ~8k updates before one
tick's worth of arrivals can't drain in one tick — but the rows/sec figure is the
portable one.

## Editor vs exported game

Every other number on this page comes from an editor binary, but a player runs an export
template. Measured 2026-09-10 on one machine: the official Godot 4.7-stable editor
against the 4.7-stable `linux_debug` and `linux_release` export templates. All three ran
one exported pck (compressed binary tokens, as a shipped game uses), with the binary order
rotated each round; medians of 4 rounds. All three decoded identical rows.

| bench | editor | debug template | release template | release vs editor |
|---|---|---|---|---|
| replay parse-only (`profile_deser`) | 69.8k rows/s | 69.8k rows/s | 91.2k rows/s | +31% |
| replay parse+apply (`profile_deser`) | 50.1k rows/s | 50.5k rows/s | 65.3k rows/s | +30% |
| row parse (`bench_e2e_receive`) | 4.50 µs/row | 4.41 µs/row | 2.75 µs/row | −39% |
| populate, generic / specialized (`bench_specialized_parser`)¹ | 2.61 / 1.37 µs/row | 2.62 / 1.34 µs/row | 1.95 / 0.98 µs/row | −25% / −29% |
| apply insert, prim / entity | 605 / 586 ns | 594 / 594 ns | 474 / 480 ns | −22% / −18% |
| apply update, prim / entity | 2679 / 4348 ns | 2597 / 4249 ns | 2162 / 3530 ns | −19% / −19% |
| apply delete, prim / entity | 733 / 764 ns | 720 / 714 ns | 577 / 562 ns | −21% / −26% |
| `_rows_equal`, prim equal / int column differs | 1039 / 1028 ns | 997 / 994 ns | 908 / 902 ns | −13% / −12% |

¹ A separate run the same day, medians of 5 rounds.

- **The debug template runs at editor speed.** The gap is GDScript's debug-build checks,
  not the editor's tools code. A debug export is no better stand-in for a player's build
  than the editor is.
- **Parse gains the most.** Row parse drops 39%, apply about 20%. Parse still dominates
  receive: 81% of `bench_e2e_receive`'s total on the release template, 86% in the editor.
- **Editor numbers are conservative for a shipped game.** The headroom figures and backlog
  triggers on this page come from editor runs, so a release export reaches each trigger
  later, not sooner.
- **Compare numbers only within one binary.** The custom 4.8.dev editor build behind the
  rest of this page replays at about 84k rows/s parse-only, between the official 4.7
  editor (69.8k) and the release template (91.2k). This comparison does not separate the
  version change from build options.
- **A per-row saving goes stale and does not transfer across binaries.**
  `bench_e2e_receive` used to subtract a fixed 2.80 µs/row, the specialized parser's
  saving as measured in June. That exceeds the whole row-parse stage on the release
  template, 2.75 µs/row. The same saving now measures 1.24 µs/row on the 4.7 editor and
  0.97 on the release template. `bench_e2e_receive` therefore prints only a ceiling, the
  speedup if row parse cost nothing. Measure the saving with `bench_specialized_parser`
  on the binary in question.
- **A specialized parser would make receive about 1.4× faster on the release template.**
  Estimated from the same binary's numbers: subtracting the 0.97 µs/row saving from
  `bench_e2e_receive`'s 3.40 µs/row total leaves 2.43 (1.40×). On a 200k-row initial
  snapshot that is about 680 → 485 ms. The ~195 ms saved is parse-thread time; apply
  still runs on the main thread under the frame budget either way. The `INLINE`
  variant, one bounds check per row, would reach 1.69×.

### After the generated `_row_eq` (2026-09-11)

The update and `_rows_equal` rows above predate the typed comparison codegen now emits.
Re-measured a day later, the 4.7 editor against the 4.7 release template (no debug
template this time), one exported pck, binary order rotated, medians of 5 rounds. The prim
row has no generated `_row_eq`, so it runs the generic walk through the fallback, one call
slower than before the change.

| bench | editor | release template | release vs editor |
|---|---|---|---|
| apply update, prim / entity / circle | 2700 / 2331 / 2370 ns | 1869 / 1679 / 1831 ns | −31% / −28% / −23% |
| row compare, circle equal: walk / generated | 2018 / 507 ns | 1759 / 433 ns | −13% / −15% |
| row compare, config equal: walk / generated | 403 / 195 ns | 363 / 171 ns | −10% / −12% |

## Research verdicts (2026-06-20)

A deep-research pass (23 sources, 25 adversarially 3-vote-verified claims, official
SpacetimeDB + Godot + Valve/Unity netcode primary sources) graded the backlog. **None
of our measured numbers were contradicted.** Verdicts:

- **Batch row signals — NO-GO.** Every official SpacetimeDB SDK (Rust `on_insert`,
  C# `OnInsert`, TS `onInsert`) delivers **per-row** callbacks — per-row is the canonical
  cross-SDK contract. Batching breaks API *and* diverges from every peer. Netcode prior
  art doesn't rescue it: Unity Netcode for Entities snapshots per-chunk on the server but
  applies **per-entity on the client**; Source batches on the *wire*, applies per-object.
  Wire-batching ≠ callback-batching. Keep per-row.
- **Forwarder removal — DEFER.** Real ~142 ns/row waste, but Godot signals *must* emit on
  the main thread (Node signals can't emit from worker threads; SceneTree + Resources not
  thread-safe — PR#105453, issue#81148, proposal#9747). No clean removal without coupling
  or an API break; flood-only cost. Defer.
- **Typed-pk dicts — NO-GO (premise refuted).** The int-vs-string dict speedup this lever
  relied on was killed 0-3 (godot#68834); "StringName keys slower" killed 0-3 (fixed by
  PR#68747). The speedup doesn't exist.
- **Tick-rate tuning — VALIDATED.** Valve: tickrate is a precision/latency/CPU lever, not
  throughput. Confirms throughput is tick-invariant; raising ticks buys latency.
- **Threading split — VALIDATED.** Our decode-on-thread + apply/signals-on-main-thread
  matches the C# SDK exactly ("splits background-thread parsing and main-thread cache
  mutation… not advised to run FrameTick on a background thread, since it modifies Db")
  and Rust's `frame_tick` = our per-tick drain. We independently arrived at the official
  architecture.

## Optimization backlog — measured, NOT taken

Ordered by magnitude. None is a no-regret win at current load; each is here so the
trade can be re-weighed if a real workload crosses its trigger.

### 1. Batch row signals (per-row emit → one emit per table_update) — **NO-GO** (research-graded)

- **What**: replace per-row `row_inserted(table, row)` with one
  `row_inserted_batch(table, Array[row])` per `table_update`. Collapses N emits → 1,
  and N forwarder re-emits → 1 (see #2).
- **Measured gain**: signal emit is ~25% of insert cost (~142 ns/row with the forwarder
  attached, ~284 ns/row counting the forwarder's own re-emit). At a 7k-update/tick flood
  the forwarder hop alone is ~1.0 ms/tick.
- **Cost / risk**: **breaking public-API change** (2.x → 3.0). Every consumer of
  `row_inserted`/`row_updated`/`row_deleted` rewrites. This is a product decision, not
  a perf one. Mitigation: ship the batch signal *alongside* the per-row one, deprecate
  per-row over a major.
- **Trigger**: sustained > ~5k row-deltas/tick on the main thread, or a profile showing
  signal dispatch as a top frame cost. Below that, AIMD already hides it.

### 2. Drop the LocalDatabase→client signal forwarder double-emit

- **What**: every row currently fires a LocalDatabase signal **and** a client forwarder
  re-emit of the client's own same-named signal (`_forward_row_*`). Two dispatches/row.
- **Measured gain**: ~142 ns/row pure overhead (the internal hop carries no behavior —
  it only re-exposes the DB signal as a client signal).
- **Cost / risk**: removing it cleanly means consumers connect to `client.local_db.row_*`
  instead of `client.row_*` → **breaking API**. The forwarder exists for layering
  (LocalDatabase doesn't know `client`). Folds naturally into #1 if that's ever done.
- **Trigger**: same as #1 — only matters under flood, and shares the same fix.

### 3. Codegen typed `_row_eq()` per generated row class — **SHIPPED** (2026-09-11)

- **Outcome**: generated rows update ~40% faster; details and numbers under "Update cost
  is dominated by value equality". The coupling this entry warned about, generated
  checks drifting from `_values_equal`, is held by `tests/test_typed_row_equality.gd`. It
  compares the generated checks with the walk for every column shape codegen emits.
- **Measured, not taken**: expanding a nested record column inline instead of calling the
  record's `_eq` saved ~40 ns more on a ~450 ns circle comparison (~9%), at the price of
  recursive codegen. Emitting `_row_eq` as a call into `_eq`, rather than repeating the
  checks, cost ~200 ns per comparison and was dropped before shipping.

### 4. Typed-pk inner dicts — **NO-GO** (premise refuted by research)

- **What**: `_tables[name]` inner dict is untyped (Variant pk keys). A `Dictionary[int, T]`
  when pk is `int` would *supposedly* cut the Variant hash cost (~45% of insert).
- **Premise refuted**: the int-vs-string dict speedup this relied on was killed 0-3 in
  adversarial verification (godot#68834 — the claimed 135 ns vs 250-350 ns gap); the
  "StringName keys ~25% slower" claim was also killed 0-3 (fixed by PR#68747). The speedup
  the lever was built on does not exist. **Do not pursue** absent a fresh bench proving
  a typed-pk gain on this engine version.
- **Cost / risk**: pk type varies per table (int / string / identity-bytes), so this needs
  codegen knowledge of each table's pk type + per-type dict instantiation. Complex for a
  fraction of the 45% — that itself unproven.
- **Trigger**: profile showing dict ops dominating under a sustained insert/delete flood
  on int-pk tables. Low priority.

## Reproduce

```
cd godot-client
GB=<path-to-godot-binary>
$GB --headless --path . --script tests/bench_apply_profile.gd       # apply waves (insert/update/delete)
$GB --headless --path . --script tests/bench_apply_components.gd    # per-row cost attribution
$GB --headless --path . --script tests/bench_rows_equal.gd          # generated _row_eq vs the _rows_equal walk
$GB --headless --path . --script tests/bench_tick_overhead.gd       # idle-tick overhead vs tick rate
$GB --headless --path . --script tests/bench_e2e_receive.gd         # decompress / row parse / apply shares
$GB --headless --path . --script benchmark/profile_deser.gd         # real replay, parse-only vs parse+apply
```

Always re-bench on the target machine + Godot version before acting on a threshold;
the absolute nanoseconds are not portable, the shares roughly are.

### On an export template

A release template ignores `--script` and `--main-loop`: a build without path-override
support clears both in `main/main.cpp` before it picks a main loop. It still loads an
`override.cfg` placed beside the executable, so select the bench there:

1. In a scratch copy of `godot-client/`, give the bench script a `class_name` (the bench
   scripts have none) and add an empty scene, then re-import.
2. Export with a Linux preset. Add `*.bin` to the include filter, so the replay fixture
   ships in the pck.
3. Write an `override.cfg` beside the exported executable, then run the executable with
   `--headless`:

   ```
   [application]
   run/main_loop_type="BenchApplyProfile"
   run/main_scene="res://empty.tscn"
   ```

4. For the editor run, put the same `override.cfg` in the project directory and run
   without `--script`, so every binary takes the same code path.

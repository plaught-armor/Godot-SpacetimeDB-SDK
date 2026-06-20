# Performance Notes

How the inbound path spends time, what's already optimized, and the optimizations
deliberately *not* taken yet — each with a measured number and a trigger threshold,
so the call can be revisited from data rather than re-derived.

> **Numbers are machine-relative.** All ns/op figures below were measured on one
> dev machine (Godot 4.8.dev headless, release-ish build). Treat the **ratios and
> shares** as the signal, not the absolute nanoseconds. Re-run the benches in
> `godot-client/tests/bench_*.gd` on the target before acting on any threshold.

## The inbound pipeline

A message goes through three stages from socket to game state:

1. **Poll** — `SpacetimeDBConnection._physics_process` calls `_websocket.poll()`,
   drains available packets, hands each to the client via `message_received`.
2. **Parse** — when `use_threading` (default on, off on Web), a background thread
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

- **Per-row apply cost is tick-invariant.** A Variant dict insert is 107 ns whether
  the tick is 60 or 240 Hz. The tick rate changes *when* the drain runs, not how long
  GDScript ops take. Sweeping the apply / component micro-benches across tick rates
  returns identical ns/row — no point.
- **Throughput is tick-invariant.** Rows arrive at a network-driven rows/**sec**,
  independent of tick rate. Higher ticks = the same rows spread over more ticks = fewer
  rows/tick *and* a proportionally smaller budget/tick. Budget-*per-row* is constant.
  Raising ticks does **not** reduce sustainable rows/sec.
- **Fixed per-tick overhead** is the only thing that scales with tick rate (paid
  `ticks/sec` times), and it's negligible. Measured idle-tick drain proxy
  (`bench_tick_overhead.gd`): **34 ns/tick** → fixed overhead per second:

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

## Already shipped (branch `perf/parse-poll-hot-path`)

All measured + test-verified (39/39 suite green):

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

## Measured apply-path baseline

`LocalDatabase.apply_table_update`, saturated (N=100k, best-of-7),
`tests/bench_apply_profile.gd`:

| wave | prim row (6 primitive fields) | entity row (nested object field) |
|---|---|---|
| insert | 503 ns/row | 525 ns/row |
| update (detect) | ~1854 ns/row | ~2099 ns/row |
| delete | ~579 ns/row | ~709 ns/row |

Per-row insert attributed via `tests/bench_apply_components.gd` (component ns/op):

| component | ns/op | share of insert |
|---|---|---|
| Variant-keyed dict set (×2: refcount + table) | 107 each | ~45% |
| Variant-keyed dict get (refcount lookup) | 99 | ~20% |
| per-row signal emit (0 listeners / 1 listener) | 98 / 141 | ~20% |
| `Resource.get(StringName)` (pk fetch) | 44 | ~10% |

**Headroom** (tick-invariant — see tick-rate analysis above): sustained pure
main-thread apply tops out at ~**2.0M inserts/sec**, ~**0.54M updates/sec**,
~**1.7M deletes/sec** (1 sec ÷ per-row cost). The AIMD drain budget caps the per-tick
slice below a full tick, so exceeding these becomes latency (backlog drained over more
ticks), not a dropped frame. Expressed per 60 Hz tick that's ~33k inserts or ~9k updates
before one tick's worth of arrivals can't drain in one tick — but the rows/sec figure is
the portable one.

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
- **Forwarder removal — DEFER.** Real ~98 ns/row waste, but Godot signals *must* emit on
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
- **Measured gain**: signal emit is ~20–28% of apply cost (~98 ns/row at 0 listeners,
  ~196 ns/row counting the client forwarder's second emit). At a 9k-update/tick flood
  the forwarder hop alone is ~0.88 ms/tick.
- **Cost / risk**: **breaking public-API change** (2.x → 3.0). Every consumer of
  `row_inserted`/`row_updated`/`row_deleted` rewrites. This is a product decision, not
  a perf one. Mitigation: ship the batch signal *alongside* the per-row one, deprecate
  per-row over a major.
- **Trigger**: sustained > ~5k row-deltas/tick on the main thread, or a profile showing
  signal dispatch as a top frame cost. Below that, AIMD already hides it.

### 2. Drop the LocalDatabase→client signal forwarder double-emit

- **What**: every row currently fires a LocalDatabase signal **and** a client forwarder
  re-emit of the client's own same-named signal (`_forward_row_*`). Two dispatches/row.
- **Measured gain**: ~98 ns/row pure overhead (the internal hop carries no behavior —
  it only re-exposes the DB signal as a client signal).
- **Cost / risk**: removing it cleanly means consumers connect to `client.local_db.row_*`
  instead of `client.row_*` → **breaking API**. The forwarder exists for layering
  (LocalDatabase doesn't know `client`). Folds naturally into #1 if that's ever done.
- **Trigger**: same as #1 — only matters under flood, and shares the same fix.

### 3. Codegen typed `_row_eq()` per generated row class — **REJECTED by measurement**

- **What**: replace `_rows_equal`'s dynamic `a.get(name) != b.get(name)` field loop with
  a codegen-emitted typed `func _row_eq(o) -> bool: return id == o.id and ...`.
- **Measured**: the typed comparator is **1.63× / 172 ns/call faster in isolation**
  (`bench_rows_equal.gd`, 6 primitive fields, full-walk equal case) — BUT the apply
  profile proves `_rows_equal` is **not** the bottleneck: the nested-object `entity` row
  (bails at field 2) costs *more* per update than the `prim` row (full 6-field walk).
  Field comparison isn't where update time goes; Variant dict ops + signals are.
- **Cost / risk**: codegen change + bindings regen + golden-test regen, on every schema
  change, forever. Object-field tables (the common case) bail after 1–2 compares and gain
  ~nothing.
- **Trigger**: an all-primitive, update-heavy table sustaining > ~5k updates/tick. Even
  then, re-bench *that table's* real update volume first — the isolated 1.63× does not
  survive the object-field bail in practice.

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
$GB --headless --path . --script tests/bench_rows_equal.gd          # _rows_equal: dynamic vs typed lever
$GB --headless --script tests/bench_tick_overhead.gd               # idle-tick overhead vs tick rate
```

Always re-bench on the target machine + Godot version before acting on a threshold;
the absolute nanoseconds are not portable, the shares roughly are.

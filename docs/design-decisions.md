# Design Decisions

Why some features exist, why some don't, and why some that *look* missing are
deliberately out of scope. Recorded so the calls aren't re-litigated each time
someone compares this SDK against the official Rust / C# / TypeScript clients.

The comparison that drove this list was a feature-parity audit of all four
client SDKs against the SpacetimeDB v2/v3 wire protocol (June 2026). The short
version: this SDK is at or ahead of parity on everything the wire can carry.

## Blocked by the wire — not actionable client-side

These are absent because SpacetimeDB **removed the data from the wire** at the
v1 → v2 protocol cut, and v3 reuses v2 message bodies verbatim. No client SDK
(Rust, C#, TypeScript, Godot) can surface them; doing so needs an upstream
protocol change. They are documented as caveats in the [README](../README.md#known-limitations--caveats):

- **Reducer-event caller identity / connection id / energy.** `TransactionUpdate`
  on v2/v3 is only a list of per-query-set row deltas. A row callback fired by
  *another* client's reducer cannot know who caused it. Your *own* call is
  recoverable by correlating the response `request_id` (the `SpacetimeDBReducerCall`
  handle already does this).
- **Out-of-energy outcome.** No distinct wire variant — energy exhaustion arrives
  as `InternalError` / `Err` with a message.
- **Reducer call flags (`NoSuccessNotify` / `FullUpdate`).** v2/v3 `CallReducerFlags`
  is single-variant (`Default`); the server rejects any other byte. Fire-and-forget
  reducers existed in v1 and were removed.

If a future protocol (v4) re-adds caller identity to `TransactionUpdate`, an
`EventContext`-style callback argument becomes worth building. Until then it has
no data to carry beyond what the reducer handle already gives you.

## Built

- **Btree range queries** — `filter_range(from, to)` (inclusive) plus the one-sided
  `filter_gte` / `filter_gt` / `filter_lte` / `filter_lt` on orderable index columns
  (`int` / `float` / `String`), backed by a sorted-key mirror (O(log d + k)).
  Bytes-backed keys (`Identity`, `u128`/`u256`) keep exact-match `filter()` only —
  no defined ordering for `bsearch`.
- **Per-request latency stats** — `client.get_stats()` returns a `SpacetimeDBStats`
  with round-trip latency bucketed by category (reducer / procedure / one-off /
  subscribe). Closes the last diagnostics gap vs the C# SDK's `Stats` object.

## Deliberately out of scope

Considered during the parity audit, decided against. Revisit only when a concrete
need shows up — listed with the trigger that would justify reopening.

| Skipped | Why | Reopen when |
|---|---|---|
| **Sliding-window / percentile latency** (C# keeps a rolling time window) | All-time min/max/avg + last answers "is this slow." Windowed percentiles need a per-category ring buffer — real complexity for a diagnostic-only payoff. | Profiling needs p95/p99, not just min/max. |
| **Exclusive / unbounded `filter_range` flags** (a `Range` POD with included/excluded/unbounded bounds, like the TS SDK) | The inclusive `filter_range` plus four one-sided bounds express every real query shape with zero per-call allocation. A bounds object adds an API surface and an alloc nobody asked for. | A query genuinely needs a half-open compound bound the four accessors can't compose. |
| **Per-reducer-name latency breakdown** | Category-level stats answer "reducers slow vs procedures slow." Per-name needs a name→tracker map that grows unboundedly with the reducer set. | One specific reducer needs isolating — then key a map inside the reducer category. |
| **Stats enable/disable toggle** | Cost is ~2 dict ops + one `Time.get_ticks_usec` per request — trivial against the network round-trip. A flag adds config surface to save nothing measurable. Always-on, like the C# SDK. | A measured hot path shows the tracking itself on a profile. |
| **`EventContext` callback argument** (Rust/C#/TS pass a context to row callbacks) | The only data it would carry that the SDK doesn't already expose is caller identity — which isn't on the v2/v3 wire (see above). The remaining value (db / reducers access inside a callback) is already reachable via the module client and the `SpacetimeDB` autoload, and adding the arg is a breaking change to every callback signature. | A v4 protocol re-adds caller identity to `TransactionUpdate`. |
| **Fluent connection builder** (`DbConnection.builder().withUri()...`) | `SpacetimeDBConnectionOptions` (a `Resource`) covers the same surface and is the idiomatic Godot shape — editor-inspectable, savable. A fluent builder would be a parallel API for cosmetics. | — (idiomatic choice, unlikely to reopen). |
| **Typed column query DSL** (`tables.user.where(r => r.online.eq(true))`) | `SpacetimeDBQuery` (`.table().where().to_sql()`) already builds validated SQL. A typed-column DSL fights GDScript's lack of generics for a marginal ergonomic gain. | GDScript gains the type machinery to make it compile-checked, or query typos become a real reported pain. |

## Where this is enforced

- Wire-blocked items: README "Known Limitations & Caveats" (user-facing).
- Built features: README "Features" + `docs/api.md`.
- This file: the *why-not* for the deliberate skips, so they stay decided.

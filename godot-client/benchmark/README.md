# Benchmarks

Performance harnesses for the SDK. Three kinds, from synthetic to real:

## 1. In-process apply micro-bench — `micro_bench.gd`

No server, no network. Times `LocalDatabase.apply_table_update` (insert / update /
delete, PK + PK-less, with/without `query_id` membership) over synthetic rows. Saturates
the apply hot path by construction, so it isolates per-row apply cost. Branch-agnostic
(string-based `get`/`callv`) — run on two branches and diff for a before/after.

```sh
<godot> --headless --path . --script res://benchmark/micro_bench.gd
```

## 2. Real-workload replay — `replay_workload.gd` (+ `capture_workload.gd`, `bench_workload.bin`)

Replays a **captured real Blackholio inbound packet stream** through the deserializer +
`LocalDatabase` in-process (no server). Measures deserialize + apply on real data shapes
(actual entity/circle/food row sizes and insert/update/delete mix) at saturation. This is
the most representative number — and it shows **deserialize dominates** real throughput
(~25× the apply-only micro-bench cost).

```sh
<godot> --headless --path . --script res://benchmark/replay_workload.gd
```

`bench_workload.bin` is a committed fixture (a captured stream) so the replay is
reproducible offline. To re-capture (needs a server with Blackholio + bot load):

```sh
spacetime start &
spacetime publish -p <repo>/SpacetimeDB/demo/Blackholio/server-rust -s http://127.0.0.1:3000 blackholio --yes
# bot load in one process:
<godot> --headless --path . --script res://benchmark/bench_load.gd -- 50 &
# capture (compression NONE so the fixture replays without a decompress step):
<godot> --headless --path . --script res://benchmark/capture_workload.gd -- 100000
```

## 3. End-to-end bot-load throughput — `bench_load.gd` + `bench_measure.gd`

Live, network-bound. `bench_load` spawns K bots flooding the server; `bench_measure`
subscribes one client and reports rows/sec + fps + drain backlog under that load. Good
for the frame-budget drain/parse path. **Caveat:** network-bound — if it isn't saturated
(fps pinned at a cap, backlog draining to 0) it can't reveal per-op cost; prefer the
micro-bench or replay for that.

```sh
spacetime start &  # + publish blackholio
<godot> --headless --path . --script res://benchmark/bench_load.gd -- 40 &
<godot> --headless --path . --script res://benchmark/bench_measure.gd -- 40
```

# Blackholio example client

A Godot port of SpacetimeDB's [Blackholio](https://github.com/clockworklabs/Blackholio)
demo (agar.io-style), built on this SDK. Lives in `scripts/` (`main.gd`,
`entity_node.gd`, `ui/leaderboard.gd`) with generated bindings in
`spacetime_bindings/`.

The client connects to `http://127.0.0.1:3000`, module `blackholio`
(see `scripts/main.gd`, which calls `SpacetimeDB.Blackholio.connect_db(...)` on
the generated module autoload).

## Run a server to test against

You need a local SpacetimeDB running the Blackholio module named `blackholio`.

1. **Install the SpacetimeDB CLI** (this example was verified with **2.7.0**):
   <https://spacetimedb.com/install>

2. **Start a local server** (keep it running):
   ```sh
   spacetime start --data-dir ~/.local/share/spacetime-blackholio
   ```

3. **Publish the bundled Blackholio server module** as `blackholio`. This repo
   ships a vendored copy at [`blackholio-server/`](../blackholio-server/),
   pinned to `spacetimedb = "2.5.0"` so it builds cleanly against the tested CLI:
   ```sh
   cd ../blackholio-server
   ./publish.sh          # spacetime publish -s local blackholio --delete-data -y
   ```
   Tail its logs with `./logs.sh`.

   > **Why bundled?** Blackholio's upstream `master` server targets SpacetimeDB
   > `master` and uses newer macro syntax (`name =` table attribute, bare
   > `ctx.sender`). Force-porting it to a released CLI compiles but breaks
   > gameplay (`enter_game` rolls back, no circles spawn). The vendored copy is
   > already pinned + patched for the **2.5.0** crate, so no tweaks are needed.

4. **Regenerate bindings** (only if your server's schema differs from the
   committed ones) — either via the editor SpacetimeDB dock, or headless:
   ```sh
   godot --headless --path . --script res://addons/SpacetimeDB/cli.gd
   ```
   (Configure the module once in the editor dock first; see
   [docs/codegen.md](../docs/codegen.md).)

## Run the client

Open `godot-client/` in Godot 4.7 and press **F5**. Enter a name to spawn.
Controls: mouse to move, **Space** to split, **S** to suicide, **Q** to lock aim.

## Load testing (perf harness)

Two headless tools stress the SDK's inbound pipeline (deserialize → apply →
per-frame drain) against a live Blackholio server:

- `bench_load.gd` — spawns N bot connections that play (move continuously), so
  the server's `move_all_players` tick produces a high-volume entity-update
  stream. `N` via a trailing arg:
  ```sh
  godot --headless --path . --script res://benchmark/bench_load.gd -- 200
  ```
- `bench_measure.gd` — one instrumented client; reports rows/sec applied, fps,
  and the unapplied drain backlog over a window:
  ```sh
  godot --headless --path . --script res://benchmark/bench_measure.gd -- 200
  ```
  The trailing arg is only echoed back as the `bots=` label in the `RESULT`
  line (to tag the run with the load size you started separately); it does not
  spawn bots or change the workload.

Run the load in the background, then the measure. `end_backlog ≈ 0` means the
drain keeps up; a growing backlog across the window is the real ceiling.
Validated to ~17k rows/sec (the local server's max output) with backlog ~0 —
the client absorbs the server's full throughput without falling behind.

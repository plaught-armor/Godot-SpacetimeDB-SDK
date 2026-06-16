# Blackholio example client

A Godot port of SpacetimeDB's [Blackholio](https://github.com/clockworklabs/Blackholio)
demo (agar.io-style), built on this SDK. Lives in `scripts/` (`main.gd`,
`entity_node.gd`, `ui/leaderboard.gd`) with generated bindings in
`spacetime_bindings/`.

The client connects to `http://127.0.0.1:3000`, module `blackholio`
(see `scripts/main.gd` → `connect_db`).

## Run a server to test against

You need a local SpacetimeDB running the Blackholio module named `blackholio`.

1. **Install the SpacetimeDB CLI** (this example was verified with **2.5.0**):
   <https://spacetimedb.com/install>

2. **Start a local server** (keep it running):
   ```sh
   spacetime start --data-dir ~/.local/share/spacetime-blackholio
   ```

3. **Get the Blackholio server module** and publish it as `blackholio`:
   ```sh
   git clone https://github.com/clockworklabs/Blackholio.git
   cd Blackholio/server-rust
   spacetime publish blackholio --server local
   ```

   > **Version note:** Blackholio's `master` server targets SpacetimeDB `master`.
   > To build it against the **2.5.0** CLI, two small macro-syntax tweaks in
   > `src/lib.rs` are needed (the table macro and the sender accessor changed
   > between releases):
   > - table attribute `name = <ident>` → `accessor = <ident>`
   > - `ctx.sender` → `ctx.sender()`
   >
   > Building with a CLI that matches Blackholio's pinned SpacetimeDB version
   > avoids these tweaks entirely.

4. **Regenerate bindings** (only if your server's schema differs from the
   committed ones) — either via the editor SpacetimeDB dock, or headless:
   ```sh
   godot --headless --path . --script res://addons/SpacetimeDB/cli.gd
   ```
   (Configure the module once in the editor dock first; see
   [docs/codegen.md](../docs/codegen.md).)

## Run the client

Open `godot-client/` in Godot 4.7 and press **F5**. Enter a name to spawn.
Controls: mouse to move, **Space** to split, **Q** to suicide.

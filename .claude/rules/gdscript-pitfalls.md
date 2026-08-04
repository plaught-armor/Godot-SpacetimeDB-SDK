# GDScript Pitfalls — Project Deltas

Thin project layer. Two other sources carry the bulk — don't duplicate them here:

- **Canon (teaching + rationale)** → `~/.claude/rules/gdscript/` (read `index.md`, load the relevant section): engine bugs, type/async, style, DOD, resource loading.
- **Enforcement (full rule audit)** → `gdscript-reviewer` subagent (`.claude/agents/03_gdscript-reviewer.md`). Runs in its own context; invoke after `.gd` changes.

Below = only what's specific to this SpacetimeDB SDK, or the project workflow. Everything else lives in canon above.

## SpacetimeDB specifics

- **Enum mismatch at reducer call sites** — cast GDScript enums to `int` when passing to a generated reducer. Wire format is int; the enum type doesn't survive the boundary.
- **BSATN deserialization is a real Variant boundary** — row callbacks / decoded rows arrive untyped. Convert to the typed form at the boundary, then keep downstream code typed (reviewer H10/H10b treat this as a sanctioned exception, not a license to stay untyped).
- **Generated bindings** at `godot-client/spacetime_bindings/` — regenerate when codegen changes; don't hand-edit. After a deliberate codegen change, regen goldens (`STDB_REGEN_GOLDEN=1`) and review the diff.
- **A message the server sends right before closing never reaches the SDK** — Godot's `WebSocketPeer` calls `in_buffer.clear()` when a clean close completes, and the whole close handshake happens inside one `poll()`, so a data frame that arrived in the same read is gone before any script runs. Engine-side, not fixable here; don't go looking for a drain the SDK is missing. Reproducer + full write-up: `godot-client/tests/_repro_ws_close_drops_final_messages.gd` and `docs/design-decisions.md`.

## Project workflow

- Run `gdscript-formatter` on changed `.gd` files, then verify.
- Run `validate_script` (MCP) after editing `.gd` files — error code 43 with empty errors = valid (autoload-dependent).
- Tests: `godot-client/run_tests.sh` (headless, exit code = fail count).

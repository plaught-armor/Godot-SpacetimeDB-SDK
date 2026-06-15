# Godot SpacetimeDB SDK

GDScript SDK for SpacetimeDB. Godot 4.7 + SpacetimeDB 2.1.0 (tested 2.0.0–2.1.0).

## Scope

- Core SDK work lives in `godot-client/addons/SpacetimeDB/`.
- Generated bindings at `godot-client/spacetime_bindings/` — regenerate when codegen changes.
- Example code at `godot-client/example_code/`.

## Conventions

- Global GDScript rules apply: `~/.claude/rules/gdscript/` (read `index.md` first, load only the relevant section).
- Project-local GDScript pitfalls: `.claude/rules/gdscript-pitfalls.md`.
- Run `gdscript-formatter` on changed `.gd` files, then verify.
- Run `validate_script` after editing `.gd` files.
- For review, invoke the `gdscript-reviewer` subagent.

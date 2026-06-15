# GDScript Pitfalls

> Full ruleset: see `.claude/agents/03_gdscript-reviewer.md` (73 rules with engine bug links). Below are the rules most relevant to daily development.

## Engine Bugs (will crash or corrupt)

**`const` packed arrays are broken** ([#88753](https://github.com/godotengine/godot/issues/88753)) — `const Array[PackedFloat32Array]` — `.size()` returns byte count, values read 0.0. Use `static var` for class-accessed, `var` otherwise.

**`const` arrays/dicts are mutable shared references** ([#61274](https://github.com/godotengine/godot/issues/61274)) — `const MY_ARR = [1,2,3]` can be mutated by anyone and changes are visible everywhere. Never mutate; `.duplicate()` first.

**Typed `.filter()`/`.map()` return untyped Array** ([#72566](https://github.com/godotengine/godot/issues/72566)). Must use `assign()`:
```gdscript
var result: Array[MyType] = []
result.assign(items.filter(func(p): return is_instance_valid(p)))
```

**`await` on freed object leaks or crashes** ([#72629](https://github.com/godotengine/godot/issues/72629)). Check `is_instance_valid()` after any `await` involving a node.

**RefCounted circular references leak silently** ([#7038](https://github.com/godotengine/godot/issues/7038)). Use `weakref()` for one direction, or entity IDs instead of object references.

**Freed object ID reuse** ([#32383](https://github.com/godotengine/godot/issues/32383)). Stale reference may point to a different object. Null-out refs after freeing; check validity AND type.

**`assert()` stripped in release builds**. Never for runtime validation — use `if` + `push_error`.

**`sort_custom` must be strict `<`** ([#58878](https://github.com/godotengine/godot/issues/58878)). Never `<=`. `Array.sort()` is NOT stable — include tiebreaker.

## Type System & Async

**No implicit type inference** — never use `:=`. Static typing = 40-47% faster execution.

**No inline lambdas** — `gdscript-formatter` breaks indentation. Extract to named methods.

**Lambda captures by-value for locals, by-reference for members** ([#69014](https://github.com/godotengine/godot/issues/69014)). Use member vars or mutable containers to share state.

**Concurrent coroutine race conditions** — non-deterministic resume order. Use flag+poll patterns.

**No `await` in `_ready()`** — pauses init unpredictably. Use `call_deferred()` or separate coroutine.

**Signal `await` without timeout** — network/reducer code must have timeout fallback.

**Node method name collisions** — never shadow `get_owner`, `get_name`, `get_path`, etc.

## Style & Conventions

**Typed `for` loops** — always `for item: Type in collection`.

**SpacetimeDB enum mismatch** — cast to `int` at reducer call sites.

**Dictionary access on known schemas** — direct `data["key"]`, not `.get("key", default)`.

**No ungated print statements** — gate behind debug flag. `print()` is synchronous I/O and measurably slow.

**Freed object checks** — always `is_instance_valid(obj)`, never truthiness (`if obj:`).

**Non-autoload nodes must disconnect from autoload signals in `_exit_tree()`**.

**`validate_script` for error checking** — run after editing `.gd` files. Error code 43 with empty errors = valid (autoload-dependent).

**Shadowed parameter names** — rename to avoid shadowing members. **Animation library prefix** — `LibName/AnimName`. **`DirAccess` in exports** — wrap in `OS.has_feature("editor")`. **Null checks** — truthiness for guards, explicit null when 0/false could be valid.

# Contributing

Thanks for helping improve the Godot SpacetimeDB SDK. This guide covers the
local workflow — how to run the tests, enable the pre-push gate, and update the
codegen golden files.

## Prerequisites

- A Godot 4 editor binary (the SDK is developed against Godot 4.7+; the test
  suite runs headless). Point the tooling at it with the `GODOT_BIN` environment
  variable if `godot` is not on your `PATH`.

## Running the tests

The suite lives in `godot-client/tests/`. Each test is a
standalone script that extends `SceneTree`, asserts as it runs, and exits with
its failure count (`0` means everything passed). Run the whole suite with:

```sh
cd godot-client
./run_tests.sh                       # run every test_*.gd
./run_tests.sh test_row_parse        # run one (name with or without .gd)
GODOT_BIN=/path/to/godot ./run_tests.sh
VERBOSE=1 ./run_tests.sh             # stream each test's full output
```

The runner launches one Godot process per test so a crash in one test cannot
take down the others. It exits `0` when every test passes and `1` if any fail.

## Pre-push gate

A pre-push hook runs the full suite and blocks the push if anything fails. The
hook is committed under `.githooks/` but is inert until you point git at it:

```sh
git config core.hooksPath .githooks
```

To push without running the suite (for a docs-only change, say), use
`git push --no-verify`.

## Codegen golden tests

`test_codegen_golden.gd` locks the exact GDScript text that codegen emits. It
parses the captured schema fixtures under `godot-client/tests/fixtures/`, runs
the generator, and diffs every emitted file against the committed golden in
`godot-client/tests/golden/`.

If you make a **deliberate** change to codegen output, regenerate the goldens
and review the diff before committing:

```sh
cd godot-client
STDB_REGEN_GOLDEN=1 ./run_tests.sh test_codegen_golden   # or run the script directly
git diff tests/golden                                    # review every change
```

A golden diff you did not intend is a regression — investigate before
regenerating it away. The golden directory carries a `.gdignore` so Godot does
not register the generated `class_name`s as project globals.

## Code style

Baseline is the [official GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html).
On top of that, this SDK follows
[**gdscript-lint**](https://github.com/plaught-armor/gdscript-lint) — a rule
corpus for the Godot 4 engine gotchas that `gdformat` and `gdtoolkit`'s `gdlint`
don't cover: the things that compile fine and then break, leak, or silently
corrupt at runtime. Each rule is tied to a Godot issue number where one exists,
and every performance-motivated rule is benchmarked before it ships, so the
rules are checkable rather than taste. `rules/index.md` in that repo is the map;
the linter itself is a single zero-dependency Python file you can run locally.

That matters more here than in a typical game project: an SDK's bugs surface in
*other people's* projects, where they are far harder to trace back.

The rules that come up most in this codebase:

- Run `gdscript-formatter` on changed `.gd` files, then verify they still parse.
- Static typing is mandatory: `var x: Type = value` (never `:=`), typed `for`
  loops, typed parameters and return values.
- Prefer `Packed*Array` over `Array[primitive]`, and never declare an array or
  dictionary `const` — `const` containers are shared mutable references in
  Godot 4.
- Bracket access on known schemas (`data["key"]`), not `.get("key", default)`;
  reserve `.get()` for genuinely optional external data.
- Check `is_instance_valid()` after any `await` that involves a `Node`.

BSATN decoding is a genuine `Variant` boundary — decoded rows and row callbacks
arrive untyped. Convert to the typed form at that boundary, then keep everything
downstream typed.

## Pull requests

Keep changes surgical — touch only what the task needs. Run `./run_tests.sh`
before opening a PR; if you changed codegen, include the regenerated goldens in
the same PR as the code change so the diff tells the whole story.

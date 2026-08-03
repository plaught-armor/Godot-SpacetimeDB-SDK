# Submodules / namespaces — upstream readiness note

**Status: not supported, nothing to do yet.** Namespaced submodules exist only on
SpacetimeDB's `master` (PR [#5486](https://github.com/clockworklabs/SpacetimeDB/pull/5486),
commit `87907691c`, 2026-08-02). No tag contains them — the newest release is
`2.7.1` — and only the TypeScript server SDK can author them today. This note
records what the feature does to the wire so the work is already scoped when it
does ship.

Everything below was verified against the `master` sources, not inferred from the
PR description. The schema JSON was produced by running the same conversion and
serializer the HTTP schema route uses
(`RawModuleDefV10::from(module_def)` wrapped in `sats::serde::SerdeWrapper`, see
`crates/client-api/src/routes/database.rs`) over a module with one submodule; the
probe is committed as `integration-tests/schema_probe/` and its output as
`godot-client/tests/fixtures/vsubmod.json`.

## What the wire looks like

**A new schema section, carrying a whole nested module.** `RawModuleDefV10Section`
gains `Submodules(Vec<RawSubmoduleV10>)`, where each entry is
`{ "namespace": "lib", "module": { "sections": [...] } }` — a complete
`RawModuleDefV10`, with its own `Typespace`, `Types`, `Tables`, `Reducers` and
`ExplicitNames`. Submodule tables are **not** flattened into the root `Tables`
section.

**Each nested module has its own type-ref space.** In the captured fixture the
root `Typespace` and the `lib` `Typespace` both have a type at index `0`, and they
are different types. `product_type_ref: 0` inside the submodule means "index 0 of
the submodule's typespace". A parser that hoisted submodule tables into the root
table list without also scoping their type refs would silently bind rows to the
wrong type — this is the single biggest hazard in implementing the feature.

**Names on the wire are dot-qualified, using the canonical spelling.** The engine
registers a submodule table under `<namespace>.<canonical_name>` and a reducer
under `<namespace>.<canonical_name>`:

| Def | `source_name` | `ExplicitNames` canonical | Wire / catalog name |
| --- | --- | --- | --- |
| root table | `RootThing` | `root_thing` | `root_thing` |
| submodule table | `LibData` | `lib_data` | `lib.lib_data` |
| root reducer | `rootInsert` | `root_insert` | `root_insert` |
| submodule reducer | `libInsert` | `lib_insert` | `lib.lib_insert` |

The accessor spelling is an alias, never an identity — `lib.LibData` is explicitly
rejected (`crates/schema/src/schema.rs`, `check_compatible_submodule_table_name`).
Namespaces nest, so a name can carry more than one dot (`auth.baz.baz_items`), and
the SQL parser joins all leading parts back into one catalog name rather than
treating them as qualification (`crates/sql-parser/src/parser/mod.rs`,
`parse_parts`). Subscriptions therefore read `SELECT * FROM lib.lib_data`, and
`CallReducer` carries `lib.lib_insert`.

**Nothing else about the protocol changed.** `crates/client-api-messages` is
byte-identical between `v2.7.0` and `master`.

## What this SDK does with it today

Verified, not assumed: feeding `tests/fixtures/vsubmod.json` through
`SpacetimeSchemaParser.parse_schema()` yields the root table and root reducer and
skips the rest without an error, because the section dispatch in
`addons/SpacetimeDB/codegen/schema_parser.gd` is an `if section.has(...)` chain
with no `else`. `tests/golden/vsubmod/` is the generated output for that fixture,
and it contains `root_thing` only — no `lib_data`, no `lib_insert`. So a client
pointed at a namespaced module connects and works, minus every submodule table,
reducer, procedure and view.

Keeping the fixture in the golden set means the day submodules are implemented,
the diff shows exactly which generated files appear.

## What implementing it would take

- **Parser:** recurse into `Submodules`, carrying the namespace prefix and
  resolving type refs against the *owning* module's typespace, not the root's.
  Each nested module also has its own `ExplicitNames`, so canonical-name lookup
  has to be per-module too.
- **Codegen naming:** `.` is not legal in a GDScript identifier, so
  `lib.lib_data` needs a mangling scheme (TypeScript went with a `Lib_LibData`
  row type under a `lib/` directory). Whatever is picked has to compose with the
  existing native-member and keyword escaping, and stay collision-free against a
  root table that happens to be named `lib_lib_data`.
- **Db facade shape:** flat (`db.lib_lib_data`) or nested (`db.lib.lib_data`).
  Nested reads better and matches the server's model; flat is a smaller change.
- **Call/subscribe paths:** these need the dotted name verbatim, so the mangled
  GDScript identifier and the wire name must be kept as separate fields, exactly
  as `source_name` vs `canonical_name` already are.
- **Visibility:** the TypeScript client codegen exports only *public* submodule
  tables and non-private reducers/procedures. Ours would need the same filter.
- **Not client concerns:** submodule HTTP route registrations are ignored by the
  server itself (only the root module's routes are used).

## When to pick this up

When it lands in a tagged release **and** a real module needs it. Until then the
format can still change — it is unreleased, and only one server language can
produce it. Re-capture `vsubmod.json` with
[`integration-tests/schema_probe/`](../integration-tests/schema_probe/) before
building against it.

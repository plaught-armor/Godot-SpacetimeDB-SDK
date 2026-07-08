# Blackholio server (vendored)

Rust server module for the [Blackholio example client](../godot-client/EXAMPLE.md).
This is third-party code, vendored into the SDK repo so the example has a
reproducible, version-matched server to test against.

## Origin & license

Vendored from the SpacetimeDB monorepo, `demo/Blackholio/server-rust`
(commit `353557cede4dd8cab1dd0a31f93677e175609bda`). Copyright Clockwork Labs,
Inc; Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The source is unmodified. The **only** local change is the dependency pin in
`Cargo.toml`:

```toml
spacetimedb = "2.5.0"
```

## Why vendored instead of cloning upstream

Blackholio's upstream `master` targets SpacetimeDB `master` and uses newer macro
syntax (`name =` table attribute, bare `ctx.sender`). Force-porting it to a
released CLI compiles but **breaks gameplay** — `enter_game` rolls back, no
circles spawn. Pinning to the released `2.5.0` crate here avoids the macro
churn and matches the CLI this SDK is tested with (2.2.0–2.7.0), keeping the
generated client bindings aligned.

## Publish & run

Start a local SpacetimeDB first (`spacetime start --data-dir <dir>`), then:

```sh
./publish.sh   # spacetime publish -s local blackholio --delete-data -y
./logs.sh      # tail module logs
```

## Updating the vendored copy

1. Re-copy `src/` from the monorepo `demo/Blackholio/server-rust` at the target commit.
2. Re-apply the `spacetimedb = "<tested-version>"` pin in `Cargo.toml`.
3. Update the commit hash in `NOTICE` and this README.
4. Republish, then regenerate client bindings via the Godot SpacetimeDB dock if
   the schema changed (review the golden diff per `CONTRIBUTING.md`).

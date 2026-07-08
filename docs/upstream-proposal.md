# Upstream PR plan — GDScript Blackholio client (SpacetimeDB issue #4830)

> **DEPRECATED — outcome reached. Kept for historical record only.**
>
> The PR was opened and **closed** by a maintainer:
> [clockworklabs/SpacetimeDB#5453](https://github.com/clockworklabs/SpacetimeDB/pull/5453).
> Reason was policy, not code quality: the demo depends on a *community* Godot SDK
> rather than an official SpacetimeDB SDK, so it belongs alongside that SDK — i.e.
> this repo — not in the official monorepo. The maintainer praised the
> implementation and left the door open to reopen, but no packaging change flips
> the "community vs official SDK" bit; only clockworklabs adopting an official
> GDScript SDK would.
>
> The demo now lives here permanently ([`godot-client/`](../godot-client/),
> [`EXAMPLE.md`](../godot-client/EXAMPLE.md)). The plan below is left unedited as a
> record of the attempt.

Concrete checklist for contributing our GDScript Blackholio client to
`clockworklabs/SpacetimeDB`, modeled on the closed PR #3128 and targeting the open
tracking issue.

## Context (why this is wanted)

- **Issue #4830 — "Add Godot client support for Blackholio" — is OPEN.** It tracks
  *reimplementing* PR #3128 on current `master`. The merged C# `client-godot`
  (#5030) did **not** close it, so the GDScript client is still wanted.
- **PR #3128** (closed) added a GDScript client (Godot 4.4.1, compatibility-mode
  for web/websocket) using the flametime Godot SDK — the SDK our fork derives from.
  It was closed only because *"the Godot SDK [wasn't] stable [enough]"* and the PR
  went *"too far out of date to merge directly… reimplement on master."* Our fork
  is now exactly that: current with SpacetimeDB 2.6.0, hardened, tested.
- We have already commented on #4830 offering this.

## The standard-Godot gap (the pitch)

The merged `client-godot` is **C#**, so it needs the **Godot .NET (Mono)** build.
Users on **standard Godot** (no .NET — the default download, the larger audience)
have no SpacetimeDB path. A GDScript client + compatibility renderer fills that gap
and enables **web/websocket** export.

## Structure — follow the #3128 model (vendor the SDK in the client)

#3128 did **not** add to `sdks/`; it vendored the addon inside the client dir.
That's the accepted pattern — so we do the same. `client-godot` is taken (C#), so:

```
demo/Blackholio/client-godot-gdscript/
├── project.godot
├── main.tscn
├── scripts/                     # main.gd, entity_node.gd, starfield.gd, food_field.gd, ui/
├── shaders/                     # food.gdshader
├── addons/SpacetimeDB/          # the SDK, vendored (core, codegen, core_types, …)
├── spacetime_bindings/          # bindings codegen'd from the blackholio schema
└── README / notes
```

## Checklist

- [ ] **Render method → GL Compatibility.** Our project is `"Mobile"` (Vulkan, no
      web). #3128 and the merged C# client both use `"GL Compatibility"`. Switch for
      web/websocket export + precedent.
- [ ] **Assemble the client dir** as above: copy the addon + bindings + scripts +
      scenes into `client-godot-gdscript/`. Keep it self-contained (no external
      path deps).
- [ ] **CLA.** All commit authors must sign (CLA Assistant gate; #3128 shows it).
      Squash so the Claude co-author trailer doesn't add an unsigned committer.
- [ ] **License / attribution.** Repo is BSL 1.1; contributed code becomes BSL
      there. Preserve the flametime MIT attribution (LICENSE / NOTICE) and state the
      fork lineage. Expect a provenance check.
- [ ] **PR body** (fill `pull_request_template.md`): reference #4830 and #3128,
      "reimplemented on master, SDK current with 2.6.0, parity with the C# client,
      compatibility renderer for web." API/ABI breaking = none. Complexity ~2.
- [ ] **CI.** `ci.yml` must pass; it runs the C# client via dotnet. A GDScript
      client needs a **headless standard-Godot runner** in CI. We have a
      self-asserting suite (`extends SceneTree`, exit code = failures) + live
      integration tests (e.g. the reconnect/identity check) to mirror the C#
      client's play-mode tests. Confirm with maintainers how they want this wired.
- [ ] **Docs.** Add `client-godot-gdscript/` to the Blackholio `README.md`
      structure list (note: it currently omits even the existing C# `client-godot`)
      and a short run section (`F5` in standard Godot 4.x); note it in `DEVELOP.md`.
- [ ] **Target the right base branch** (`check-pr-base.yml`); pass CODEOWNERS
      review, merge labels (`check-merge-labels.yml`), `pr_approval_check.yml`.

## Parity status (what's already done)

Feature parity with the C# `client-godot`, verified against SpacetimeDB 2.6.0:
connect/subscribe, enter / split / suicide / respawn, mass-weighted camera +
upstream zoom/speed, leaderboard, consume animation (chase consumer), token
persistence + auto-rejoin, upstream color palette, crisp screen-space labels,
starfield, status panel, grow-in, and **GPU-instanced food** (MultiMesh + SDF
shader — one draw call). Bindings codegen from the schema.

## Status on #4830 — questions already asked, awaiting maintainer reply

Posted on #4830 (2026-06-16), no maintainer response yet. Asked:

1. Accept a GDScript client as a separate dir? Preferred naming/layout?
2. AI-assistance disclosure policy? (Disclosed upfront: built with AI assistance,
   reviewed/tested/maintained by us; we maintain the SDK it depends on.)
3. Bundle the SDK addon, or reference it as a dependency?

**Next action: wait for the maintainer reply** — don't open the PR until they
answer (esp. #1 layout and #3 bundle-vs-dependency, which decide the structure
above). Still-open for them: CI runner for headless Godot, and the BSL/flametime
attribution under their CLA.

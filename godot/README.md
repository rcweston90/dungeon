# Dungeon Forge — Godot 4 port

A faithful GDScript port of the Three.js prototype in [`../index.html`](../index.html):
a deterministic procedural dungeon generator (pure data) plus a `MultiMesh`
renderer, control panel, automatic acceptance tests, and an optional staged
build animation.

## Requirements

- **Godot 4.3+** (Forward+ renderer). No C#, no extensions — pure GDScript.

## Run

1. Open Godot, **Import** this `godot/` folder (select `project.godot`).
2. Press **F5** (Play). The main scene builds the whole thing in code.
3. Acceptance-test results print to the **Output** panel and show in the UI panel.

## Structure

| File | Role |
|------|------|
| `scripts/dungeon_rng.gd` | mulberry32 PRNG (bit-for-bit port, 32-bit `imul` emulated) |
| `scripts/dungeon_gen.gd` | Pure-data pipeline: scatter → Delaunay/MST/loops → semantics → carve → rasterize → BFS → decorate. `DungeonGen.generate(params) -> Dictionary` |
| `scripts/dungeon_renderer.gd` | `Node3D` owning 9 `MultiMeshInstance3D` (≈9 draw calls), ≤12 shadowless `OmniLight3D`, overlays, heatmap, flicker, build animation |
| `scripts/dungeon_tests.gd` | Acceptance tests + FNV-1a checksum |
| `scripts/main.gd` | Ortho iso camera, input, code-built UI, regenerate loop |
| `scenes/main.tscn` | Trivial root wired to `main.gd` |

## Separation of concerns

`DungeonGen` has **zero** rendering references — it returns typed arrays
(`PackedByteArray` grid, `PackedInt32Array` BFS field) and plain Dictionaries.
That's the layer you hook game logic into (spawning, pathfinding, save/load).
`DungeonRenderer` is the only file that touches Godot render objects; freeing
the node disposes everything.

## Determinism & timing notes

- Same `seed` + params reproduce the same dungeon (verified by the checksum
  test). The mulberry32 port also matches the JS stream, so a given seed yields
  the same layout in both the web prototype and this project.
- GDScript is interpreted, so 60-room generation is slower than the web's 50 ms
  target. The timing test reports the measured value against a GDScript-realistic
  budget. Moving `DungeonGen` to a `Thread`, C#, or a GDExtension recovers
  web-scale numbers if you need them.

## Controls

Drag to pan · mouse wheel to zoom · seed box + 🎲 · sliders for rooms /
loop chance / decor · overlay toggles (Delaunay / MST / loops / critical path /
difficulty heatmap) · animate-build toggle (takes effect on next Generate).

## Validation

This project was compiled and run against **Godot 4.4 stable** (headless) before
delivery. Results:

- Full scene loads with **zero script errors** (generator, renderer, lights,
  overlays, UI, and the per-frame flicker loop all execute).
- **All 8 acceptance tests pass** for seed 42 (default), including the
  determinism checksum (`3fedae1d`).
- A headless sweep of **300 dungeons** (60 seeds × room counts 10–80) passes
  every invariant — 100% reachability, cyclomatic ≥ 1, entrance degree 1 and
  not boss-adjacent, and no prop/spawn on a doorway/wall/void cell.

Re-run the sweep yourself:

```
godot --headless --path godot --script tools/headless_check.gd
```

(`tools/headless_check.gd` is a `SceneTree` harness — generator + tests only,
no rendering.)

### Performance

Interpreted GDScript is much slower than the web build's V8: a cold 60-room
generation is ~300 ms here vs the 50 ms web target (the default 42-room gen is
well under 100 ms, fine for interactive slider-dragging). The `min()/max()`
Variant-inference sites are explicitly typed and the separation hot loop was
moved onto flat `PackedFloat64Array`s (a ~2× speedup, verified bit-for-bit
identical by checksum). If you need web-scale generation, move `DungeonGen` to
a `Thread`, C#, or a GDExtension.

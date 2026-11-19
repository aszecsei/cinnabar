# Positions and transforms

World positions are fixed-point `i64` values, and transforms form a hierarchy that propagation writes. This document explains both and where positions become floating point.

**In this document:** [Positions](#positions) · [Transforms](#transforms)

## Positions

World positions are fixed-point: `World_Position` holds three `i64` values in units of 2^-24 m (Q39.24).

- **Resolution:** 2^-24 m (about 60 nm), the same everywhere in the world. There is no loss of precision far from the origin, and no origin rebasing.
- **Range:** ±2^38 m (about 1.8 AU) on each axis. In this range, the difference of two positions always fits in an `i64`.
- **Two operations only.** `position_sub(a, b)` gives an `[3]f32` delta. `position_offset(p, delta)` adds an `[3]f32` delta. `World_Position` is a struct, so Odin does not allow other arithmetic on it. Use `position_lerp` for interpolation.
- **Rounding:** `position_sub` converts the difference to `f32` once, so the result is correctly rounded. `position_offset` rounds the delta to the nearest unit. Truncation would move every step toward zero.
- **Meters as `f64`** (`position_from_meters`, `position_to_meters`) are only for authoring, display and tests. Above 2^29 m from the origin, an `f64` cannot hold every position.
- **Spatial cells:** shift the raw value right to get an exact integer cell key.

The alternative designs, and why they were not taken: `f64` positions lose precision past 2^29 m and still need camera-relative conversion for the GPU; `f32` with origin rebasing moves every entity when the origin moves and makes multiplayer and replays depend on each client's origin; a fixed-point `i64` has one exact answer everywhere, and the only conversion to floating point is the camera-relative delta that the GPU needs anyway.

### Where positions go

| Consumer | What it sees |
|---|---|
| Rendering | Render extraction gives poses relative to the camera's position. The GPU sees only camera-relative `f32` matrices. See [Render extraction](render-extraction.md#render-extraction). |
| Physics | Simulates in `f64` offsets from a `World_Position` anchor for each physics world, with `position_sub_f64` and `position_offset_f64`. See [Physics: Positions and precision](../physics/design.md#positions-and-precision). |
| Scripts | A `WorldPosition` userdata that supports only `-` (gives a `vector`) and `+ vector`. Entity helpers such as `entity:offset_to(other)` and `entity:move(v)` do not allocate. Scripts never see raw values: a Luau number is an `f64`. |
| Cooked scenes, editor link | Raw `i64` values. The editor shows meters, and sends a move as a delta or as raw values. |

## Transforms

- `Transform` is the world-space pose: a `World_Position`, a rotation and a scale. Every placed entity has one.
- For a root entity, `Transform` is the source of truth. A child has `Parent` and `Local_Transform`. Its `Local_Transform` holds an `f32` offset, a rotation and a scale relative to the parent, and it is the source of truth. Transform propagation writes the child's `Transform`.
- Engine components have small explicit IDs (`TRANSFORM_ID` and others). The game registers them with `register_engine_components` in its registration procedure.
- **Change `Parent` only with `add`, `remove` or their commands**, so the world knows that the hierarchy changed. A write through `get` or `get_write` does not reach the child lists, so scripts can only read `Parent`. The world logs a cycle, or a hierarchy deeper than 64 levels, and does not propagate it.
- **Child lists:** each entity slot has a first child, and each child has a previous and a next sibling. `add_raw`, `remove_raw` and despawn keep them up to date, so `apply` keeps them up to date too. `ecs.children_iter(w, e)` and `ecs.children_next` walk an entity's children, the most recently parented first. Make no structural change while the walk runs.
- **Orphans:** a child whose parent is not alive is in the world's orphan list. A despawned parent moves its children there, and a `Parent` that names a dead or stale handle puts its entity there. A stale handle never links a child to the new entity in its slot.
- **Despawning a parent despawns its descendants.** To keep a child, remove its `Parent` first. Despawn walks the child lists, so it costs the subtree, not the world. The immediate `despawn` takes the orphans at once. `apply` takes them at the end, so commands for the children in the same `apply` still run first: a child that a command reparents, or whose `Parent` it removes, leaves the orphan list and stays alive.
- The world keeps every child sorted by depth, and sorts again only when the hierarchy changes. Propagation runs one level at a time. The entities in one level are processed in parallel.
- Propagation runs after each fixed tick and again after the `Late` stage.
- Propagation includes `Inactive` entities, so an entity is in the right place when it becomes active.

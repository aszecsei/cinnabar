# World streaming

How a world's scenes load and unload around the camera, in `lib/engine/streaming` and `lib/engine/scene`. A world asset lists scenes with bounds and distances. A policy loads the scenes near the camera and unloads the far ones, a few entities each frame. Read [Scenes](scenes.md) first.

**In this document:** [The world](#the-world) · [World streamer](#world-streamer) · [The policy](#the-policy) · [Loading in stages](#loading-in-stages) · [Budgets](#budgets) · [Events](#events) · [Failures](#failures) · [Limits](#limits)

## The world

A world is an asset of the `world` kind. It lists scenes. Each scene has bounds (a box in meters), a load distance and an unload distance, or it is persistent. The text, the blob and the cooker's checks are in [Content: Worlds](../content/kinds/worlds.md). A world has no grid form: each scene has its own bounds.

The policy reads the blob's `World_Scene_Record`s (`lib/engine/asset/format/world.odin`) in blob order. A world has at most `MAX_WORLD_SCENES` (1024) scenes.

## World streamer

Two components in `lib/engine/streaming` (the `streaming` package) control the policy.

| Component | ID | What it does |
|---|---|---|
| `World_Streamer` | 144 | Names the world (`world`, an asset field) that streams. It also receives the [events](#events) as script events. |
| `Stream_Source` | 145 | Marks an entity that scenes load around, such as the player. The position is the entity's `Transform`. It has no fields. |

- **Put `World_Streamer` on an entity of a scene that stays loaded**, for example a persistent scene. If its entity is despawned, the policy unloads every scene that it loaded.
- **The first streamer wins.** When more than one entity has `World_Streamer`, the first that `ecs.collect` finds selects the world. The policy logs one warning.
- **The camera is always a source.** The sources are the camera's position and each `Stream_Source` entity with a `Transform`.
- **A new `world` value** unloads the scenes of the old world and loads the new world's blob.

## The policy

`streaming.update` runs once a frame. It decides which scenes load and unload. `scene.begin_load` and `scene.advance_loads` do the loads ([Loading in stages](#loading-in-stages)).

**Distance.** The distance of a scene is the distance in meters from a source to the scene's bounds, and 0 inside them. With several sources, a scene uses the smallest distance (`scene_distance`).

**Load and unload.**

- A scene that is out begins to load when its distance is at most its `load_distance`.
- A scene that is in unloads when its distance is more than its `unload_distance`.
- **The hysteresis gap** is the space between the two distances. A scene in the gap keeps its state. A source that moves back and forth at the edge of a scene does not load and unload it again. The cooker's default `unload_distance` is `load_distance` times `DEFAULT_UNLOAD_FACTOR` (1.25). The policy treats an `unload_distance` below `load_distance` as equal to it.
- **Persistent scenes** (the `.Persistent` flag) begin to load at once, with or without sources. They never unload by distance. They unload only with their streamer.

**Priority.** Of the scenes that want to load, persistent scenes go first, then the nearest. A scene that is loading advances in the same order.

**Limits on loads.** At most `MAX_SCENE_LOADS` (2) streamed scenes are not ready at once. At most `MAX_STREAMED_SCENES` (`core.MAX_SCENE_MEMORY` - 8 = 56) scenes are in, which leaves memory for scenes that scripts and the game load.

**A frame's order of work.** `game.stream_scenes` runs after the queued `Scene.load` and `Scene.unload` requests and before the systems. Its steps:

1. Collect the sources: the camera, then the `Stream_Source` entities.
2. Ask physics for `loading_scenes` ([Budgets](#budgets)).
3. In `streaming.update`: find the streamer, load the world blob, and follow a blob that changed ([Failures](#failures)).
4. Mark a scene that something else unloaded as out.
5. Compute the distances, and unload the scenes past their unload distance.
6. Begin the loads that the distances ask for, in priority order.
7. Advance the scenes that are loading, within the [budgets](#budgets).
8. Run `forget_despawned` if a scene unloaded, send the [events](#events), and find the camera again.

**Special cases.**

- **Edit mode:** `stream_scenes` does nothing while the editor edits, as the world stands still then. The editor's preview shows which scenes would load from a position, and opens them ([Editor: World view](../editor/world-view.md#the-preview)).
- **No sources:** only the persistent scenes begin to load, and nothing unloads. Scenes that are loading go on loading. This happens when there is no camera and no `Stream_Source`.
- **No streamer or no world:** the policy does nothing.

## Loading in stages

A streamed scene loads across frames. `scene.begin_load` adds the scene to the table with its blob read started. Each frame, `scene.advance_loads` moves it on within the budget. The row's `stage` has the stage's data, in the scene's memory.

| Stage | What happens | Leaves when |
|---|---|---|
| `Reading` | The host reads the blob ([Blobs and loading: Reads across frames](../content/blobs-and-loading.md#reads-across-frames)). Each frame polls the read. | The read is done and the blob is a scene of this build. |
| `Spawning` | The loader spawns entities in blob order, each with `Loading`. | Every entity record has an entity (up to `SCENE_SPAWNS_PER_FRAME` each frame). |
| `Filling` | The loader gives each entity its components, its parent and its `Disabled`. | Every entity is filled (up to `SCENE_FILLS_PER_FRAME` each frame). |
| `Settling` | The scene waits for its physics bodies. | The scene's number is not in `bodies_pending`, checked a call after `Filling` ended at the soonest. |
| `Ready` | The scene is shown. | A scene stays `Ready` until it unloads. |

A stage goes only to the next stage (`change_stage`). A scene that `add_scene` added starts in `Ready`.

- **`ecs.Loading`** (component 10) holds the scene's number. It hides an entity as `Disabled` does: the entity is `Inactive`, so queries, rendering and physics skip it ([ECS: Queries](ecs.md#queries)). The loader calls `ecs.update_activity` after each batch of spawns and fills, so nothing sees a new entity before it is hidden.
- **The reveal** happens when a scene is in `Settling` and has no bodies pending. The loader:
  1. Removes `Loading` from every entity of the scene, and updates the activity.
  2. Settles the entities, as `add_entities` does.
  3. Attaches the behaviours of the entities. They wake in the next script phase.
  4. Moves the scene to `Ready`.
- **Behaviours attach at `Ready`.** A hidden entity has no behaviours, so no script runs on a scene that is not ready.
- **Physics bodies** of hidden entities come a few at a time, disabled, and `check_bodies` enables them when `Loading` goes ([Physics: Components](../physics/design.md#components)).
- **Unload while loading.** `scene.unload_scene` on a scene that is `Reading` ends the host read (`end_read`). It then despawns what the scene made and frees its memory, as for any scene. The policy does this when a source moves away from a scene that is still loading.
- **A scene that cannot load** is unloaded with what it made ([Failures](#failures)).
- **Bundles.** In a release, each chunk of a world has a bundle of its own. `scene.begin_load` holds the chunk's bundle, which it opens if it is not already open. `scene.unload_scene` releases the hold, and the bundle closes when nothing loaded from it is in use ([Blobs and loading: Bundles](../content/blobs-and-loading.md#bundles)).

A scene joins the world's scenes when it begins to load, and its navmeshes load with it ([Navigation: Loading](../ai/navigation.md#loading)). Paths cross between two streamed scenes' navmeshes where their volumes meet ([Navigation: Seams](../ai/navigation.md#seams)).

## Budgets

The work of a frame is limited, so a big scene does not stall the frame.

| Constant | Value | What it limits |
|---|---|---|
| `SCENE_SPAWNS_PER_FRAME` | 1024 | Entities that `advance_loads` spawns in a frame, for all the scenes that load. |
| `SCENE_FILLS_PER_FRAME` | 128 | Entities that `advance_loads` fills in a frame, for all the scenes that load. |
| `LOADING_BODIES_PER_SYNC` | 32 | Physics bodies that one sync makes for hidden entities of loading scenes. |
| `MAX_SCENE_LOADS` | 2 | Streamed scenes that are not ready at once. |
| `MAX_STREAMED_SCENES` | 56 | Scenes that the policy keeps in at once (`core.MAX_SCENE_MEMORY` - 8). |

- **The budgets are shared.** The scenes that load share one `Load_Budget` for a frame, in priority order: the first scene uses what it needs, and the rest get what is left.
- **A scene waits for its bodies.** `physics.loading_scenes` lists the scenes that have a hidden entity with a collider or a rigid body and no body yet. A scene stays in `Settling` while its number is in that list. It is empty without a physics world or a backend that makes bodies, so a scene never waits for bodies that cannot come.
- **The Resource Monitor** shows the last frame's work while a scene loads ([Editor: Resource Monitor](../editor/shell-and-panels.md#resource-monitor)): `Scenes loading`, `Scene entities spawned` and `Scene entities filled`. They come from `streaming.stats` through `Game_Stats`.

## Events

The policy records what happened to each scene in a frame. `game.stream_scenes` sends them in order.

**In Odin,** `streaming.events` gives the last update's `Stream_Event`s: a `kind` (`Loading`, `Ready`, `Unloaded` or `Failed`), the scene's `number` and its `scene` GUID. They are valid until the next update. For a scene that did not begin to load, `number` is 0.

**In scripts,** the streamer entity's behaviours get each event as a script event, in the next script phase:

| Event | When |
|---|---|
| `on_scene_loading(number, scene)` | The scene began to load. |
| `on_scene_ready(number, scene)` | The scene is shown. |
| `on_scene_unloaded(number, scene)` | The scene unloaded: by distance, with its streamer, or because something else unloaded it. |
| `on_scene_failed(number, scene)` | The scene did not load. `number` is 0 when the load did not begin. |

`number` is the scene's number and `scene` is an `Asset`. `Scene.state(number)` returns `"loading"`, `"ready"`, or nil for a number that is not loaded ([Scenes: Scripts](scenes.md#scripts)).

```luau
local Streamer = Behaviour.define("Streamer", { world = Field.asset() })

function Streamer:on_scene_loading(number, scene)
	print("loading", number, Scene.state(number)) -- loading 2147483648 loading
end

function Streamer:on_scene_ready(number, scene)
	self.ready = (self.ready or 0) + 1
end

return Streamer
```

The events go to the streamer's behaviours only, as the streamer is the entity that has `World_Streamer`.

## Failures

A scene fails when `begin_load` refuses it, its blob cannot be read, it is not a scene blob of this build, or an entity record is damaged. The loader unloads what it made and logs an error.

- **The slot is failed.** A failed scene is not tried again until the world blob changes. The slot keeps the blob's version, and a new version (a recook while the game runs) makes it out again.
- **A world that does not load** (missing, or not a world blob of this build) is logged once. It is tried again when the streamer names another world.
- **A world blob that changed** keeps its loaded scenes by record index. A scene whose record is gone unloads.

## Limits

- **Settle, behaviour attach and the removal of `Loading`** at the reveal are not budgeted. They run in one frame for the whole scene.
- **Characters and joints** have no loading budget. Only rigid bodies and colliders are made a few at a time.
- **Scene memory:** at most `core.MAX_SCENE_MEMORY` (64) scenes are loaded at once, and the policy keeps `MAX_STREAMED_SCENES` (56) of them.
- **Streaming stands still in Edit mode.** The editor does not edit or save streamed scenes. In Play, the World editor shows the scenes that the game has in ([Editor: World view](../editor/world-view.md#play)).
- **One streamer** selects one world. A second `World_Streamer` is ignored.

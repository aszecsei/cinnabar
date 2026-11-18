# Scenes

How scenes come into the world and leave it, in `lib/engine/scene`. A running world can hold several scenes. The game loads a scene beside the scenes that are already loaded, and it unloads one scene while the others stay. Read [ECS](ecs.md) first. The scene format and the editor's scenes are in [Editor: Document and scenes](../editor/document-and-scenes.md#scenes).

**In this document:** [The level](#the-level) · [Numbers](#numbers) · [Loading](#loading) · [Unloading](#unloading) · [Ownership](#ownership) · [Scene IDs](#scene-ids) · [The systems](#the-systems) · [Streaming](#streaming) · [Loading in stages](#loading-in-stages) · [References across scenes](#references-across-scenes) · [Scripts](#scripts) · [Limits](#limits)

## The level

The level is all of the loaded scenes. `scene.Scenes` is the table of these scenes, and it lives beside the world in `Game_State` (`Game.scenes`). Each row has the scene's number, its GUID, and the blob that loaded it.

| Procedure | What it does |
|---|---|
| `scene.load(w, scripts, s, scenes)` / `scene.load_asset(..., guid, scenes)` | Unloads the level, then adds the scene as scene 0. |
| `scene.unload_level(w, scenes)` | Despawns every entity, forgets every scene, releases their blobs, and unloads the level ([Core: Level memory](../core/jobs-and-memory.md#level-memory)). |
| `scene.add_scene(w, scripts, scenes, s, number?)` / `scene.add_scene_asset(..., guid, number?)` | Adds one scene beside the scenes that are loaded. Does not unload the level. Returns the scene's number. |
| `scene.unload_scene(w, scenes, number)` | Despawns one scene and the entities that it owns. The other scenes stay. |

All of these run between frames, outside the script phase. A script asks for a load or an unload, and the game applies the request at the start of the next frame ([Streaming](#streaming)).

## Numbers

Each loaded scene has a number. The number is stored in `Scene_Entity.scene` on each entity of the scene.

- **0** is the game's own scene, which `scene.load` loads.
- **1 and up** are the editor's scenes ([Editor: Several scenes](../editor/document-and-scenes.md#several-scenes)).
- **`FIRST_RUNTIME_SCENE` (2³¹) and up** are the scenes that the game streams in. If `add_scene` gets no number, it gives the next free number from this range. Because the range starts at 2³¹, a streamed scene can never get one of the editor's numbers.

A number is used only once in a level. `add_scene` refuses a number that is loaded and logs a warning. `reserve_number` takes the next number before the scene loads, which lets a request return the number at once. When the level unloads, the numbers start again at `FIRST_RUNTIME_SCENE`.

## Loading

`add_scene` adds the scene's entities with `add_entities`, with the scene's number and the scene's own ID map:

- A local reference and a parent resolve in the scene alone. Two scenes can have the same scene IDs, for example two copies of a file. A reference to another scene binds when that scene is `Ready`, in `add_scene` and in a staged load ([References across scenes](#references-across-scenes)).
- The behaviours wake in the next script phase, as with `scene.load`.
- The scene's GUID joins the world's scenes (`ecs.world_scenes`), and the navmeshes of that scene load ([Navigation: Loading](../ai/navigation.md#loading)).

`add_scene_asset` keeps the scene's blob loaded until the scene or the level unloads. If the blob does not load, or if it is not a scene of this build, the world does not change. `scene.load_asset` also reads the blob before it unloads the level, so if a load fails, the old level stays.

## Unloading

`unload_scene(w, scenes, number)`:

1. Finds each entity of the scene, and each entity that the scene owns ([Ownership](#ownership)), including inactive entities.
2. Despawns them with `ecs.despawn_many`. Their children go too. `despawn_many` searches for the descendants once, not once for each entity.
3. Clears the scene's ID map, removes the scene from the table, and releases the scene's blob.
4. Takes the scene's GUID out of the world's scenes, so its navmeshes unload.

A link that is bound to the scene goes to 0, or binds again to another scene with the same GUID ([References across scenes](#references-across-scenes)). The links that the scene holds go with its memory. The other scenes' entities, their local references and their parents do not change. An entity handle into the unloaded scene is no longer alive (`ecs.is_alive` returns false), so a stored reference to it fails safely. The scene's own memory and its GPU resources are freed, and the other scenes' memory stays ([Core: Scene memory](../core/jobs-and-memory.md#scene-memory)).

## Ownership

A scene owns its own entities, their children, and the entities that its entities spawn:

- **Children** go with their parent through `Parent`, as with every despawn.
- **Spawns:** `scene.Scene_Owned{scene}` (component 9) marks an entity that belongs to a scene but is not in the scene's file. When a behaviour calls `World.spawn` or `World.spawn(prefab)`, the new root gets `Scene_Owned` with the scene of the behaviour's entity. This is the entity's `Scene_Entity.scene`, or its own `Scene_Owned.scene`, so a spawn of a spawn belongs to the same scene. The script runtime calls this hook through `script.set_spawned_hook`, which `scene.register_scripts` sets, with `script.calling_entity`, the entity whose callback or coroutine runs.
- **From Odin**, `scene.spawn_prefab(..., owner = number)` gives the root `Scene_Owned`.
- **Global spawns:** an entity that the main script, a script action or frame code spawns has no owner. It stays until something despawns it.

`scene.scene_of(w, entity)` returns the scene that an entity belongs to. `Scene_Owned` is derived like `Scene_Entity`: a scene file cannot set it, and the editor shows it read-only.

## Scene IDs

`scene.find(scenes, w, number, id)` resolves a scene ID in one scene. The editor's operations use the same lookup. Each loaded scene's map from scene ID to entity is in the scene's memory, and goes with the scene. The map of a scene that came in without `add_scene` is in the Level arena. If an entry is stale (the entity is gone, or its slot holds another entity), `find` builds every map again from each entity's `Scene_Entity`. A scene that came into the world without `add_scene` is found in the same way. `scene.key_of(w, entity)` returns an entity's scene number and scene ID.

## The systems

Some systems keep data by entity outside the world. These systems drop the entities of an unloaded scene in the same frame:

| System | How |
|---|---|
| Physics bodies, characters, joints | `physics.forget_despawned` destroys them at once, so raycasts stop hitting them. This also works while the game is paused and no tick runs. |
| Nav paths and crowd agents | `nav.forget_despawned` frees their slots. |
| AI agents | `ai.forget_despawned` frees their slots, which stops their actions, and drops the writes that waited for them. |
| Behaviours | `script.forget_despawned` ends them, with `on_disable` and `on_destroy`. |
| Audio sources, renderer items (GPU scene, skins, particles, probes), UI documents | Their own sweeps already drop entities that are not seen in a frame. |

`game.forget_despawned(g)` runs the first four sweeps. The game runs it after it applies an unload. Odin code that calls `scene.unload_scene` directly between frames calls it too. Residency (the renderer's GPU assets) is keyed by GUID, not by entity. A scene that loads again uses the entries that its first load made, so a scene that loads, unloads and loads again adds none.

## Streaming

`game.load_scene(g, guid) -> number` and `game.unload_scene(g, number)` queue a request. At the start of each frame, after the `begin_frame` hook and before the systems prepare, the game:

1. Applies the queued requests, in order.
2. Runs `forget_despawned` if a scene unloaded.
3. Finds the camera again.

A request that `begin_frame` makes applies in the same frame. A request that a script makes applies in the next frame. A load that fails logs an error, and its number stays unused.

A `World_Streamer` loads and unloads the scenes of a world by itself ([World streaming](streaming.md)). Its scenes load in stages.

`game.set_sublevel(g, name, active)` queues a change of a sublevel with these requests. A scene loads with the parts of its active sublevels, each a scene of its own ([Sublevels](sublevels.md)).

## Loading in stages

`scene.begin_load(w, scenes, guid, number?)` adds a scene that loads across frames, and `scene.advance_loads` moves it on within a budget. The scene goes through `Reading`, `Spawning`, `Filling` and `Settling` to `Ready`. Its entities have `ecs.Loading`, so they stay hidden until it is `Ready`, and its behaviours attach then. `scene.stage_of(scenes, number)` gives the stage. `scene.loaded_scenes` lists the scenes that are loading with the others. Call both procedures between frames, outside the script phase. The stages, the budgets and the events are in [World streaming](streaming.md#loading-in-stages).

## References across scenes

A field names an entity of another scene by the scene's GUID and the entity's scene ID (`@<guid>/<id>` in the scene file, see [Editor: Scenes](../editor/document-and-scenes.md#scenes)). `lib/engine/scene/links.odin` holds these as links, and is the only code that writes them.

- **A link** is a `Scene_Link` in the row of the scene that holds the field. It has the field's slot (a component field, found again by the hash of its name at each write, or a behaviour field), the target's GUID and scene ID, and a state: `Link_Waiting` or `Link_Bound`. It is in the holder's scene memory, so it goes with the holder.
- **Loading:** a reference to the holder's own GUID is local. A reference to another scene binds to the first `Ready` scene with that GUID, and writes that scene's entity into the field. If no such scene is `Ready`, the field is 0 and the link waits. A scene that still loads is not `Ready`, and its entities do not count.
- **When a scene becomes ready,** `add_scene` and the staged load (after the scene is revealed) bind the links that wait for its GUID. A link whose entity is not in the scene logs a warning and ends.
- **When a scene unloads,** each link that is bound to it binds again to the same ID in another `Ready` scene with the same GUID. If there is none, the field is 0 and the link waits.
- **A write is conditional.** A link writes its field only while the field holds what the link wrote before. A script or an edit that has written the field since keeps its value, and the link ends. The links of a component end when the component is replaced or removed, and the links of a behaviour end when the behaviour or its entity goes.
- **Pending:** `scene.pending(s, w, entity, component, field)` and `scene.pending_behaviour(s, w, entity, script, field)` return the target's GUID and true while the link waits, and false otherwise. A field that has no link gives false.
- **Parents** stay in one scene. The text parsers refuse a parent in another scene, and the editor's link drops an `Edit_Parent` to another scene with a warning.

**Known limits:**

- A script that writes nil to a field that waits does not end the wait: the link overwrites the nil when its scene is ready.
- A runtime `set_parent` across scenes is not refused.
- Undo of a destroy in the editor makes a new entity. A link that was bound to the old one stays dead, as a reference in the same scene does.
- Two loaded scenes with one GUID: a link binds to the first one that loaded.

## Scripts

| Binding | What it does |
|---|---|
| `Scene.load(scene: Asset) -> number` | Asks for the scene to load beside the others. Returns the number that it will have. The scene loads at the start of the next frame. |
| `Scene.unload(number)` | Asks for the scene with the number to unload, with what it owns, at the start of the next frame. |
| `Scene.of(entity) -> number?` | The scene that the entity belongs to, or nil for an entity that the game spawned. For an entity of a sublevel's part, it is the part's number. |
| `Scene.base(number) -> number?` | The base of a sublevel's part, the number itself for any other scene, or nil for a number that is not loaded ([Sublevels: Ownership](sublevels.md#ownership)). |
| `Scene.pending(behaviour, field) -> Asset?` | The scene that a behaviour's entity field waits for, as an `Asset` that `Scene.load` takes. It is nil when the field names no other scene, or when that scene is loaded. |
| `Scene.state(number) -> string?` | `"loading"` for a scene that is still loading (not yet shown), `"ready"` for one that is shown, and nil for a number that is not loaded. A scene that `Scene.load` asked for is `"ready"` once it loads. A part's number gives the part's own stage. |

The `Sublevel` library activates a scene's sublevels and reads their state ([Sublevels: Scripts](sublevels.md#scripts)).

```luau
local Portal = Behaviour.define("Portal", { next = Field.asset() })

function Portal:on_trigger_enter(other)
	self.loaded = Scene.load(self.next)
	-- The portal's own scene goes once the player is through.
	Scene.unload(Scene.of(self.entity))
end

return Portal
```

## Limits

- **Scene memory:** at most `core.MAX_SCENE_MEMORY` (128) scenes are loaded at once. Each part of a sublevel counts as a scene ([Sublevels: Scene memory](sublevels.md#scene-memory)). `add_scene` refuses one more and logs an error ([Core: Scene memory](../core/jobs-and-memory.md#scene-memory)).
- **Loads across frames** are only for the scenes that a `World_Streamer` loads, the parts of sublevels that become active, and Odin code that calls `scene.begin_load`. `add_scene` and `Scene.load` load a scene in one frame, from a blob that `asset.load` reads at once ([World streaming](streaming.md)).
- **The editor** does not edit or save streamed scenes. Its documents are its own scenes, numbered below `FIRST_RUNTIME_SCENE`. A load of its scenes unloads the level, and every streamed scene with it. A scene that it opens or closes beside the others is added or unloaded alone, with `add_scene` and `unload_scene` ([Editor: Several scenes](../editor/document-and-scenes.md#several-scenes)).

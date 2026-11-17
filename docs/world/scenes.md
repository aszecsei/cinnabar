# Scenes

How scenes come into the world and leave it, in `lib/engine/scene`. A running world can hold several scenes. The game loads a scene beside the scenes that are already loaded, and it unloads one scene while the others stay. Read [ECS](ecs.md) first. The scene format and the editor's scenes are in [Editor: Document and scenes](../editor/document-and-scenes.md#scenes).

**In this document:** [The level](#the-level) · [Numbers](#numbers) · [Loading](#loading) · [Unloading](#unloading) · [Ownership](#ownership) · [Scene IDs](#scene-ids) · [The systems](#the-systems) · [Streaming](#streaming) · [Loading in stages](#loading-in-stages) · [Scripts](#scripts) · [Limits](#limits)

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

- References and parents resolve only in the scene. Two scenes can have the same scene IDs, for example two copies of a file.
- The behaviours wake in the next script phase, as with `scene.load`.
- If the world has no scene, the scene's GUID becomes `World.scene`, and the navmeshes of that scene load ([Limits](#limits)).

`add_scene_asset` keeps the scene's blob loaded until the scene or the level unloads. If the blob does not load, or if it is not a scene of this build, the world does not change. `scene.load_asset` also reads the blob before it unloads the level, so if a load fails, the old level stays.

## Unloading

`unload_scene(w, scenes, number)`:

1. Finds each entity of the scene, and each entity that the scene owns ([Ownership](#ownership)), including inactive entities.
2. Despawns them with `ecs.despawn_many`. Their children go too. `despawn_many` searches for the descendants once, not once for each entity.
3. Clears the scene's ID map, removes the scene from the table, and releases the scene's blob.
4. If the scene's GUID is `World.scene`, gives `World.scene` to the next loaded scene, or clears it.

The other scenes' entities, their references and their parents do not change. An entity handle into the unloaded scene is no longer alive (`ecs.is_alive` returns false), so a stored reference to it fails safely. The scene's own memory and its GPU resources are freed, and the other scenes' memory stays ([Core: Scene memory](../core/jobs-and-memory.md#scene-memory)).

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

## Loading in stages

`scene.begin_load(w, scenes, guid, number?)` adds a scene that loads across frames, and `scene.advance_loads` moves it on within a budget. The scene goes through `Reading`, `Spawning`, `Filling` and `Settling` to `Ready`. Its entities have `ecs.Loading`, so they stay hidden until it is `Ready`, and its behaviours attach then. `scene.stage_of(scenes, number)` gives the stage. `scene.loaded_scenes` lists the scenes that are loading with the others. Call both procedures between frames, outside the script phase. The stages, the budgets and the events are in [World streaming](streaming.md#loading-in-stages).

## Scripts

| Binding | What it does |
|---|---|
| `Scene.load(scene: Asset) -> number` | Asks for the scene to load beside the others. Returns the number that it will have. The scene loads at the start of the next frame. |
| `Scene.unload(number)` | Asks for the scene with the number to unload, with what it owns, at the start of the next frame. |
| `Scene.of(entity) -> number?` | The scene that the entity belongs to, or nil for an entity that the game spawned. |
| `Scene.state(number) -> string?` | `"loading"` for a scene that is still loading (not yet shown), `"ready"` for one that is shown, and nil for a number that is not loaded. A scene that `Scene.load` asked for is `"ready"` once it loads. |

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

- **Navmeshes** follow `World.scene`, which is one scene: the first scene that loaded, or the next scene after it unloads ([Navigation](../ai/navigation.md#loading)).
- **Scene memory:** at most `core.MAX_SCENE_MEMORY` (64) scenes are loaded at once. `add_scene` refuses one more and logs an error ([Core: Scene memory](../core/jobs-and-memory.md#scene-memory)).
- **Loads across frames** are only for the scenes that a `World_Streamer` loads, and for Odin code that calls `scene.begin_load`. `add_scene` and `Scene.load` load a scene in one frame, from a blob that `asset.load` reads at once ([World streaming](streaming.md)).
- **The editor** does not edit or save streamed scenes. Its documents are its own scenes, numbered below `FIRST_RUNTIME_SCENE`. A load of its scenes unloads the level, and every streamed scene with it.

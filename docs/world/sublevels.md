# Sublevels

How the parts of a scene's sublevels load and unload in a running world, in `lib/engine/scene`, `lib/engine/streaming` and `lib/engine/game`. A sublevel is a named group of entities that the game activates and deactivates while the level runs, such as `night` or `boss_fight`. The cooker splits each scene into a base and one part for each of its sublevels ([Content: Scenes](../content/kinds/scenes.md#sublevels)). Read [Scenes](scenes.md) and [World streaming](streaming.md) first.

**In this document:** [The active set](#the-active-set) · [Parts are scenes](#parts-are-scenes) · [Activation](#activation) · [Ownership](#ownership) · [References](#references) · [Streaming](#streaming) · [Events](#events) · [Scene memory](#scene-memory) · [Known limits](#known-limits)

## The active set

The project's settings declare each sublevel, and say if it starts active: `sublevel.<name> = active` or `= inactive` ([Architecture: Project settings](../overview/architecture.md#project-settings)). `project.Settings.sublevels` keeps them in a fixed table of `format.MAX_SUBLEVELS` (32) names. A later line for a name wins.

The game keeps the active set in `Game.sublevels`, beside `Game.scenes`. The set belongs to the level. Each level starts it again from the settings, so it applies to every scene that loads: from `game.main_scene`, from `Scene.load`, and from a world's streaming.

Each sublevel has one state, `game.Sublevel_State`. `change_sublevel` is the only writer.

| State | Means |
|---|---|
| `Inactive` | Its parts are not loaded. |
| `Loading` | It is active, and some of its parts are not ready yet. |
| `Active` | It is active, and its parts of every loaded scene are ready. |
| `Failed` | It is active, and one of its parts did not load. |

A sublevel goes from `Inactive` to `Loading`, between `Loading`, `Active` and `Failed`, and from any of these to `Inactive`. It goes back to `Loading` when a scene that loads brings a part of it. A level's reset goes through the same writer, so each change has its event.

A sublevel that the settings declare while the level runs joins the set, inactive. One that they no longer declare stays until the next level.

| Procedure | What it does |
|---|---|
| `game.set_sublevel(g, name, active) -> bool` | Queues a change ([Activation](#activation)). It is false for a name that the project does not declare. |
| `game.sublevel_state(g, name)` | The state of a sublevel. |
| `game.active_sublevels(g)` | The names of the sublevels that are `Loading` or `Active`, in frame memory. |
| `game.sublevel_events(g)` | This frame's events ([Events](#events)). |

## Parts are scenes

A scene loads as its base and the parts of its active sublevels. Each part is a row of `scene.Scenes` with its own number, memory, ID map and links. So ownership, references, memory and staged loading work for a part as they do for a scene.

The base's blob lists its sublevels, by name and GUID. A part's blob does not know its base, so the part's row names it. A row's `part` is one value, `scene.Scene_Part`: a `Part_Base` with its sublevels, or a `Part_Of` that names its base and its sublevel. It is nil only for a base whose blob is still reading. `set_part` is its only writer, and a row gets its part once.

A part is wanted when its sublevel is active and its scene is in, and in no other case.

| Procedure | What it does |
|---|---|
| `scene.base_of(scenes, number)` | The base of a part. For any other scene, the scene itself. |
| `scene.sublevel_of(scenes, number)` | The sublevel of a part. |
| `scene.sublevels_of(scenes, base)` | The sublevels that a base's blob lists. |
| `scene.part_number(scenes, base, name)` | The number of a base's part of a sublevel, if it is loaded. |
| `scene.load_parts(w, scripts, scenes, base, wanted)` | Loads a base's wanted parts at once, as `add_scene_asset` does. |
| `scene.update_parts(w, scenes, wanted)` | Unloads the parts that are not wanted, and begins to load in stages the wanted ones that are missing. It gives how many entities went. |
| `scene.loading_with_parts(scenes, base)` | Whether the base or any of its parts is not ready. |
| `scene.add_scene(..., of = Part_Of{base, name})` | Adds a part from memory, as the editor sends it. A base that is not loaded refuses it. |
| `scene.move_entities(w, scenes, root, from, to)` | Moves an entity and its descendants to another part, with their handles, their maps and their links ([Editor: Parts](../editor/document-and-scenes.md#parts)). |

- **A scene that loads at once arrives whole.** The main scene and `Scene.load` load the base, then `load_parts` loads its active parts in the same frame.
- **A scene that loads in stages begins its parts when its blob is read.** `advance_loads` takes the active sublevels, and begins their parts as soon as the base knows its list. The base stays in `Settling` for at least one call, so it is never ready before its parts begin.
- **Unloading a base unloads its parts first,** since they name it.
- **A part that does not load** is logged, and its base does not try it again while the sublevel stays active. The sublevel is `Failed`, and `scene.sublevel_failed(scenes, name)` says so. Deactivating the sublevel forgets the failure (`scene.retry_sublevel`), so activating it again tries the part again, in the same frame too.
- **Bundles.** A part's blob is in its base's bundle ([Content: Scenes](../content/kinds/scenes.md#sublevels)). A part takes no bundle hold of its own: the base's hold keeps the bundle open.

## Activation

`game.set_sublevel(g, name, active)` queues a change with the scene requests. The change applies at the start of the next frame, or of this frame from `begin_frame` ([Scenes: Streaming](scenes.md#streaming)). In Luau, `Sublevel.set_active(name, active)` does the same, and raises an error for a name that the project does not declare ([Scripts](#scripts)).

- **Activating** sets the sublevel to `Loading`. `update_parts` begins its part of every loaded scene in stages, and `advance_loads` moves them on within the frame's budget ([World streaming: Budgets](streaming.md#budgets)).
- **Deactivating** sets the sublevel to `Inactive`. `update_parts` unloads its parts, with what they own, and the game runs `forget_despawned`.

One budget covers all staged loads in a frame. `streaming.update` spends it on the streamed scenes first, nearest first, then on the other loads, such as the parts of scenes that the game loaded. It does so with no `World_Streamer` too.

After the scenes advance, `update_sublevels` moves each active sublevel to `Failed` while one of its parts did not load, to `Loading` while one is not ready, and otherwise to `Active`.

## Ownership

An entity of a part has the part's number. So `Scene.of(entity)` gives the part's number, and `Scene.base(number)` gives its base. An entity that a behaviour on a part's entity spawns is owned by the part (`Scene_Owned`), so it goes when the sublevel deactivates ([Scenes: Ownership](scenes.md#ownership)).

## References

The cooker turns a reference from one part of a scene into another part into a reference across scenes, `@<part guid>/<id>` ([Content: Scenes](../content/kinds/scenes.md#sublevels)). So it binds when the part is ready, and goes back to 0 and waits when the part unloads ([Scenes: References across scenes](scenes.md#references-across-scenes)).

A reference prefers its own family: the base and the parts of its own copy of the scene. When two copies of a scene are loaded, each copy's references bind to its own parts. A reference to one of its family's sublevels waits for its family's part, and does not bind to another copy's.

## Streaming

A streamed scene loads the parts of its active sublevels with it, and they unload with it ([World streaming: The policy](streaming.md#the-policy)).

- **One load.** The policy counts a scene and its parts that are loading as one load for `MAX_SCENE_LOADS`. A scene whose base is ready but whose parts are not still counts.
- **Kept scenes.** The parts count toward `MAX_STREAMED_SCENES` with their scene.
- **`on_scene_ready`** says that the base is shown. `on_part_ready` says that a part is ready.

## Events

**In Odin,** `game.sublevel_events(g)` gives this frame's `Sublevel_Event`s: a `kind` and the `sublevel`'s name. They are valid until the next frame.

| Kind | When |
|---|---|
| `Loading` | The sublevel's parts began to load: it was activated, or a scene that loaded brought parts of it. |
| `Ready` | Its parts of every loaded scene are ready. |
| `Unloaded` | It was deactivated, and its parts unloaded. |
| `Failed` | One of its parts did not load. |

`scene.part_events(scenes)` gives each part's events since the game's last `clear_part_events`, once a frame. `streaming.events` adds `Sublevel_Loading`, `Sublevel_Ready` and `Sublevel_Unloaded` for the parts of streamed scenes, with the scene's `number` and `scene` GUID and the `sublevel`'s name.

**In scripts,** every behaviour that has a handler gets the game's sublevel events, on any entity, in the frame's script phase ([Scripts](#scripts)). The streamer entity's behaviours also get the events of the streamed scenes' parts, in the same phase ([World streaming: Events](streaming.md#events)):

| Event | When |
|---|---|
| `on_part_loading(number, scene, name)` | A part of the scene's sublevel began to load. `number` is the base's. |
| `on_part_ready(number, scene, name)` | The part is ready. |
| `on_part_unloaded(number, scene, name)` | The part unloaded, or did not load. |

## Scripts

The `Sublevel` library activates sublevels and reads their state. A name that the project does not declare is an error, except for `state`.

| Binding | What it does |
|---|---|
| `Sublevel.set_active(name, active)` | Queues the change for the start of the next frame, as `Scene.load` does ([Activation](#activation)). |
| `Sublevel.is_active(name)` | Whether the sublevel was last asked to be active. It is true at once after `set_active(name, true)`, before the parts begin to load. |
| `Sublevel.state(name)` | `"inactive"`, `"loading"`, `"ready"` (its parts of every loaded scene are ready), `"failed"` (one of its parts did not load), or nil for a name that the project does not declare. |

Each event goes to every behaviour whose class has the handler, with the sublevel's name, once ([Scripting: Behaviours: Events](../scripting/behaviours.md#events)):

| Event | When |
|---|---|
| `on_sublevel_loading(name)` | The sublevel's parts began to load: it was activated, or a scene that loaded brought parts of it. |
| `on_sublevel_ready(name)` | Its parts of every loaded scene are ready. |
| `on_sublevel_unloaded(name)` | It was deactivated, and its parts unloaded. |
| `on_sublevel_failed(name)` | One of its parts did not load. |

A part's entity is in the part's scene: `Scene.of(entity)` gives the part's number, `Scene.state(number)` its stage, and `Scene.base(number)` its base ([Scenes: Scripts](scenes.md#scripts)).

```luau
local Dusk = Behaviour.define("Dusk")

function Dusk:on_enable()
	Sublevel.set_active("night", true)
end

function Dusk:on_sublevel_ready(name: string)
	if name == "night" then
		-- Every lamp of the night is in the world: fade in.
	end
end

return Dusk
```

The sample's night scene turns its `night` sublevel on and off with N (`samples/mygame/content/scripts/night_toggle.luau`). F7 cycles to it.

## Scene memory

Each part takes a slot of scene memory ([Core: Scene memory](../core/jobs-and-memory.md#scene-memory)). So sublevels multiply the slots that a world needs: a scene with two active sublevels takes three.

`core.MAX_SCENE_MEMORY` is 128, up from 64. A larger table costs little:

- **The tables** grow by a few KB: the slots in the host, and `ecs.World.scenes`.
- **Address space** is reserved only by a slot that is open: `SCENE_RESERVE` (256 MB) each. 128 open slots reserve 32 GB of the 128 TB that a 64-bit process has. Only the pages that a scene uses are committed.
- **GPU scopes.** Each slot has a scope, and `gpu.Scope` is a `u8` with the scenes' scopes from 16. So the limit cannot go past 240. `core` asserts this when it compiles.

## Known limits

- **A change to the settings' sublevels** applies when the next level starts, except that a newly declared sublevel joins the running level, inactive.
- **The editor's scenes** come from its documents, not from blobs. The editor sends each document's parts itself, as rows that name their base. In Edit, the world has the editor's choice of sublevels, not the active set: a change of the active set in Edit unloads no part ([Editor: Parts](../editor/document-and-scenes.md#parts)). A base from the editor lists no sublevels, so activating a sublevel in Play loads no part of it.
- **At most 32 sublevels** for each project, and for each scene.

# World

The ECS in `lib/engine/ecs` and the packages directly on it: positions, transforms, fixed ticks, render extraction and volumes.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [ECS](ecs.md) | Entities, components, storage, queries, systems, command buffers, and the script view. |
| [Positions and transforms](positions-and-transforms.md) | Fixed-point positions and the transform hierarchy. |
| [Time](time.md) | Fixed ticks, interpolation and teleports. |
| [Render extraction](render-extraction.md) | How rendering reads the world. |
| [Volumes](volumes.md) | Settings that depend on where a point is. |

## Overview

The world is one `ecs.World` in `Game_State`. Its storage is virtual memory that the game reserves itself, so it holds no allocators and no pointers into code, and a code reload keeps it whole.

| File in `lib/engine/ecs` | What it holds |
|---|---|
| `world.odin` | `World`: the entity slots, the archetypes, the clock, spawn and despawn, `apply` |
| `entity.odin` | `Entity`: the generational handle |
| `component.odin` | `Registry` and `register_component`: stable IDs, sizes, layout hashes, defaults |
| `archetype.odin` | Archetypes and their 16 KiB chunks |
| `query.odin` | `Query`: terms, the archetype cache, chunk iteration, `collect` |
| `schedule.odin` | Systems, stages, `run_stage` and `run_fixed` |
| `commands.odin` | `Command_Buffer`: deferred structural changes |
| `activity.odin` | `Disabled` and `Inactive`, `set_active`, `update_activity` |
| `transform.odin` | `Transform`, `Local_Transform`, `Parent`, `Previous_Transform`, propagation, `presented` |
| `position.odin` | `World_Position` and its two operations |
| `name.odin` | The `Name` component |

The data flow in a frame: systems read and write components through queries, in parallel jobs; their structural changes go to command buffers, which `apply` runs at fixed points; the script phase edits the world directly because it is serial; and at the end, [render extraction](render-extraction.md#render-extraction) writes what the GPU needs into frame memory. Two packages sit directly on `ecs`: `lib/engine/volume` ([Volumes](volumes.md#volumes)) and `lib/engine/scene`, the loader that fills a world from a cooked scene or the editor's snapshot ([Editor](../editor/document-and-scenes.md#scenes)).

## Future work

- **Change tracking.** Several consumers scan the whole world: the editor's entity deltas ten times a second ([Editor](../editor/link.md#world)), the GPU scene's rewrite of every slot each frame ([Rendering](../rendering/gpu-scene.md#gpu-scene)), and `World.query` from scripts. A per-chunk change version for each column, bumped when a system with write access runs over the chunk (as Unity's DOTS does), lets a query ask for only the chunks that changed since a version it remembers. Do this when the editor's deltas or the GPU scene's upload show in the profile, which the designs expect at around 50 000 entities.
- **Physics and animation.** Both are designed as native `Fixed` systems with `Previous_Transform` interpolation. Physics on Jolt is its own design ([Physics](../physics/design.md)), with a tick hook in `run_fixed` and `f64` offsets from an anchor per physics world. Neither exists yet.
- **Spawning prefabs from systems.** A native system runs as a job, so it cannot call `scene.spawn_prefab` at once; it needs a `command_spawn_prefab` on the command buffer ([Editor: Prefabs](../editor/prefabs.md#future-work)). Do this with the first system that spawns.
- **Child lists.** Entities do not store their children, so despawning a parent and finding a child both scan. A per-entity first-child and next-sibling pair, maintained by `apply`, would make both O(children). Do this when hierarchies are large or despawns show in the profile.
- **A name index.** Unity's `GameObject.Find` is deliberately absent. If content needs lookups by name, a `Name` index maintained by `apply` is the place, so that it never scans.
- **Query cache by version.** A query's archetype cache is rebuilt at every `apply` that created an archetype. An archetype version on the world would let queries skip the rebuild when nothing new appeared, which matters once many queries exist.
- **A deeper hierarchy limit and a parallel `apply`.** The 64-level limit and the serial `apply` are fine for the sample. `apply` could run the buffers of independent archetypes in parallel once structural changes per frame are large.

## References

- Sander Mertens, [flecs](https://github.com/SanderMertens/flecs) and the [*ECS FAQ*](https://github.com/SanderMertens/ecs-faq): the vocabulary of archetypes, tables and deferred operations, and the trade-offs between archetype and sparse-set storage.
- Unity DOTS, [*Entities: Archetypes and chunks*](https://docs.unity3d.com/Packages/com.unity.entities@latest): the 16 KiB struct-of-arrays chunk as the unit of storage and of work, and change versions per chunk.
- Timothy Ford, [*Overwatch Gameplay Architecture and Netcode*](https://www.gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and), GDC 2017: systems with declared access, deferred structural changes, and a fixed tick with interpolated presentation.
- Glenn Fiedler, [*Fix Your Timestep!*](https://gafferongames.com/post/fix_your_timestep/): the accumulator, the tick cap, and `alpha` interpolation that [Fixed and variable rate](time.md#fixed-and-variable-rate) implements with integer time.
- Unity, [*Order of execution for event functions*](https://docs.unity3d.com/Manual/ExecutionOrder.html): the `FixedUpdate` / `Update` / `LateUpdate` model that the stages and the script phase mirror.
- On large-world coordinates: Unreal Engine's [*Large World Coordinates*](https://dev.epicgames.com/documentation/en-us/unreal-engine/large-world-coordinates-in-unreal-engine-5) and Godot's [*Large world coordinates*](https://docs.godotengine.org/en/stable/tutorials/physics/large_world_coordinates.html) describe the `f64` approach; cinnabar's fixed-point choice is explained in [Positions](positions-and-transforms.md#positions).

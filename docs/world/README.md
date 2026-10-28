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
| `schedule.odin` | Systems, stages, `run_stage`, the tick loop (`begin_ticks`, `next_tick`, `run_tick_systems`) and `run_fixed` |
| `commands.odin` | `Command_Buffer`: deferred structural changes |
| `activity.odin` | `Disabled` and `Inactive`, `set_active`, `update_activity` |
| `transform.odin` | `Transform`, `Local_Transform`, `Parent`, `Previous_Transform`, propagation, `presented` |
| `position.odin` | `World_Position` and its two operations |
| `name.odin` | The `Name` component |

The data flow in a frame: systems read and write components through queries, in parallel jobs; their structural changes go to command buffers, which `apply` runs at fixed points; the script phase edits the world directly because it is serial; and at the end, [render extraction](render-extraction.md#render-extraction) writes what the GPU needs into frame memory. Two packages sit directly on `ecs`: `lib/engine/volume` ([Volumes](volumes.md#volumes)) and `lib/engine/scene`, the loader that fills a world from a cooked scene or the editor's snapshot ([Editor](../editor/document-and-scenes.md#scenes)).

## References

- Sander Mertens, [flecs](https://github.com/SanderMertens/flecs) and the [*ECS FAQ*](https://github.com/SanderMertens/ecs-faq): the vocabulary of archetypes, tables and deferred operations, and the trade-offs between archetype and sparse-set storage.
- Unity DOTS, [*Entities: Archetypes and chunks*](https://docs.unity3d.com/Packages/com.unity.entities@latest): the 16 KiB struct-of-arrays chunk as the unit of storage and of work, and change versions per chunk.
- Timothy Ford, [*Overwatch Gameplay Architecture and Netcode*](https://www.gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and), GDC 2017: systems with declared access, deferred structural changes, and a fixed tick with interpolated presentation.
- Glenn Fiedler, [*Fix Your Timestep!*](https://gafferongames.com/post/fix_your_timestep/): the accumulator, the tick cap, and `alpha` interpolation that [Fixed and variable rate](time.md#fixed-and-variable-rate) implements with integer time.
- Unity, [*Order of execution for event functions*](https://docs.unity3d.com/Manual/ExecutionOrder.html): the `FixedUpdate` / `Update` / `LateUpdate` model that the stages and the script phase mirror.
- On large-world coordinates: Unreal Engine's [*Large World Coordinates*](https://dev.epicgames.com/documentation/en-us/unreal-engine/large-world-coordinates-in-unreal-engine-5) and Godot's [*Large world coordinates*](https://docs.godotengine.org/en/stable/tutorials/physics/large_world_coordinates.html) describe the `f64` approach; cinnabar's fixed-point choice is explained in [Positions](positions-and-transforms.md#positions).

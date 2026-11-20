# Cinematics

Cutscenes at run time, in `lib/engine/cutscene`. A cutscene asset holds bindings and tracks on one time axis (see [Content: Cutscenes](../content/kinds/cutscenes.md)). This layer describes how the game plays a cutscene: the entities that it acts on, how its tracks evaluate at a time, the player that runs it, and, in later parts, its tracks. Read [World: Scenes](../world/scenes.md) and [Editor: Prefabs](../editor/prefabs.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Bindings](bindings.md) | Possessed and spawned bindings, how they resolve, overrides, the policy for a missing binding, and what happens when a bound entity goes. |
| [Evaluation](evaluation.md) | The clock, the order in the frame, the kinds of track, sections and blending, events, the restore snapshot and hot reload. |
| [Player](player.md) | The player's states and its one writer, handles, commands, loading and failures, conflicts between players, and reset. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `lib/engine/cutscene` | Game | The bindings of a cutscene: how they resolve, their states, and how spawned entities are shown and released. The evaluation of its tracks at a time: the clock, the two systems, blending and the restore snapshot. The players: their lifecycle, handles and commands. |

The data flow:
1. A script or the game plays a cutscene, and gets a handle to its [player](player.md). In the next frame, the player loads the cutscene and the assets that it references, and resolves its bindings. A possessed binding finds an entity of a loaded scene. A spawned binding spawns a prefab, which stays hidden until the cutscene plays.
2. Each tick, the cutscene's time advances on its clock, and its tracks evaluate at the time. Tracks ask for a binding's entity, and get it only while it is alive. Before a track first writes a field, the snapshot saves the field ([Evaluation](evaluation.md)).
3. When the cutscene ends, the player gives the world back: the tracks set to restore put their fields back, the spawned entities are despawned and the assets are unloaded.

**Not built yet:** the tracks of each kind, skipping, the scripts' `Cutscene` library and the cutscene editor. Each one is a sub-issue of [#526](https://github.com/aszecsei/cinnabar/issues/526).

## References

- Unreal Engine, [*Working with Actors in Sequencer*](https://dev.epicgames.com/documentation/en-us/unreal-engine/working-with-actors-in-sequencer-in-unreal-engine): possessables, the actors that a sequence takes control of, and spawnables, the actors that it makes and destroys itself.
- Unity, [*Timeline*](https://docs.unity3d.com/Packages/com.unity.timeline@1.8/manual/index.html): a scene's director binds the objects of the scene to the tracks of a timeline asset.

# Cinematics

Cutscenes at run time, in `lib/engine/cutscene`. A cutscene asset holds bindings and tracks on one time axis (see [Content: Cutscenes](../content/kinds/cutscenes.md)). This layer describes how the game plays a cutscene: the entities that it acts on, how its tracks evaluate at a time, the player that runs it, and, in later parts, its tracks. Read [World: Scenes](../world/scenes.md) and [Editor: Prefabs](../editor/prefabs.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Bindings](bindings.md) | Possessed and spawned bindings, how they resolve, overrides, the policy for a missing binding, and what happens when a bound entity goes. |
| [Evaluation](evaluation.md) | The clock, the order in the frame, the kinds of track, sections and blending, events, the restore snapshot and hot reload. |
| [Player](player.md) | The player's states and its one writer, handles, commands, loading and failures, conflicts between players, and reset. |
| [Possession](possession.md) | What a cutscene suspends on the entities that it holds: behaviours, AI, navigation and physics. The input context and the hidden HUD, and how the end gives them back. |
| [Skipping](skipping.md) | The skip policy, the `Skipping` state and its fades, the events that fire when skipped, and the skip action that a player holds. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `lib/engine/cutscene` | Game | The bindings of a cutscene: how they resolve, their states, what they suspend, and how spawned entities are shown and released. The evaluation of its tracks at a time: the clock, the two systems, blending and the restore snapshot. The players: their lifecycle, handles and commands, what they hold of the game while they play, and how they skip. |

The data flow:
1. A script or the game plays a cutscene, and gets a handle to its [player](player.md). In the next frame, the player loads the cutscene and the assets that it references, and resolves its bindings. A possessed binding finds an entity of a loaded scene. A spawned binding spawns a prefab, which stays hidden until the cutscene plays. Each binding suspends the systems that would fight the cutscene on its entity, such as its behaviours and its AI ([Possession](possession.md)).
2. When the cutscene starts to play, the player pushes its input context and hides the HUD. Each tick, the cutscene's time advances on its clock, and its tracks evaluate at the time. Tracks ask for a binding's entity, and get it only while it is alive. Before a track first writes a field, the snapshot saves the field ([Evaluation](evaluation.md)).
3. A player who holds the skip action, or a script, skips the cutscene: behind a fade, the player evaluates the end, or the end of a skip range, once, and fires only the events marked to fire when skipped ([Skipping](skipping.md)).
4. When the cutscene ends, the player gives the world back: the tracks set to restore put their fields back, the input and the HUD come back, the bindings resume what they suspended, the spawned entities are despawned and the assets are unloaded.

**Not built yet:** the tracks of each kind, the scripts' `Cutscene` library and the cutscene editor. Each one is a sub-issue of [#526](https://github.com/aszecsei/cinnabar/issues/526).

## References

- Unreal Engine, [*Working with Actors in Sequencer*](https://dev.epicgames.com/documentation/en-us/unreal-engine/working-with-actors-in-sequencer-in-unreal-engine): possessables, the actors that a sequence takes control of, and spawnables, the actors that it makes and destroys itself.
- Unity, [*Timeline*](https://docs.unity3d.com/Packages/com.unity.timeline@1.8/manual/index.html): a scene's director binds the objects of the scene to the tracks of a timeline asset.

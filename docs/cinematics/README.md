# Cinematics

Cutscenes at run time, in `lib/engine/cutscene`. A cutscene asset holds bindings and tracks on one time axis (see [Content: Cutscenes](../content/kinds/cutscenes.md)). This layer describes how the game plays a cutscene: the entities that it acts on and, in later parts, its player, its evaluation and its tracks. Read [World: Scenes](../world/scenes.md) and [Editor: Prefabs](../editor/prefabs.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Bindings](bindings.md) | Possessed and spawned bindings, how they resolve, overrides, the policy for a missing binding, and what happens when a bound entity goes. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `lib/engine/cutscene` | Game | The bindings of a cutscene: how they resolve, their states, and how spawned entities are shown and released. |

The data flow:
1. A player resolves a cutscene's bindings before the cutscene plays. A possessed binding finds an entity of a loaded scene. A spawned binding spawns a prefab, which stays hidden until the cutscene plays.
2. At each evaluation, tracks ask for a binding's entity. They get it only while it is alive.
3. When the cutscene ends, the spawned entities are despawned.

**Not built yet:** the player and its lifecycle, evaluation, the tracks, skipping, the scripts' `Cutscene` library and the cutscene editor. Each one is a sub-issue of [#526](https://github.com/aszecsei/cinnabar/issues/526).

## References

- Unreal Engine, [*Working with Actors in Sequencer*](https://dev.epicgames.com/documentation/en-us/unreal-engine/working-with-actors-in-sequencer-in-unreal-engine): possessables, the actors that a sequence takes control of, and spawnables, the actors that it makes and destroys itself.
- Unity, [*Timeline*](https://docs.unity3d.com/Packages/com.unity.timeline@1.8/manual/index.html): a scene's director binds the objects of the scene to the tracks of a timeline asset.

# AI

How agents decide, perceive and find their way: agents, their blackboards and the actions that they take, the decisions that choose the actions on jobs within a budget, and what agents see and hear, in `lib/engine/ai`; and the navmeshes that the cooker bakes, loaded with their scene, the queries on them, and the path requests that systems solve on jobs, in `lib/engine/nav`. Read [World](../world/README.md), [Scripting](../scripting/README.md), [Physics](../physics/README.md), [Content: Blackboards](../content/kinds/blackboards.md), [Content: Decisions](../content/kinds/decisions.md), [Content: Perceptions](../content/kinds/perceptions.md) and [Content: Navmeshes](../content/kinds/nav-meshes.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Agents](agents.md) | Agents and their pool, blackboards and how they are written, thinking and its budget, decision modules, native and script actions, the order in a tick, determinism, reload, and the `Blackboard` and `Agent` script libraries. |
| [Perception](perception.md) | `Perceiver` and `Perceivable`, the project's tags, sight in a cone checked by rays within a budget shared in turn, hearing gameplay's noises through walls, each agent's memory, the rows that fill its blackboard, `on_perceive` and `on_forget`, determinism, the `Perception` script library, and drawing. |
| [Navigation](navigation.md) | Loading a scene's navmeshes, the queries (`nearest`, `find_path`, `raycast`, `random_point`), path requests and their budget, determinism, the `Navigation` script library, drawing in the editor, and the limits. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `tools/cook` (blackboards, decisions) | Tool | Cooks blackboards into slots and decisions' shared parts against their blackboards, and gives the rest of a decision to its technique's reader (see [Content: Decisions](../content/kinds/decisions.md)). |
| `lib/engine/ai` | Game | `Agent` and `Agent_State`, the agents' pool, loading, the `ai perceive`, `ai think` and `ai actions` systems, the commands' job buffer, native and script actions, `Perceiver` and `Perceivable` and the agents' memories, and the script libraries. |
| `tools/cook` (perceptions) | Tool | Cooks perceptions into the tags that they notice and their rows (see [Content: Perceptions](../content/kinds/perceptions.md)). |
| `tools/cook` (navmeshes) | Tool | Bakes a navmesh for each navigation volume and agent type with Recast (see [Content: Navmeshes](../content/kinds/nav-meshes.md)). |
| `lib/engine/nav` | Game | `Nav_Mesh_Volume` and `Nav_Path`, loading, the queries, the path requests and their system, the script library, and drawing. |
| `lib/engine/random` | Game | The engine's generator, xoshiro256**, which `random_point` and the scripts' `Random` draw from. |

The data flow in a frame: `ai.prepare` loads the agents' blackboards, decisions and perceptions and reads them into the frame's views. In each fixed tick, `ai perceive` checks the perceivers' sight with rays within a budget, hears the noises of the last tick, and fills their blackboards. Then `ai think` runs the decisions of the agents whose turn it is on jobs, and `ai actions` the native actions. Their commands apply after the tick's `Fixed` systems, and the script actions run in the scripts' fixed step. `ai.end_frame` lets the views go.

For navigation, `nav.prepare` loads the navmeshes of the world's scene when the scene changes, and reads the loaded blobs into the frame's views. The queries read the views, from frame code, systems' jobs and scripts. In each fixed tick, the `nav paths` system admits the requests, runs the searches on jobs for their share of the node budget, and writes the paths that finished to their `Nav_Path`s. `nav.end_frame` lets the views go before the assets poll for recooked blobs.

## References

- Epic Games, [Unreal Engine: Behavior Trees](https://dev.epicgames.com/documentation/en-us/unreal-engine/behavior-tree-overview-in-unreal-engine): blackboards of typed keys, which the AI's blackboards follow.
- Epic Games, [Unreal Engine: AI Perception](https://dev.epicgames.com/documentation/en-us/unreal-engine/ai-perception-in-unreal-engine): sight in a cone with a line-of-sight check, hearing of noise events that gameplay reports, and stimuli that age out, which perception follows.

- Mikko Mononen, [Recast and Detour](https://github.com/recastnavigation/recastnavigation): the bake, and Detour's `dtNavMeshQuery` (`findPath`, `findStraightPath`, `raycast`, `findRandomPointAroundCircle`) and its sliced path finding, which the queries and the path requests follow. The engine's code is its own.
- David Blackman and Sebastiano Vigna, [*Scrambled Linear Pseudorandom Number Generators*](https://prng.di.unimi.it/): xoshiro256**, the generator in `lib/engine/random`.

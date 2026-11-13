# AI

How agents decide, perceive and find their way: agents, their blackboards and the actions that they take, the decisions that choose the actions on jobs within a budget, and what agents see and hear, in `lib/engine/ai`; and the navmeshes that the cooker bakes, loaded with their scene, the queries on them, the path requests that systems solve on jobs, and the crowd that walks agents along their paths around each other, in `lib/engine/nav`. Read [World](../world/README.md), [Scripting](../scripting/README.md), [Physics](../physics/README.md), [Content: Blackboards](../content/kinds/blackboards.md), [Content: Decisions](../content/kinds/decisions.md), [Content: Perceptions](../content/kinds/perceptions.md) and [Content: Navmeshes](../content/kinds/nav-meshes.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Agents](agents.md) | Agents and their pool, blackboards and how they are written, thinking and its budget, decision modules, native and script actions, the order in a tick, determinism, reload, and the `Blackboard` and `Agent` script libraries. |
| [Behavior trees](behavior-trees.md) | The `behavior_tree` technique's module: a think, starting and resuming nodes, the abort modes, actions over several thinks, time in ticks, repeats, determinism, reload, and the limits. |
| [Utility](utility.md) | The `utility` technique's module: a think, scoring with curves and the compensation factor, the best or a weighted pick by the agent's generator, momentum, cooldowns, scoring for each perceived target, the scores for debuggers and scripts, determinism, reload, and the limits. |
| [Perception](perception.md) | `Perceiver` and `Perceivable`, the project's tags, sight in a cone checked by rays within a budget shared in turn, hearing gameplay's noises through walls, each agent's memory, the rows that fill its blackboard, `on_perceive` and `on_forget`, determinism, the `Perception` script library, and drawing. |
| [Navigation](navigation.md) | Loading a scene's navmeshes, the queries (`nearest`, `find_path`, `raycast`, `random_point`), path requests and their budget, the crowd (`Nav_Agent`, corridors, steering and avoidance) and its movement through characters, the `move_to` and `stop` actions, determinism, the `Navigation` script library, drawing in the editor, and the limits. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `tools/cook` (blackboards, decisions) | Tool | Cooks blackboards into slots and decisions' shared parts against their blackboards, and gives the rest of a decision to its technique's reader (see [Content: Decisions](../content/kinds/decisions.md)). |
| `lib/engine/ai/behavior_tree` | Game | The behavior tree module: it checks a tree when an agent starts with it, and runs it when the agent thinks, with each node's state in the agent's module state (see [Behavior trees](behavior-trees.md)). |
| `lib/engine/ai/utility` | Game | The utility module: it checks a decision's options when an agent starts with it, and scores and runs them when the agent thinks, with the running option, cooldowns and last scores in the agent's module state (see [Utility](utility.md)). |
| `lib/engine/ai` | Game | `Agent` and `Agent_State`, the agents' pool, loading, the `ai perceive`, `ai think` and `ai actions` systems, the commands' job buffer, native and script actions, `Perceiver` and `Perceivable` and the agents' memories, and the script libraries. |
| `tools/cook` (perceptions) | Tool | Cooks perceptions into the tags that they notice and their rows (see [Content: Perceptions](../content/kinds/perceptions.md)). |
| `tools/cook` (navmeshes) | Tool | Bakes a navmesh for each navigation volume and agent type with Recast (see [Content: Navmeshes](../content/kinds/nav-meshes.md)). |
| `lib/engine/nav` | Game | `Nav_Mesh_Volume`, `Nav_Path`, `Nav_Agent` and `Nav_Agent_State`, loading, the queries, the path requests and their system, the crowd and its system, the `move_to` and `stop` actions, the script library, and drawing. |
| `lib/engine/random` | Game | The engine's generator, xoshiro256**, which `random_point` and the scripts' `Random` draw from. |

The data flow in a frame: `ai.prepare` loads the agents' blackboards, decisions and perceptions and reads them into the frame's views. In each fixed tick, `ai perceive` checks the perceivers' sight with rays within a budget, hears the noises of the last tick, and fills their blackboards. Then `ai think` runs the decisions of the agents whose turn it is on jobs, and `ai actions` the native actions. Their commands apply after the tick's `Fixed` systems, and the script actions run in the scripts' fixed step. `ai.end_frame` lets the views go.

For navigation, `nav.prepare` loads the navmeshes of the world's scene when the scene changes, and reads the loaded blobs into the frame's views. The queries read the views, from frame code, systems' jobs and scripts. In each fixed tick, the `nav paths` system admits the requests, runs the searches on jobs for their share of the node budget, and writes the paths that finished to their `Nav_Path`s. Then `nav crowd` applies the agents' moves, takes their paths, and on jobs fixes each agent's corridor from where its character is, steers it and avoids its neighbors, and gives its character a velocity, which the tick's physics step moves. `nav.end_frame` lets the views go before the assets poll for recooked blobs.

## References

- Epic Games, [Unreal Engine: Behavior Trees](https://dev.epicgames.com/documentation/en-us/unreal-engine/behavior-tree-overview-in-unreal-engine): blackboards of typed keys, which the AI's blackboards follow, and decorators with observer aborts (`Self`, `Lower Priority` and `Both`), which the behavior tree's guards follow.
- Dave Mark, *Behavioral Mathematics for Game AI* (Course Technology, 2009), and Dave Mark and Mike Lewis, "Building a Better Centaur: AI at Massive Scale" (GDC 2015): response curves over normalized inputs, and the compensation factor for the count of considerations, which utility decisions follow.
- Epic Games, [Unreal Engine: AI Perception](https://dev.epicgames.com/documentation/en-us/unreal-engine/ai-perception-in-unreal-engine): sight in a cone with a line-of-sight check, hearing of noise events that gameplay reports, and stimuli that age out, which perception follows.

- Mikko Mononen, [Recast and Detour](https://github.com/recastnavigation/recastnavigation): the bake, and Detour's `dtNavMeshQuery` (`findPath`, `findStraightPath`, `raycast`, `findRandomPointAroundCircle`) and its sliced path finding, which the queries and the path requests follow. The engine's code is its own.
- Mikko Mononen, [DetourCrowd](https://github.com/recastnavigation/recastnavigation/tree/main/DetourCrowd): the path corridor (`dtPathCorridor`), and the adaptive sampling of `dtObstacleAvoidanceQuery`, which the crowd follows. The engine's code is its own.
- David Blackman and Sebastiano Vigna, [*Scrambled Linear Pseudorandom Number Generators*](https://prng.di.unimi.it/): xoshiro256**, the generator in `lib/engine/random`.

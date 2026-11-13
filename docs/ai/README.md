# AI

How agents decide, perceive and find their way: agents, their blackboards and the actions that they take, the decisions that choose the actions on jobs within a budget, and what agents see and hear, in `lib/engine/ai`; and the navmeshes that the cooker bakes, loaded with their scene, the queries on them, the path requests that systems solve on jobs, and the crowd that walks agents along their paths around each other, in `lib/engine/nav`. Read [World](../world/README.md), [Scripting](../scripting/README.md), [Physics](../physics/README.md), [Content: Blackboards](../content/kinds/blackboards.md), [Content: Decisions](../content/kinds/decisions.md), [Content: Perceptions](../content/kinds/perceptions.md) and [Content: Navmeshes](../content/kinds/nav-meshes.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Agents](agents.md) | Agents and their pool, blackboards and how they are written, thinking and its budget, decision modules, native and script actions, the order in a tick, determinism, reload, and the `Blackboard` and `Agent` script libraries. |
| [Behavior trees](behavior-trees.md) | The `behavior_tree` technique's module: a think, starting and resuming nodes, the abort modes, actions over several thinks, time in ticks, repeats, determinism, reload, and the limits. |
| [Utility](utility.md) | The `utility` technique's module: a think, scoring with curves and the compensation factor, the best or a weighted pick by the agent's generator, momentum, cooldowns, scoring for each perceived target, the scores for debuggers and scripts, determinism, reload, and the limits. |
| [GOAP](goap.md) | The `goap` technique's module and the plan runner that the planning techniques share: a think, goals and their priorities, the regressive A* search, the plan budget shared among agents over ticks, running a plan and writing its effects, replanning, the plan for debuggers and scripts, determinism, reload, and the limits. |
| [HTN](htn.md) | The `htn` technique's module: a think, the forward decomposition by methods in order with backtracking by replay, the method traversal record that lets a better method cut in, the budget of steps, running and replanning with GOAP's runner, the plan and its methods for debuggers and scripts, determinism, reload, and the limits. |
| [Perception](perception.md) | `Perceiver` and `Perceivable`, the project's tags, sight in a cone checked by rays within a budget shared in turn, hearing gameplay's noises through walls, each agent's memory, the rows that fill its blackboard, `on_perceive` and `on_forget`, determinism, the `Perception` script library, and drawing. |
| [Navigation](navigation.md) | Loading a scene's navmeshes, the queries (`nearest`, `find_path`, `raycast`, `random_point`), path requests and their budget, the crowd (`Nav_Agent`, corridors, steering and avoidance) and its movement through characters, the `move_to` and `stop` actions, determinism, the `Navigation` script library, drawing in the editor, and the limits. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `tools/cook` (blackboards, decisions) | Tool | Cooks blackboards into slots and decisions' shared parts against their blackboards, and gives the rest of a decision to its technique's reader (see [Content: Decisions](../content/kinds/decisions.md)). |
| `lib/engine/ai/behavior_tree` | Game | The behavior tree module: it checks a tree when an agent starts with it, and runs it when the agent thinks, with each node's state in the agent's module state (see [Behavior trees](behavior-trees.md)). |
| `lib/engine/ai/utility` | Game | The utility module: it checks a decision's options when an agent starts with it, and scores and runs them when the agent thinks, with the running option, cooldowns and last scores in the agent's module state (see [Utility](utility.md)). |
| `lib/engine/ai/goap` | Game | The GOAP module: it checks a decision's goals and actions when an agent starts with it, and picks a goal, searches for a plan within its share of the plan budget, and runs the plan when the agent thinks, with the plan and the search in the agent's module state (see [GOAP](goap.md)). |
| `lib/engine/ai/htn` | Game | The HTN module: it checks a decision's tasks, methods and actions when an agent starts with it, and decomposes the root task within its share of the plan budget, runs the plan, and looks for a better method while it runs, with the plan, its record and the decomposition in the agent's module state (see [HTN](htn.md)). |
| `lib/engine/ai` | Game | `Agent` and `Agent_State`, the agents' pool, loading, the `ai perceive`, `ai think` and `ai actions` systems, the plan budget and the plan runner, the commands' job buffer, native and script actions, `Perceiver` and `Perceivable` and the agents' memories, and the script libraries. |
| `tools/cook` (perceptions) | Tool | Cooks perceptions into the tags that they notice and their rows (see [Content: Perceptions](../content/kinds/perceptions.md)). |
| `tools/cook` (navmeshes) | Tool | Bakes a navmesh for each navigation volume and agent type with Recast (see [Content: Navmeshes](../content/kinds/nav-meshes.md)). |
| `lib/engine/nav` | Game | `Nav_Mesh_Volume`, `Nav_Path`, `Nav_Agent` and `Nav_Agent_State`, loading, the queries, the path requests and their system, the crowd and its system, the `move_to` and `stop` actions, the script library, and drawing. |
| `lib/engine/random` | Game | The engine's generator, xoshiro256**, which `random_point` and the scripts' `Random` draw from. |

The data flow in a frame: `ai.prepare` loads the agents' blackboards, decisions and perceptions and reads them into the frame's views. In each fixed tick, `ai perceive` checks the perceivers' sight with rays within a budget, hears the noises of the last tick, and fills their blackboards. Then `ai think` runs the decisions of the agents whose turn it is on jobs, and `ai actions` the native actions. Their commands apply after the tick's `Fixed` systems, and the script actions run in the scripts' fixed step. `ai.end_frame` lets the views go.

For navigation, `nav.prepare` loads the navmeshes of the world's scene when the scene changes, and reads the loaded blobs into the frame's views. The queries read the views, from frame code, systems' jobs and scripts. In each fixed tick, the `nav paths` system admits the requests, runs the searches on jobs for their share of the node budget, and writes the paths that finished to their `Nav_Path`s. Then `nav crowd` applies the agents' moves, takes their paths, and on jobs fixes each agent's corridor from where its character is, steers it and avoids its neighbors, and gives its character a velocity, which the tick's physics step moves. `nav.end_frame` lets the views go before the assets poll for recooked blobs.

## Design

1. **Shared parts, and a module for each technique.** An agent has a blackboard of typed keys, a perception that fills some of them, and actions that act. A decision module reads the blackboard and chooses the next action. Behavior trees, utility, GOAP and HTN are four modules over the same parts. Agents with different techniques can therefore share a blackboard and actions, and a script can give an agent another decision ([Agents](agents.md#design)).
2. **Decisions are data, and scripts act.** A decision is a `.decision` asset whose header names its technique. The editor edits it, and the cooker cooks it against its blackboard. A module runs it natively on jobs, in fixed ticks, within a budget of agents. Scripts write the blackboard and implement actions, but they do not decide.
3. **Perception writes the blackboard.** Sight and hearing fill keys through the rows of the agent's perception. A noise is an event that gameplay makes. It is not a sound in the mix ([Perception](perception.md#design)).
4. **Navigation is the engine's own at runtime.** The cooker bakes navmeshes with Recast from the static colliders of a scene's navigation volumes, one for each agent type. The queries, the path requests and the crowd are Odin in `lib/engine/nav`, after Detour's algorithms, with no static state ([Navigation](navigation.md#design)).
5. **Agents move as characters.** The crowd steers each agent and gives its `Character` a velocity, which the physics step moves. Physics owns the position.
6. **The state is on the host's heap.** The agents' pool and the crowd's pool keep each agent's values, module state, running action, memory and corridor, so a code reload keeps every agent where it was. A planner keeps its search there between ticks, since jobs end with the frame.

## The order in a tick

| Step | What happens |
|---|---|
| 1. `ai perceive` | The perceivers see within the ray budget and hear the noises of the last tick. Their memories change, and their perceptions' rows ask to write the blackboard ([Perception](perception.md#the-order-in-a-tick)). |
| 2. `ai think` | The native actions that ended stop. The agents whose turn it is think on jobs, within the think budget, and ask for actions and writes ([Agents: Thinking](agents.md#thinking)). |
| 3. `ai actions` | The native actions start and tick on jobs. `move_to` asks the crowd for a move. |
| 4. `nav paths` | The path requests are solved on jobs, within the node budget ([Navigation: Path requests](navigation.md#path-requests)). |
| 5. `nav crowd` | The crowd applies its moves, takes its paths, steers and avoids, and gives the characters their velocities ([Navigation: Crowds](navigation.md#crowds)). |
| 6. The flush | The commands of the tick's jobs apply, in system order and then job order: blackboard writes, and actions to start or stop. |
| 7. The scripts' fixed step | The behaviours' `fixed_update`, and then the script actions: those that ended stop, and those that a decision chose start and tick. |
| 8. Physics, then events | The physics step moves the characters. Then the tick's events arrive: contacts, animation events, and `on_perceive` and `on_forget`. |

A decision therefore reads in a tick what perception wrote in the tick before, and an action that it starts acts in the same tick, for a script action, or in the next, for a native one.

## Reload and restart

| What happens | The agents | Navigation |
|---|---|---|
| A code reload | Keep their values, module states, running actions and memories. `register_world` registers the modules and the native actions again ([Agents: Reload and restart](agents.md#reload-and-restart)). | Keeps its navmeshes, its paths and its crowd. |
| A soft restart | Start again from their blackboards' defaults, since the pool goes with the `Game`. | Starts again with the `Game`. |
| A recooked blackboard or decision | The agent stops its action and starts again from its defaults. | — |
| A recooked navmesh | — | The paths on it are found again, and the crowd's agents ask for new paths ([Navigation: Loading](navigation.md#loading)). |
| A script hot reload | A script action's class is patched in place, so its instances keep running. | — |

## The sample

`samples/mygame`'s guard scene, `content/scenes/guard.scene`, which F7 cycles to, puts the parts together. It has two rooms that a doorway 2 m wide joins, a ramp up to a platform in the east room, low cover 1.2 m high, tall cover, and a navigation volume over all of it.

| Entity | What it has | What it does |
|---|---|---|
| The player | `Character`, a `Perceivable` with the `Player` tag, and `player.luau`, `ai/footsteps.luau` and `ai/thrower.luau` | Walks with W, A, S and D, and makes a quiet `Player` noise, 4 m, at each stride. E throws a stone, `prefabs/stone.prefab`. Each fast knock of the stone makes a loud `Noise`, 15 m, and the thud's sound. A stone hurts an agent with `Health` the first time that it hits it. |
| The guard | A fox: `Character`, `Nav_Agent`, `Perceiver`, `Agent`, and an `Animator` with `models/fox/guard.animation_graph`; `ai/agent_body.luau` and `ai/decision_switch.luau` | Runs `ai/guard.decision`, a behavior tree. H swaps it with `ai/guard_htn.decision`, an HTN, through `Agent.set_decision`. |
| The wary one | A capsule with the guard's components without the `Animator`; `ai/agent_body.luau` and `ai/health.luau` | Runs `ai/wary.decision`, a utility decision. |
| Crowd | `ai/crowd.luau` | G adds 18 guards from `prefabs/guard.prefab` at random points on the navmesh, which makes twenty agents. The next G takes them away. |
| HUD | `ui/guard_hud.ui` and `ai/guard_hud.luau` | Shows the guard's decision and action, the wary one's action and health, and the number of agents. |

**The shared parts.** Every agent names one blackboard, `ai/guard.blackboard`, and one perception, `ai/guard.perception`.
- **The perception** fills `target` with the nearest `Player` that the agent sees or hears, `can_see_target` with whether it sees them, and `last_seen` with where it last perceived them. A footstep is a noise whose source is the player, so it keeps the player in the agent's memory, at the step's place, without sight. The perception also fills `noise` and `noise_at` with the nearest `Noise` that the agent remembers, and where it was.
- **The actions** are the engine's `move_to` and `stop`, and the script actions in `content/scripts/ai`, which the main script requires through `ai/actions.luau`: `bark(at)`, `look_around(seconds)`, `next_patrol_point(radius)`, `patrol(radius)`, `keep_distance(from, range)` and `flee(from, range)`. `patrol` and `flee` wait for their own moves by the tickets that `Navigation.move_to` gives.
- **The body.** `agent_body.luau` keeps what each agent's actions share: where the agent started, which the patrols walk around, and where an action asks it to look. The actions reach it with `self.entity:get(AgentBody)`. It turns the agent to face the way that the crowd walks it. While the agent stands, it turns the agent to where its action asks it to look. It sets the graph's `speed` from `Navigation.velocity`, so the fox walks and runs as fast as it moves. `bark` sets the graph's `bark` trigger, and the graph's `bark` event plays `audio/bark.wav`. An agent without an `Animator` barks at once.

**The guard's tree** has four branches, in order of priority:
1. **Chase** while it sees the player, with `abort = both`. It notes that it searches, and moves to the player. Within 2 m, the bark cuts in: it stops and barks, and the bark cools down for 3 s.
2. **Go to a noise** that it remembers, with `abort = lower`, and look about there.
3. **Search** while it searches, or while it remembers the player without seeing them, with `abort = both`. It moves to `last_seen`, looks about for 3 s, and stops searching. A wall hides the player, and so does the low cover, which is higher than the fox's eye. A footstep shows where they are.
4. **Patrol:** it takes a random point within 8 m of where it started, moves there, and looks about.

**The guard's HTN** has the same ways, as five methods of its root task in the same order, over the same actions. Its planning key is `can_see_target`, which the chase and the bark need. When the guard loses sight of the player, the key changes, and the guard plans again and searches. When it sees the player, the chase is a better method, which cuts into a search or a patrol ([HTN: The method traversal record](htn.md#the-method-traversal-record)).

**The wary one's options** weigh its health and its distance to the player. Healthy, it chases, and it barks when it is close. Hurt, it keeps 6 m away. Badly hurt and close, it flees to the furthest of a few points within 12 m. A noise draws it, and otherwise it patrols. Two stones take its health from 100 to 30, and it gets 3 points back each second ([Utility](utility.md)).

**Watching it.** Play the scene in the editor, select an agent and open its decision. The decision editor shows the guard's running branch or its HTN plan, and the wary one's scores ([Editor: Decision editor: Live view](../editor/decision-editor.md#live-view)). A decision saved while the game plays is cooked again, and the agent starts again with it.

**The cost.** `TwentyAgentsCostWhatTheProfilerReports`, a host link test, plays the scene with 18 more guards: first while they patrol, and then while they chase the player. It reports the profiler's costs of the five systems for each tick, and of the scripts. The intervals of 0.2 s and 0.25 s spread the agents' thinks over the ticks, and the think budget bounds a tick in which many are due ([Agents: Thinking](agents.md#thinking)).

## References

- Epic Games, [Unreal Engine: Behavior Trees](https://dev.epicgames.com/documentation/en-us/unreal-engine/behavior-tree-overview-in-unreal-engine): blackboards of typed keys, which the AI's blackboards follow, and decorators with observer aborts (`Self`, `Lower Priority` and `Both`), which the behavior tree's guards follow.
- Dave Mark, *Behavioral Mathematics for Game AI* (Course Technology, 2009), and Dave Mark and Mike Lewis, "Building a Better Centaur: AI at Massive Scale" (GDC 2015): response curves over normalized inputs, and the compensation factor for the count of considerations, which utility decisions follow.
- Jeff Orkin, "Three States and a Plan: The A.I. of F.E.A.R." (GDC 2006): goals, actions with preconditions and effects, and a regressive A* over a world state of facts, which GOAP decisions follow.
- Dana Nau et al., "SHOP: Simple Hierarchical Ordered Planner" (IJCAI 1999): total-order forward decomposition of tasks by methods in order, with backtracking, which HTN decisions follow.
- Troy Humphreys, "Exploring HTN Planners through Example", *Game AI Pro*, chapter 12 (CRC Press, 2013): the method traversal record, by which a better method replaces the running plan.
- Epic Games, [Unreal Engine: AI Perception](https://dev.epicgames.com/documentation/en-us/unreal-engine/ai-perception-in-unreal-engine): sight in a cone with a line-of-sight check, hearing of noise events that gameplay reports, and stimuli that age out, which perception follows.

- Mikko Mononen, [Recast and Detour](https://github.com/recastnavigation/recastnavigation): the bake, and Detour's `dtNavMeshQuery` (`findPath`, `findStraightPath`, `raycast`, `findRandomPointAroundCircle`) and its sliced path finding, which the queries and the path requests follow. The engine's code is its own.
- Mikko Mononen, [DetourCrowd](https://github.com/recastnavigation/recastnavigation/tree/main/DetourCrowd): the path corridor (`dtPathCorridor`), and the adaptive sampling of `dtObstacleAvoidanceQuery`, which the crowd follows. The engine's code is its own.
- David Blackman and Sebastiano Vigna, [*Scrambled Linear Pseudorandom Number Generators*](https://prng.di.unimi.it/): xoshiro256**, the generator in `lib/engine/random`.

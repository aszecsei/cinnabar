# Navigation

How agents find their way at runtime: the navmeshes of a scene load with it, queries find points and paths on them, path requests are solved on jobs in fixed ticks within a budget, and the crowd walks agents along their paths around each other. The cooker bakes the navmeshes with Recast ([Content: Navmeshes](../content/kinds/nav-meshes.md)). The runtime, in `lib/engine/nav`, is the engine's own Odin, with nothing of Detour linked. Read [Hot reload](../overview/hot-reload.md#rules), [Core: Jobs and memory](../core/jobs-and-memory.md), [World: ECS](../world/ecs.md) and [Positions and transforms](../world/positions-and-transforms.md) first.

**In this document:** [Design](#design) · [Loading](#loading) · [Queries](#queries) · [Path requests](#path-requests) · [Crowds](#crowds) · [Movement](#movement) · [Determinism](#determinism) · [Scripts](#scripts) · [Drawing](#drawing) · [Limits](#limits)

## Design

1. **The runtime is the engine's own.** The queries follow Detour's `dtNavMeshQuery` (`findNearestPoly`, `findPath`, `findStraightPath`, `raycast` and `findRandomPointAroundCircle`), but read the engine's blob ([Content: Navmeshes: The blob](../content/kinds/nav-meshes.md#the-blob)). Nothing has static state, so a code reload keeps all of it.
2. **The state holds handles, not blobs.** `nav.State` in `Game` holds the asset handles of the scene and its navmeshes, and plain data for the path requests. Each frame, `prepare` reads the loaded blobs into the frame's views, and `end_frame` lets them go before `asset.poll` can swap a blob.
3. **Queries only read.** Their scratch memory is the allocator they are given, so frame code, any number of jobs and scripts can query at once.
4. **Positions are `World_Position`s outside, and `f32` inside**, in meters relative to the navmesh's anchor, the center of its volume. A query converts each point once.
5. **Path requests spread over ticks.** A `Fixed` system solves the queued requests on jobs, a few searches at a time, within a budget of searched nodes in each tick. A search stops only between nodes, so its path does not depend on the budget or the number of jobs, only the tick it is ready in.
6. **Agents walk through their characters.** The crowd follows DetourCrowd's corridor and its adaptive sampling, in the engine's own code. It gives each agent's `Character` a velocity, and the physics tick moves the capsule ([Physics: Characters](../physics/design.md#characters)). The crowd reads where the character got to in the next tick, so a wall, a slope or a push has the last word.

## Loading

A scene's navmeshes load with it and unload when the world holds another scene.

- **The world's scene:** `ecs.World.scene` is the GUID of the scene that the world was loaded from. `scene.load` is its only writer. A scene loaded by GUID (`scene.load_asset`) gives it the blob's GUID. The editor's document gives it the `Load_Scene` message's GUID (see [Editor: Editor link](../editor/link.md#messages)). A scene that was never cooked has none.
- **The list:** `nav.prepare` notices a new scene, loads the scene's blob through the asset runtime, and reads its navmeshes with `format.scene_nav_meshes`. It loads each one by its GUID and unloads the old scene's. In a release, a level's bundle holds its navmeshes ([Blobs and loading: Bundles](../content/blobs-and-loading.md#bundles)).
- **A recook:** a recooked navmesh is the same handle with a new version, so the next frame reads the new blob, and the paths on it are found again ([Path requests](#path-requests)). A recooked scene, such as one with a new volume, has its list read again. The new list loads before the old one unloads, so a navmesh on both stays loaded.
- **Missing blobs:** a scene or a navmesh that cannot load is tried again when the cache's generation changes, after the next cook.
- **Agent types:** an `Agent_Type` is the index of the type in the project's `nav.agents`, which is also its bit in `Nav_Mesh_Volume.agents` ([Content: Navmeshes: Agent types](../content/kinds/nav-meshes.md#agent-types)). Each navmesh's blob holds it as `agent_index`. `nav.agent_type(s, name)` finds the type of a name among the loaded navmeshes.
- **The frame's views:** `prepare` runs in every mode, before the ticks, and `end_frame` runs at the end of the frame. Queries work between them. A blob that the build cannot read is warned about once, and is not used.

`nav.State` has one writer for the loaded scene (`sync_scene`). It is either loaded, with its list and its navmeshes' handles, or missing, waiting for a cook.

## Queries

| Query | Gives |
|---|---|
| `nearest(s, point, extents, agent)` | The point of the navmesh nearest `point`, within `extents` of it, and its polygon, as a `Location` |
| `find_path(s, start, goal, agent, max_nodes, allocator)` | A `Path_Result`: its status, `Found`, `Partial` or `Failed`, its corners as `World_Position`s, and its corridor of polygons |
| `raycast(s, start, end, agent)` | A `Raycast_Hit`: how far a straight walk along the navmesh goes, as the fraction `t`, the point it reaches, and the normal of the wall that stops it, or none |
| `random_point(s, around, radius, agent, rng, max_nodes, allocator)` | A reachable point near `around`, drawn from the caller's `random.State` |

- **Which navmesh:** a query takes the navmeshes of its agent type whose bounds hold its point, and of several, the one with the nearest polygon. `find_path`, `raycast` and `random_point` work on the navmesh of their start.
- **Snapping:** a start or a goal snaps to the nearest polygon within `default_extents`: twice the agent's radius across, and its height up and down. A point over a polygon by less than the agent's step height is on it, as in Detour.
- **Polygons** are named by their index in the blob. A polygon's tile is found by a binary search, because the tiles' runs of polygons follow each other, which `format.nav_mesh_view` checks. Heights come from each polygon's detail triangles.
- **`find_path`:** A* over the polygons. A polygon's node is at the middle of the portal that first reaches it, and the heuristic is the distance to the goal, scaled by 0.999. Ties go to the earlier node. The search reaches at most `max_nodes` polygons (`DEFAULT_MAX_NODES`, 2048). A goal that it does not reach, because no path goes there, because no polygon is near it, or because the nodes ran out, gives a `Partial` path to the point of the reached polygon nearest the goal. A start on no navmesh gives `Failed`. The funnel then pulls the straight path through the corridor's portals. A portal across tiles is only the part of the edge that its link covers.
- **`raycast`:** a walk on the xz plane from polygon to polygon across the edges that the segment leaves by. A link holds the walk only inside the part of the edge that it covers. It stops at the end, `t` is 1 and `wall` is none, or at an edge with nothing across, where `wall` is the edge's normal on the ground.
- **`random_point`:** a search outward from the start's polygon over the portals within `radius` of `around`. Each polygon that it reaches is drawn by its area, and then a point in the polygon. A polygon counts by its whole area, so the point can be outside the circle by up to a polygon's size. The same seed gives the same points.
- **Memory:** `find_path` and `random_point` take their scratch, and `find_path` its result, from `allocator`: a job's own `context.temp_allocator` by default, or frame memory from frame code.

## Path requests

`Nav_Path` (stable ID 129, in the AI's range) is an agent's path. The path itself is in `nav.State`'s pool, so the component stays far below `ecs.MAX_COMPONENT_SIZE`.

| Field | Who writes it | What it is |
|---|---|---|
| `agent` | The game | The agent type whose navmeshes the path is found on |
| `status` | The engine | `None`, no request; `Pending`; `Found`; `Partial`; or `Failed` |
| `corners` | The engine | The number of the path's corners |
| `path` | The engine | The path's slot in the pool, hidden in the editor and scripts |

- **Asking:** `nav.request_path(to, entity, goal)` asks for a path from where the entity is to `goal`. Frame code records into `nav.requests(s)`. A system's job records into `nav.job_requests(s, ctx)`, its own list, which the world flushes after the stage in system order and then job order. Scripts call `Navigation.request_path`. A new request replaces the entity's last one.
- **The system:** `nav paths` is a `Fixed` system that runs as one job. It reads `Transform` and writes `Nav_Path`. In each tick it:
  1. Frees the paths of entities that are gone, that lost their `Nav_Path`, or whose `Nav_Path` names another slot. It clears a `Nav_Path` that names a slot that is not its own, as a duplicated entity's does.
  2. Admits the new requests in order. Each goes to the back of the queue, and its `Nav_Path` becomes `Pending`.
  3. Queues again, at the back, each found path whose navmesh was recooked or unloaded, and starts again each search on one.
  4. Starts a search for each waiting request among the first `MAX_ACTIVE_SEARCHES` (8) of the queue, from where its entity is now. An entity on no navmesh of its agent type fails at once.
  5. Shares the tick's budget, `DEFAULT_TICK_NODES` (1024) searched nodes, equally among the searches, and runs each for its share on a job of its own.
  6. Writes the paths of the searches that finished, in the queue's order. A path is ready in the tick that its search finishes.
- **Reading:** `nav.path_corners(s, w, entity)` is the path's corners, from the start to its end, and `nav.path_corridor` its navmesh and polygons. They stay valid until the system runs again. `nav.set_budget` changes the budget.
- **In the tick:** the system runs with the other `Fixed` systems, before the scripts' `fixed_update`. A system that reads `Nav_Path` waits for it and sees its results in the same tick, and so do scripts. A request from a `Fixed` system's job is admitted in the next tick, after the flush. Edit mode runs no `Fixed` systems, so requests wait for Play.
- **Memory:** each search keeps its nodes, at most `MAX_PATH_NODES` (2048), in buffers that `init` reserves on the host's heap. A found path's corners and corridor are on the host's heap too, so a code reload keeps them.
- **Tickets:** a request can carry a ticket, which its path keeps. The crowd gives each of its requests the tick that it asks in, and takes only the path of its last request.

## Crowds

An agent of the crowd goes where it is sent: along its path, around the other agents and the walls near it, until it stops within its stopping distance of its target. The crowd is in `lib/engine/nav` (`crowd.odin`, `corridor.odin`, `avoid.odin`). It follows [DetourCrowd](https://github.com/recastnavigation/recastnavigation/tree/main/DetourCrowd) for the corridor and the sampling, but not its code.

| Component | ID | Who writes it | What it is |
|---|---|---|---|
| `Nav_Agent` | 134 | The game | `agent`, the agent type; `max_speed`, in m/s; `acceleration`, in m/s²; `radius`, the circle that avoidance keeps; `priority`, 0 to 255; `stopping_distance`, in meters |
| `Nav_Agent_State` | 135 | The engine | `status`, `velocity` and `desired`, which scripts and the editor read, and `crowd`, the agent's slot, hidden |

- **What it needs:** a `Nav_Agent` needs a `Character` on the same entity ([Physics: Characters](../physics/design.md#characters)). An agent without one is warned about once, and does not move. The crowd gives each agent a `Nav_Path` of its agent type, which its path requests use ([Path requests](#path-requests)).
- **The state:** each agent's corridor and steering are in a slot of `nav.State`'s crowd, on the host's heap, keyed by `Nav_Agent_State.crowd`. A slot is freed with its entity or its `Nav_Agent`. A duplicated entity gets its own slot, and starts `Idle`. An agent does not need an `Agent` ([Agents](agents.md#agents)): scripts and frame code can move it alone.
- **Moves:** `nav.move_to(to, entity, target)` sends an agent to a target, a `World_Position` or an `Entity` that it follows. `nav.stop(to, entity)` slows it to a stop where it is. Frame code and scripts record into `nav.crowd_requests(s, w)`, and a system's job into `nav.job_crowd(s, ctx)`, which flushes after the stage in system order and then job order. The next crowd tick applies them. A move gives a ticket, the tick that it was asked in, and `nav.crowd_move(s, w, entity)` gives the agent's move: its ticket, its target and its status. A new move replaces the last one. A stop with a ticket stops only that move.
- **Status:** `Idle` before the first move and after a stop; `Moving`; `Arrived` within the stopping distance of the target; and `Failed` when no path starts where the agent is, or when the agent reached the end of a partial path and its target did not move. An agent that arrived at an entity follows it again when the entity moves away.

### The crowd system

`nav crowd` is a `Fixed` system after `nav paths` and, with the agents' AI, after `ai actions`. It reads `Nav_Agent`, `Nav_Path`, `Transform`, `Character` and `Physics_Character`, and writes `Nav_Agent_State`. In each tick it:

1. **Keeps the pool:** frees the slots of agents that went, and gives new agents and copies their slots.
2. **Applies the moves and stops** in their order. A move asks for its path at once. An agent that follows a path keeps following it until the new one comes.
3. **Takes the paths** that the agents asked for, which `nav paths` solved in this tick or before: `Found` or `Partial` to follow, or `Failed`.
4. **Takes a snapshot** of every agent with a character, in the order of the slots: where it is, its character's velocity, and the velocity that it wanted in its last tick. It puts them in a grid of 4 m cells.
5. **Steers the agents on jobs** of `CROWD_BATCH` (16). Each agent fixes its corridor, finds its next corners, steers, and avoids. A job writes only its agents' slots and results.
6. **Applies the results** in the order of the slots: the phases, the paths that the agents ask for, and the velocities, which go to `physics.character_move`.

A new agent's `Nav_Agent_State` is added at the end of its first tick, with that tick's status.

### Following

- **The corridor** is the polygons of the agent's path, from the one that it stands on to its path's end, as DetourCrowd's `dtPathCorridor`.
- **The start follows the agent:** each tick, a walk along the surface from the corridor's start toward where the character is now gives the polygons that it crossed, as Detour's `moveAlongSurface`. They replace the corridor up to the last polygon that both have, as `dtMergeCorridorStartMoved` does. A push back over polygons that the agent left puts them in front of it again, so it walks back to its path.
- **Shortcuts:** a straight walk along the navmesh toward the corner after next, up to 30 radii ahead, cuts the corridor to the polygons that it crossed, when nothing stops it, as `optimizePathVisibility` does.
- **Corners:** the funnel over the corridor gives the next corners, up to `MAX_CORNERS` (4). Corners within 1 cm of the agent are passed.
- **New paths:** an agent asks for a new path when its target moved more than twice its radius, and at least 0.5 m, from where it was when the agent last asked; when a push took it off its corridor; and when its navmesh was recooked or unloaded. It asks at most every 0.5 s.
- **Steering:** from the agent's point on the navmesh toward the next corner at `max_speed`. Toward the last, the speed is at most `sqrt(2 · acceleration · distance)`, so the agent slows to a stop. Within `stopping_distance` of the path's end it has `Arrived`. An agent that was pushed more than 2 cm off the navmesh also steers back onto it, to be there in a quarter of a second, so it does not walk into the wall beside it.

### Avoidance

- **Neighbors:** up to `MAX_NEIGHBORS` (6) agents within 12 radii on the ground and 2 m up or down, from the grid, nearest first and then by slot.
- **Walls:** the edges with nothing across, and the parts of edges that no link covers, of the polygons within 12 radii: the 16 nearest, as Detour's `getPolyWallSegments` gives them.
- **Separation:** an agent that moves keeps away from the neighbors within twice their radii together, less the farther they are, as DetourCrowd's separation does.
- **Sampling:** as DetourObstacleAvoidance's adaptive sampling at its high quality: 7 divisions, 2 rings and 5 levels of depth around the desired velocity. A sample's penalty weighs its distance from the desired and the current velocities, the side that it passes the neighbors on, and how soon, within 2.5 s, it hits a neighbor or a wall.
- **Priority:** an agent takes half the avoidance of a neighbor of its own priority, as DetourCrowd's reciprocal avoidance does, and all of it for a neighbor of a higher priority. It ignores a neighbor of a lower priority in its sampling and its separation, so the higher priority keeps its way.
- **Acceleration:** the chosen velocity changes the character's current velocity by at most `acceleration` times the tick, and is at most `max_speed`.

## Movement

- **Through the character:** the chosen velocity's x and z go to `physics.character_move` with `gravity`, so the backend keeps the agent on the ground, on slopes and steps, and against walls ([Physics: Characters](../physics/design.md#characters)). The move applies in the tick's physics step.
- **From where the character is:** the next tick reads the character's `Transform` and its `Physics_Character.velocity`. The corridor follows the agent to where it actually is, and its acceleration starts from the velocity that it actually has. An agent that is pushed, or slides along a wall, does not drift off the navmesh: it walks back to its corridor, or asks for a new path from where it is.
- **Animation:** `Nav_Agent_State.velocity` is the velocity that the agent chose, and `desired` the one that its path asked for. A script or a system can set an Animator's parameter from them, such as a speed from `Navigation.velocity(entity)` ([Animation: Scripts](../animation/design.md#scripts)).
- **Actions:** the native actions `move_to` and `stop` move an agent from its decision ([Agents: Native actions](agents.md#native-actions)).
- **The sample:** `samples/mygame`'s doorway scene, which F7 cycles to, has twenty agents on one side of a wall that walk through its doorway, 2 m wide, to the other side, wait for each other, and walk back. `crosser.luau` only sends them, with `Navigation.move_to`.

## Determinism

A path is the same on every run, on one job or many, and with any budget:

- A search's nodes depend only on its start, its goal and the navmesh. The open list breaks ties by the node's index, and a search pauses only between nodes.
- The order of requests comes from the order of the frame code, and from the job buffers' flush, which does not depend on the jobs' timing. Nothing is ordered by an `Entity` value.
- Each job writes only its own search. The system writes the results in the queue's order, after every job is done.

The budget changes only the tick that a path is ready in. The tests compare the paths of the same requests on one job, on eight workers, and with budgets of 8 and 10000 nodes.

The crowd is the same on one job or many. The snapshot and the grid are taken in the order of the slots before the jobs start, and the jobs only read them. Each agent writes only its own slot. The system applies the results, the path requests and the characters' moves in the order of the slots. Neighbors are ordered by distance and then by slot. The tests compare 40 agents that cross a doorway on one job and on eight workers, on Jolt.

## Scripts

The `Navigation` library takes the agent type by its name. A name that no loaded navmesh has finds nothing.

| Binding | What it does |
|---|---|
| `Navigation.nearest(point, agent, extents?)` | The nearest point on the navmesh, or nil |
| `Navigation.find_path(start, goal, agent, max_nodes?)` | A `NavPath`: `status`, `"found"`, `"partial"` or `"failed"`, and `corners`. It is synchronous, for a few calls. |
| `Navigation.raycast(start, finish, agent)` | A `NavRaycastHit`, `t`, `position` and the wall's `normal`, or nil for a start on no navmesh |
| `Navigation.random_point(around, radius, agent)` | A reachable point, drawn from the world's `Random` state, so `Random.seed` repeats it |
| `Navigation.request_path(entity, goal)` | Asks for the entity's path, as `request_path` does. The entity needs a `NavPath`. |
| `Navigation.path(entity)` | The entity's path's corners, found or partial, or nil |
| `Navigation.move_to(entity, target)` | Sends the agent to a `WorldPosition` or an `Entity`, as `move_to` does. The entity needs a `NavAgent`. |
| `Navigation.stop(entity)` | Stops the agent |
| `Navigation.arrived(entity)` | Whether the agent arrived at its target |
| `Navigation.velocity(entity)` | The velocity that the agent chose in its last tick, a `vector` in m/s |

`NavPath`, `NavAgent` and `NavAgentState` are exposed to scripts. `NavPath`'s `status` and `corners` and `NavAgentState`'s fields are read-only. A move from a script applies in the next tick.

## Drawing

- **In the editor:** in Edit, the viewport's helpers draw the navmeshes of a selected navigation volume from the cooked blobs, each agent type in its own color: the edges between polygons faintly, the walls brightly, the links across tiles in white, and the tiles' borders in grey ([Editor: Viewport](../editor/viewport.md#viewport)).
- **The Navigation Path tool** picks a start and a goal with two clicks in a scene view ([Editor: Viewport: Navigation path](../editor/viewport.md#navigation-path)). The helpers draw the two points, and the path between them for each loaded agent type, faintly when it is partial. A selected entity with a `Nav_Path` draws its own path from where it stands to the tool's goal.
- **Agents:** in Edit, a selected `Nav_Agent` draws its avoidance radius at its feet. In Play and Paused, a selected agent draws its last tick with `nav.draw_agent`: its corridor's polygons, its next corners, a line to each neighbor that it avoided, and its desired velocity in blue and its chosen one in green, as arrows a second long.
- **In a game:** `nav.draw_volume(s, d, volume)` draws a volume's navmeshes, `nav.draw_corners` a path's corners, `nav.draw_path` an entity's path, and `nav.draw_agent` an agent's last tick, into a `debug.Draw`.

## Limits

- **One navmesh at a time:** a path or a raycast stays on the navmesh of its start. Paths across navmeshes of different volumes are not found.
- **Corners:** the funnel is the shortest path through the corridor that A* found, which does not always hold the straight line. A path can turn where the corridor bends. The crowd's shortcuts straighten it as the agent walks.
- **Crowds:** no formations or groups that move together, and no off-mesh links. Agents avoid each other and the navmesh's walls, not dynamic bodies, which their characters push or are pushed by. An agent stands still while it waits for its first path, a tick or more.
- **Heights:** Recast lifts its detail meshes a cell up, so a point on the navmesh is about one `cell_height` above the floor, as in Detour.
- **Raycasts** along a wall's edge stop at once, as Detour's do.
- **Not supported:** areas and their costs, off-mesh links, and obstacles at runtime ([Content: Navmeshes: Limits](../content/kinds/nav-meshes.md#limits)).
- **Drawing:** in Play and Paused, only the selected agents draw. The navmeshes and the Navigation Path tool draw in Edit only.

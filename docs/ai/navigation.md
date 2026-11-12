# Navigation

How agents find their way at runtime: the navmeshes of a scene load with it, queries find points and paths on them, and path requests are solved on jobs in fixed ticks within a budget. The cooker bakes the navmeshes with Recast ([Content: Navmeshes](../content/kinds/nav-meshes.md)). The runtime, in `lib/engine/nav`, is the engine's own Odin, with nothing of Detour linked. Read [Hot reload](../overview/hot-reload.md#rules), [Core: Jobs and memory](../core/jobs-and-memory.md), [World: ECS](../world/ecs.md) and [Positions and transforms](../world/positions-and-transforms.md) first.

**In this document:** [Design](#design) · [Loading](#loading) · [Queries](#queries) · [Path requests](#path-requests) · [Determinism](#determinism) · [Scripts](#scripts) · [Drawing](#drawing) · [Limits](#limits)

## Design

1. **The runtime is the engine's own.** The queries follow Detour's `dtNavMeshQuery` (`findNearestPoly`, `findPath`, `findStraightPath`, `raycast` and `findRandomPointAroundCircle`), but read the engine's blob ([Content: Navmeshes: The blob](../content/kinds/nav-meshes.md#the-blob)). Nothing has static state, so a code reload keeps all of it.
2. **The state holds handles, not blobs.** `nav.State` in `Game` holds the asset handles of the scene and its navmeshes, and plain data for the path requests. Each frame, `prepare` reads the loaded blobs into the frame's views, and `end_frame` lets them go before `asset.poll` can swap a blob.
3. **Queries only read.** Their scratch memory is the allocator they are given, so frame code, any number of jobs and scripts can query at once.
4. **Positions are `World_Position`s outside, and `f32` inside**, in meters relative to the navmesh's anchor, the center of its volume. A query converts each point once.
5. **Path requests spread over ticks.** A `Fixed` system solves the queued requests on jobs, a few searches at a time, within a budget of searched nodes in each tick. A search stops only between nodes, so its path does not depend on the budget or the number of jobs, only the tick it is ready in.

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

## Determinism

A path is the same on every run, on one job or many, and with any budget:

- A search's nodes depend only on its start, its goal and the navmesh. The open list breaks ties by the node's index, and a search pauses only between nodes.
- The order of requests comes from the order of the frame code, and from the job buffers' flush, which does not depend on the jobs' timing. Nothing is ordered by an `Entity` value.
- Each job writes only its own search. The system writes the results in the queue's order, after every job is done.

The budget changes only the tick that a path is ready in. The tests compare the paths of the same requests on one job, on eight workers, and with budgets of 8 and 10000 nodes.

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

`NavPath` is exposed to scripts, with `status` and `corners` read-only.

## Drawing

- **In the editor:** in Edit, the viewport's helpers draw the navmeshes of a selected navigation volume from the cooked blobs, each agent type in its own color: the edges between polygons faintly, the walls brightly, the links across tiles in white, and the tiles' borders in grey ([Editor: Viewport](../editor/viewport.md#viewport)).
- **The Navigation Path tool** picks a start and a goal with two clicks in a scene view ([Editor: Viewport: Navigation path](../editor/viewport.md#navigation-path)). The helpers draw the two points, and the path between them for each loaded agent type, faintly when it is partial. A selected entity with a `Nav_Path` draws its own path from where it stands to the tool's goal.
- **In a game:** `nav.draw_volume(s, d, volume)` draws a volume's navmeshes, `nav.draw_corners` a path's corners, and `nav.draw_path` an entity's path, into a `debug.Draw`.

## Limits

- **One navmesh at a time:** a path or a raycast stays on the navmesh of its start. Paths across navmeshes of different volumes are not found.
- **Corners:** the funnel is the shortest path through the corridor that A* found, which does not always hold the straight line. A path can turn where the corridor bends. Following a path and avoiding other agents are not built.
- **Heights:** Recast lifts its detail meshes a cell up, so a point on the navmesh is about one `cell_height` above the floor, as in Detour.
- **Raycasts** along a wall's edge stop at once, as Detour's do.
- **Not supported:** areas and their costs, off-mesh links, and obstacles at runtime ([Content: Navmeshes: Limits](../content/kinds/nav-meshes.md#limits)).
- **Drawing** is in the editor's Edit only. Play and Paused have no helpers.

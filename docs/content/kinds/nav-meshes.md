# Navmeshes

A navmesh is the polygons that agents of one type walk on. The cooker bakes navmeshes with Recast from a scene's static colliders, inside each navigation volume of the scene (see [Recast](#recast)). A navmesh is a sub-asset of its scene, with its GUID on a line of the scene's `.meta` file (see [Identity](../identity-and-cooking.md#identity)), and the scene's blob lists it, so a level's bundle holds it. A scene without a volume bakes nothing. `just navmeshes` runs `cook navmeshes --cache build/<target>/content --config dev|release` with the roots, after the scenes and the meshes cook. `just build`, `cook all` and the cook daemon run it after the meshes too.

**In this document:** [The volume](#the-volume) · [Agent types](#agent-types) · [Sub-assets](#sub-assets) · [Input](#input) · [The bake](#the-bake) · [The blob](#the-blob) · [Recast](#recast) · [Limits](#limits)

## The volume

`Nav_Mesh_Volume` (stable ID 128, the first of the AI's range, 128 to 143) goes on an entity with a [`Volume`](../../world/volumes.md#volumes) whose shape is `Box`. The box is the bake's extents: its center, and its extents times the entity's scale, with an extent of 0 meaning 5 m. A volume of another shape is a warning, and it bakes nothing. So does an inactive entity's.

| Field | Default | What it sets |
|---|---|---|
| `agents` | `0` | The agent types that it bakes for: bit `i` is the `i`-th type of `nav.agents`. 0 bakes for every type. A bit past the project's types is a warning. |
| `cell_size` | `0.2` | The size of a cell of the bake's grid across, in meters. Smaller cells follow edges closer, and bake slower. |
| `cell_height` | `0.1` | The size of a cell up, in meters. The agents' heights and steps round to it. |
| `tile_size` | `64` | The cells along a tile's edge, from 8 to 1024. Each tile bakes on its own (see [The bake](#the-bake)). |

The struct and its defaults are in `lib/engine/asset/format/components.odin`, which `lib/engine/nav` registers and the cooker reads. Volumes that overlap bake separate navmeshes. A rotated volume bakes the box along the world's axes that holds it.

## Agent types

The project's settings name the agent types that navmeshes bake for (see [Project settings](../../overview/architecture.md#project-settings)):

```
nav.agents = Human, Small
nav.agent.Human.radius = 0.3
nav.agent.Human.height = 1.8
nav.agent.Small.radius = 0.15
```

- **Without `nav.agents`** there is one type, `Default`.
- **Each type** has a `radius`, a `height` and a `step_height` in meters, and a `max_slope` in degrees. A type that a line does not set has the defaults: 0.4 m, 1.8 m, 0.35 m and 45 degrees.
- **A name** has only letters, digits and `_`, at most 31 of them. There are at most 32 types.
- **Problems:** a name that is not valid or that `nav.agents` does not give, a field that a type does not have, or a number that is not above 0, or for `max_slope` below 90, is a warning. The value keeps its default. `lib/engine/project` checks each line. The cooker reads `project.settings` and then `project.user.settings` from the folder above the content root named `game`, with `format.nav_agents_parse`. A later line wins.
- **Inputs:** a scene with a volume keeps both files as its inputs, so the cook daemon cooks it and its navmeshes again when they change.

Recast bakes each type on its own: the agent's radius erodes the walkable area, its height leaves out what is under a lower ceiling, its step joins surfaces at most that far apart up or down, and a triangle steeper than its slope is not walkable.

## Sub-assets

| Kind | Line in the scene's `.meta` file | Blob |
|---|---|---|
| Navmesh | `navmesh.<volume's scene ID>.<agent type>`, such as `navmesh.3b9d7e21c4a8f650.Human` | Baked by the navmesh pass |

- **GUIDs:** the scene's cook gives each navmesh its GUID, which the `.meta` file keeps, so a bake again keeps it. A volume or a type that goes leaves its line with a warning, until the scene is re-imported.
- **The scene's blob** lists its navmeshes, as `Scene_Nav_Mesh` records of the volume's scene ID, the agent type's name and the GUID. `format.scene_nav_meshes` reads them, and `format.blob_references` names them, so a level's bundle holds them (see [Bundles](../blobs-and-loading.md#bundles)). The scene's key covers the list, and leaves the `.meta` file's sub-asset lines out.
- **Prefabs** bake nothing. A volume in a prefab bakes when a scene instantiates it, under its scene ID in the expanded scene.

## Input

The cooker cannot lay out native components, so it reads the physics components from the scene's text, by their stable IDs and their fields' names, over the defaults in `format/components.odin`: `Transform`, `Local_Transform`, `Collider`, `Rigid_Body`, `Character`, `Volume` and `Nav_Mesh_Volume`. `lib/engine/physics`, `lib/engine/volume` and `lib/engine/ecs` register their components with the same structs and defaults.

- **The scene is expanded** first, as its cook expands it, so prefab instances and a stage's prefab count.
- **Poses** are composed as propagation composes them: a root's `Transform`, and a child's `Local_Transform` on its parent's pose. A child without a `Local_Transform` keeps its `Transform`.
- **Static colliders count:** a `Collider` that is not a sensor, on an active entity whose ancestors are active, without a `Character`, and either without a `Rigid_Body` on it or above it, or whose own or nearest ancestor's `Rigid_Body` is `Static` (see [Physics: Components](../../physics/design.md#components)). Kinematic and dynamic bodies do not.
- **Shapes** are triangulated at their scale, as the physics sync scales them: a box as 12 triangles, a sphere, a capsule and a cylinder with 16 segments around y.
- **Mesh and convex colliders** take the cooked mesh's collision data (see [Physics: Shapes](../../physics/design.md#shapes)). A convex collider bakes as its triangles, not their hull. A mirroring scale turns the triangles back the right way. A mesh that is not cooked, or that has no collision data, is a warning, and its collider is left out. The mesh is one of the scene's dependencies, so a change to it bakes again.
- **Positions** are `World_Position`s. The bake works in `f32` relative to the volume's center, which the blob keeps as its anchor. Each triangle that reaches the volume, or the widest agent's border past it across, goes in, in the scene's order.

## The bake

- **Tiles:** a navmesh is a grid of tiles over the volume's bounds, `tile_size` cells on a side, the last row and column cut at the bounds. Each tile reads the triangles that reach it and its border, which is the agent's radius and 3 cells more, so the polygons of two tiles meet along their edge.
- **Recast**, for each tile:
  1. A heightfield, with the triangles that the agent's slope allows marked walkable.
  2. Filters: low obstacles that the agent steps over, ledges, and spans with less headroom than its height.
  3. A compact heightfield, eroded by the agent's radius.
  4. Watershed regions, in which one of fewer than 64 cells goes and one of fewer than 400 joins a neighbor.
  5. Contours at most 1.3 cells off the regions' edges and with edges of at most 12 m.
  6. Convex polygons of up to 6 vertices, and a detail mesh that samples every 6 cells and is at most a cell high off the surface.
- **Keys:** each tile has its own key. The key covers the cooker's and Recast's versions, the tile's place, the agent's and the volume's settings, and the bytes of the triangles that reach it. An edit therefore changes only the keys of the tiles that it reaches. The navmesh's key covers its tiles' keys, its GUID, its anchor, its volume and its agent type.
- **Up to date:** a navmesh whose key is its blob's is up to date. Otherwise each tile whose key is its old blob's tile's is kept, and the others bake. Moving a wall bakes again the tiles under it, before and after, and keeps the rest.
- **Threads:** the tiles to bake run on a thread for each core, the ones with the most triangles first. Each writes its own slot, and the tiles join in their order, so the blob is the same on one thread and on many.
- **Joining tiles:** a polygon's edge on its tile's border links to each polygon of the next tile whose edge overlaps it there, at heights within the agent's step and a cell of each other. A vertex's place across is its cell in the volume's grid, so the two tiles give their shared edge the same positions.
- **Failure:** a tile that Recast cannot bake is an error on the scene, and the navmesh keeps its old blob.

## The blob

`format/nav_mesh.odin` is the engine's own layout, not Detour's. The runtime reads it without Recast or Detour.

| Part | What it holds |
|---|---|
| `Nav_Mesh_Blob` | The anchor (the volume's center, a raw `World_Position`), the volume's scene ID, the bounds relative to the anchor, the agent type's name, its settings and its index in the project's types (`agent_index`, the runtime's `Agent_Type`), the cell sizes, the tiles' size in meters, and the grid's `tiles_x` by `tiles_z` |
| `Nav_Tile` | Each tile, row by row from -z: its place, its bounds, its key, and its runs of the streams below |
| vertices | `[3]f32`, relative to the anchor, each tile's run |
| `Nav_Polygon` | Up to 6 of its tile's vertices, and across each edge a polygon of the tile, `NAV_NONE`, or `NAV_EXTERNAL` with the side of the tile; its run of links |
| `Nav_Link` | A border edge's polygon in the next tile, by its index in the blob, and the part of the edge, out of 255, that it covers |
| `Nav_Detail` | Each polygon's run of detail vertices and triangles, which give the height of its surface |
| detail triangles | `[4]u8`: three of the polygon's detail vertices and Recast's edge flags |

`format.nav_mesh_view` checks the blob: every stream inside it and aligned, the tiles in their grid, each tile's polygons right after the last tile's, and every index inside its run. A navmesh names no other asset.

## Recast

Recast is the submodule `vendor/recastnavigation` (github.com/recastnavigation/recastnavigation), pinned to a release, and `just update-recast <tag>` moves the pin. `just recast` builds Recast's own sources with `tools/cook/recast/CMakeLists.txt`, with `cn_recast.cpp`, the cooker's C interface to it (`cn_recast.h`), which `tools/cook/recast.odin` binds. One call bakes one tile from its triangles and settings and gives back its polygon mesh and detail mesh, which a second call frees. Each call has its own memory, so tiles bake on many threads at once. Only `tools/cook` links it: Detour, DetourCrowd and DetourTileCache are not built, and the runtime links none of it.

## Limits

- **Not baked:** areas and their costs, such as water or a road; off-mesh links, such as jumps and ladders; and joining volumes that overlap.
- **At runtime:** obstacles, and baking again while the game runs. The runtime loads navmeshes with their scene and finds paths on them ([AI: Navigation](../../ai/navigation.md)).
- **Drawing:** the editor draws a selected volume's navmeshes ([AI: Navigation: Drawing](../../ai/navigation.md#drawing)).
- **Geometry above the volume** is cut off, so a ceiling above the box does not limit the headroom under it. A surface inside the box with nothing above it, such as a room's roof, is walkable, so keep the box's top under a ceiling: the sample's main scene ends its volume at 1.95 m, under the room's ceiling at 2 m.
- **A polygon** has at most 255 links.

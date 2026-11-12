# AI

How agents find their way: the navmeshes that the cooker bakes, loaded with their scene, the queries on them, and the path requests that systems solve on jobs, in `lib/engine/nav`. Read [World](../world/README.md), [Physics](../physics/README.md) and [Content: Navmeshes](../content/kinds/nav-meshes.md) first.

## Documents

| Document | What it covers |
|---|---|
| [Navigation](navigation.md) | Loading a scene's navmeshes, the queries (`nearest`, `find_path`, `raycast`, `random_point`), path requests and their budget, determinism, the `Navigation` script library, drawing in the editor, and the limits. |

## Overview

| Package | Side | Responsibility |
|---|---|---|
| `tools/cook` (navmeshes) | Tool | Bakes a navmesh for each navigation volume and agent type with Recast (see [Content: Navmeshes](../content/kinds/nav-meshes.md)). |
| `lib/engine/nav` | Game | `Nav_Mesh_Volume` and `Nav_Path`, loading, the queries, the path requests and their system, the script library, and drawing. |
| `lib/engine/random` | Game | The engine's generator, xoshiro256**, which `random_point` and the scripts' `Random` draw from. |

The data flow in a frame: `nav.prepare` loads the navmeshes of the world's scene when the scene changes, and reads the loaded blobs into the frame's views. The queries read the views, from frame code, systems' jobs and scripts. In each fixed tick, the `nav paths` system admits the requests, runs the searches on jobs for their share of the node budget, and writes the paths that finished to their `Nav_Path`s. `nav.end_frame` lets the views go before the assets poll for recooked blobs.

## References

- Mikko Mononen, [Recast and Detour](https://github.com/recastnavigation/recastnavigation): the bake, and Detour's `dtNavMeshQuery` (`findPath`, `findStraightPath`, `raycast`, `findRandomPointAroundCircle`) and its sliced path finding, which the queries and the path requests follow. The engine's code is its own.
- David Blackman and Sebastiano Vigna, [*Scrambled Linear Pseudorandom Number Generators*](https://prng.di.unimi.it/): xoshiro256**, the generator in `lib/engine/random`.

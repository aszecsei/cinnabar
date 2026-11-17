# Worlds

Worlds are `.world` text files in the content roots. A world lists the scenes that stream in and out as the camera moves. Each scene has its bounds and its load and unload distances, or it is always loaded.

`just worlds` runs `cook worlds --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks worlds like any other kind (`tools/cook/worlds.odin`).

How the runtime streams the scenes is in [World: Streaming](../../world/streaming.md).

```
world 1
# The town is always loaded. The forest streams.
scene $0123456789abcdef0123456789abcdef
	persistent = true
scene $fedcba9876543210fedcba9876543210
	min = [150000000000, -10, -20]
	max = [150000000040, 10, 20]
	load_distance = 25
	unload_distance = 40
```

## The text

- **The first line** is `world 1`. A `#` starts a comment, except inside quotes.
- **`scene $<guid>`** starts a scene. The GUID is the 32 hex digits of a scene asset. A world names each scene once, and has at most `MAX_WORLD_SCENES` (1024) scenes.
- **The lines after it** are the scene's settings, `<name> = <value>`. A setting comes once for each scene.

| Setting | Value | Meaning |
|---|---|---|
| `persistent` | `true` or `false` | The scene loads with the world and never unloads. The default is `false`. |
| `min` | Three numbers | The lower corner of the scene's bounds, in meters |
| `max` | Three numbers | The upper corner of the scene's bounds, in meters |
| `load_distance` | One number | The scene loads when the camera is this many meters from its bounds. It is more than 0. |
| `unload_distance` | One number | The scene unloads when the camera is farther than this. It is at least `load_distance`. The default is `load_distance` times `DEFAULT_UNLOAD_FACTOR` (1.25). |

A scene that is not persistent needs `min`, `max` and `load_distance`. A persistent scene needs none of them, and the cooker ignores them.

Each axis of `min` is at most the same axis of `max`. The numbers are `f64` in the text. The cooker converts each coordinate to `World_Position` units (2^-24 m) and rounds it to the nearest unit. Scaling by a power of two is exact, so the blob keeps the position that the `f64` holds, also at 1.5e11 m from the origin. A coordinate outside the range of a `World_Position` is a problem.

The cooker checks that each GUID names an asset, and that the asset is a scene. It adds each GUID to the world's dependencies, so fixing a scene cooks the world again.

## The blob

A `World_Blob` (`lib/engine/asset/format/world.odin`) holds:
- **The scenes**, in the order of the text. Each `World_Scene_Record` has the scene's GUID, `min` and `max` as three `i64` each in `World_Position` units, `load_distance` and `unload_distance` as `f32` in meters, and its flags. The flag `.Persistent` marks a persistent scene, whose bounds and distances are 0.
- **The source path.**

`world_view` checks the kind, the layout and that every slice is inside the blob. `blob_references` gives the GUID of each scene.

In a release, each scene that is not persistent is a streaming chunk with a bundle of its own. The world and its persistent scenes go in the bundle of the level that names the world (see [Blobs and loading: Bundles](../blobs-and-loading.md#bundles)).

- **Problems** have their line. They include:
  - a first line that is not `world 1`;
  - a `scene` line without a GUID of 32 hex digits, or a scene that the world names twice;
  - a setting before the first scene, an unknown setting, or a setting that a scene gives twice;
  - a value of the wrong type, or a coordinate outside the range of a `World_Position`;
  - a scene that is not persistent without `min`, `max` or `load_distance`;
  - `min` above `max` on an axis, a `load_distance` that is 0 or less, or an `unload_distance` below `load_distance`;
  - a GUID that names no asset, or an asset that is not a scene;
  - more than `MAX_WORLD_SCENES` scenes.

  A world with a problem keeps its old blob, so the running game keeps the last good version.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID.
- **The editor** opens a world in the script editor. It is among the scenes in the content browser.

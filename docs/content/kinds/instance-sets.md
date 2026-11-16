# Instance sets

An instance set is the poses that an `Instanced_Mesh_Renderer` draws its mesh at: a forest, a field of grass, a scatter of rocks. It is an `Instance_Set` asset. Two sources make one: an `.instances` text file in the content roots, which this page describes, and a USD stage's point instancer, which the cooker keeps as a sub-asset of its stage (see [Stages](stages.md#point-instancers)). Both cook to the same blob. The editor's landscape foliage brush writes `.instances` files (see [Editor: Landscape](../../editor/landscape.md#foliage)), and the game can build the blob from poses at run time with the same code.

`just instance-sets` runs `cook instance-sets --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`. The daemon cooks instance sets like any other kind, and `just build` runs the recipe after the stages.

An `Instanced_Mesh_Renderer` names its set by GUID. Several renderers can share one set. How the renderer draws the instances is in [Rendering: GPU scene](../../rendering/gpu-scene.md#instanced-meshes).

```
instances 1
# Each line is an instance: its position x y z in meters, its rotation as a quaternion x y z w, and its scale x y z,
# relative to the entity whose Instanced_Mesh_Renderer names the set.
i 1.5 0 -2 0 0.3826834 0 0.9238795 1 1 1
```

## The text

- **The first line** that is not a comment or blank is `instances 1`. A `#` starts a comment.
- **Each other line is an instance:** `i` and exactly 10 numbers. The first three are its position in meters, the next four its rotation as a quaternion `x y z w`, and the last three its scale. The poses are relative to the entity whose `Instanced_Mesh_Renderer` names the set.
- **A rotation** is normalized when it is read. It must not be zero, and every number must be finite.
- **A set with no instances**, the header alone, is valid.

## What the cooker does

- **The point** of an instance is its line's place among the instances, from 0.
- **Each pose is packed** as a stage's are: the position as three `f32`, the rotation as a unit quaternion with `w` at least 0 in snorm16, and the scale in `f16` (`format.instance_pack`).
- **The cells.** The instances are ordered along a Morton curve over their positions, and each run of `INSTANCE_CELL_SIZE` (256) becomes a cell with a sphere about its instances and the largest scale of their axes, so culling can test a cell before its instances. The blob also has a sphere about every instance (`format.instance_cells`). The blob's instances are in the cells' order, not the file's.
- **The blob** is the `Instance_Set_Blob` that a stage's instance sets are (see [Blobs and loading](../blobs-and-loading.md#blob-format)), named for the file, with the source path. `format.instance_set_view` checks it.
- **Problems** have their line: a first line that is not `instances 1`, a line that is not `i` and 10 numbers, a number that is not one or not finite, and a rotation of zero length. An instance set with a problem keeps its old blob, so the running game keeps the last good version.
- **The cache key** covers the cooker version, the layout, the source path, the source and the GUID.
- **A new file** gets a `.meta` file with its GUID, which is committed with it.

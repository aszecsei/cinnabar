# Surfaces

Patch surfaces: a world-space rectangle that the GPU draws as grid patches, fine near the camera and coarse far from it, with holes, shaped by its material's displacement. Water and terrain are both one of these. Read [GPU scene](gpu-scene.md) and [Materials: Vertex displacement](materials.md#vertex-displacement) first.

**In this document:** [Surfaces](#surfaces) · [Selection](#selection) · [Patches](#patches) · [Holes](#holes) · [Materials for patches](#materials-for-patches) · [In the frame](#in-the-frame) · [Limits](#limits)

## Surfaces

A mesh's level of detail comes from its own simplification errors, which a flat plane has none of, and a mesh is as large as its file. A lake or a terrain needs a surface that is dense where the camera is and coarse where it is not, that stays in the world (a shoreline, a hole for a cave, an island), and that can be any size. That is a `Surface_Renderer` (`lib/engine/render/components.odin`, stable ID 51):

| Field | Meaning |
|---|---|
| `size` | Its extent in meters along its entity's x and z, about its position |
| `material` | A material with `geometry = patches` (see [Materials for patches](#materials-for-patches)), or the engine's default surface material |
| `hole_mask` | A `mask` texture over the rectangle: the surface has a hole where it reads 0 (see [Holes](#holes)); 0 for none |
| `cell` | The finest quad's size in meters (`DEFAULT_SURFACE_CELL`, 1 m, when 0) |
| `height_range` | How far below and above its plane the material's displacement reaches, in meters, for culling |
| `cast_shadows` | Whether its patches draw into the shadow maps |

Its entity's `Transform` places it, and it has a slot in the [GPU scene](gpu-scene.md#gpu-scene) like a `Mesh_Renderer`, so the render origin, last frame's pose, the entity ID and picking work as for a mesh. The surface is one draw item (`Cull_Item` with `ITEM_SURFACE`), whose draws the GPU adds: `lib/engine/render/surfaces.odin` holds the records and the passes.

## Selection

The surface is a quadtree. Its root is a square of `SURFACE_PATCH_QUADS` (16) finest cells times 2^(levels − 1), at the rectangle's least corner, with as many levels as it takes to cover the longer side, at most `MAX_SURFACE_LEVELS` (12). Each node is a patch of 16 × 16 quads of its level's cell, `cell × 2^level`.

`select_patches.hlsl` walks the tree each frame, one group of `SURFACE_GROUP_SIZE` (256) threads a surface, level by level through two queues in group memory, after Strugar's continuous distance-dependent level of detail:

- Level 0's range, `Surface_Record.range0`, is the distance at which a finest cell covers `SURFACE_CELL_PIXELS` (8) pixels, `cell × lod_scale / 8`, where `lod_scale` is the camera's pixels per meter at a distance of 1 over `Quality.lod_error` (see [Quality](quality.md#quality)), so a lower quality draws coarser patches. It is at least a patch, and at most what keeps every level's ring of patches within the item's reserved draws. Level L's range is `range0 × 2^L`.
- A node of level L splits while its box, the square between the surface's heights, is nearer the camera than level L − 1's range; a node outside the rectangle is dropped; the rest are the frame's patches. A node that the queues cannot hold draws as it is.
- The camera is `camera_local`, the camera in the surface's space, which the CPU computes from the instance's rows, so a turned or scaled surface selects right.
- Selection is by the camera only, with no frustum test, as the meshlets' levels are, so every view, the shadow maps' included, draws the same patches, and the prepass and the forward pass agree.
- The walk writes each surface's patches, `x | y << 12 | level << 24`, into a persistent buffer of `MAX_SURFACES` (16) × `MAX_SURFACE_PATCHES` (2048), and their count. `select_patches_reference` is the same walk on the CPU, for the tests.

`cull_patches.hlsl` then runs a thread for each patch, surface and view, after `cull_draws.hlsl`: it tests the patch's box, moved by the instance and grown by the material's displacement bound, against the view's planes, honours the casters' and the view model's rules, and takes the next draw of the surface's item's bin of that view, exactly as a mesh's item does, writing an indirect draw of `SURFACE_PATCH_VERTICES` (1536) vertices and a `Draw_Record` whose `first` is the packed patch and whose `mesh` is the surface's record. The item reserves `MAX_SURFACE_PATCHES` draws in its bin (`bin_sizes`), so the frame's draw buffers have room, and `draw_scene_view` draws the bin as any other.

## Patches

A patches material's vertex shaders build their vertices in `material_patch.hlsli`, which `material_vertex.hlsli` includes in place of `load_vertex` under `MATERIAL_PATCHES`:

- A vertex is a corner of a triangle of a quad of the grid, without an index buffer, so the draw is 16 × 16 × 6 vertices. Its position is in the surface's space, on the plane.
- **The morph.** Toward the far end of its level's range, from `SURFACE_MORPH_START` (0.7) of it, the grid's odd vertices slide onto their even neighbours, which are the next level's grid, by the vertex's own distance from the camera. Two patches of different levels then meet without a crack: the finer one's edge has become the coarser's. The morph moves the vertex on the plane before the displacement, so it holds for any displacement, since both levels displace the same point.
- The vertex then goes through `finish_vertex`, as a mesh's does: the instance's pose, and the material's `displace` at both poses (see [Vertex displacement](materials.md#vertex-displacement)). The patch's frame is the surface's x, its z and up: `normal` is up and `tangent` is x with a bitangent of z, so a tangent-space normal's x and y are along the surface's x and z. `uv0` is 0 to 1 across the rectangle, `uv1` is the position relative to the render origin on the plane over 1024 m, and the color is white.
- The `Meshlets` and `Lod_Depth` [debug views](post-processing.md#debug-views) color patches as they color meshlets: each in a color of its own, and by level.

## Holes

The hole mask is a `mask` texture over the rectangle, `uv0`'s space, cooked with `filter = box` (see [Content pipeline](../content/kinds/textures.md#textures)), so that a mip's texel is the share of its finest texels that are not holes, and reads 0 only where every one is. A quad reads the mask's mip of its level at its middle, so a quad of a coarse level is a hole only where every finest cell under it is, with a mask of one texel for each finest cell; a mask of another size is read at the nearest footprint. A quad that is a hole gives its triangles' vertices a NaN position, which the rasterizer does not draw. Hole edges are therefore the finest cells' edges. The default is the white texture, which has no holes.

## Materials for patches

A material draws patches when its `.material` says `geometry = patches` (see [Content pipeline](../content/kinds/materials.md#materials)). The cooker compiles its passes from the patch vertex path and leaves out the mesh shader path's entries, and the blob has the `Patches` flag, which `Material_Pipeline.patches` carries. A patches material on a `Mesh_Renderer` draws with the default material, and a mesh material on a `Surface_Renderer`, or no material, draws with the engine's default surface material (`lib/engine/content/materials/default_surface.material`), flat and grey.

A patches material shapes the surface with `displace`, usually along up: the sample's `water.material` sums three waves of the time on the position relative to the render origin, with wavelengths that divide 1024 m so the origin's moves leave no seam, and gives each pixel the waves' analytic normal; its `terrain.material` raises the vertices by a height map and takes the normal from the map's slope. Transparent, two-sided and masked materials all draw patches: the transparent passes use the same vertex path. The material editor previews a patches material as one patch a meter across at the mesh's place, whatever shape is chosen.

The sample's `surfaces.scene`, which F7 cycles to, is a lake with an island: a water surface with a hole over a terrain surface, 256 m across, with textures that `just sample-textures` writes.

## In the frame

- `build_scene` writes a surface's instance record as a mesh's, then its `Surface_Record` and its item, with its material's block and pipeline, the hole mask's bindless index or the white default's, and a sphere of its rectangle and its height range. After the bins are sorted, each record names its item.
- `add_scene_passes` sizes the draw buffers by the draws of a view, the bins' counts with the surfaces' reservations, and adds `select patches` after `update scene` and `cull patches` after `cull draws`, both with the culling's constants (`Cull_Constants`), which name the surfaces' records in the upload ring and the patches buffers.
- `Frame_Constants.surfaces` and `surfaces_offset` give the patch vertex shaders the records.

## Limits

- A surface is not in the ray tracing acceleration structure, so a traced shadow mask does not see it as a caster; it receives traced shadows, since the mask is from the depth buffer, and it casts and receives mapped shadows.
- It has no collision.
- It draws on the vertex-pulling path only: no mesh shaders, no vertex reuse, and no per-triangle culling of holes, which cost their vertex work.
- Hole edges are the finest cells' edges, and an 8-bit height map terraces at 1/255 of its scale.
- Selection is by the camera, so a shadow map far from it draws coarse patches there, as the meshlets do.
- A node at the queues' limit draws coarse; `range0`'s cap keeps a surface within it in the common case.

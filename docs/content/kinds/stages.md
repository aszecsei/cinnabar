# Stages

Stages are USD files: `.usda` text, `.usdc` crate and `.usd` of either kind, read with LightUSD, which TinyUSDZ is now named (see [LightUSD](#lightusd)). A stage is a `Stage` asset, which has no blob of its own: like a glTF model, it is a file of sub-assets, each with its GUID on a line of its `.meta` file (see [Identity](../identity-and-cooking.md#identity)). Unlike a model, a stage brings its whole scene: its meshes, the images and UsdPreviewSurface materials that they use, its point instancers' poses, and its prims as a prefab. `just stages` runs `cook stages --cache build/<target>/content --config dev|release` with the roots; the material and scene passes run it first too, so `just build` cooks stages without asking.

**In this document:** [Sub-assets](#sub-assets) · [Composition](#composition) · [Meshes](#meshes) · [Textures](#textures) · [Materials](#materials) · [Point instancers](#point-instancers) · [Prefab](#prefab) · [Cooking](#cooking) · [Import settings](#import-settings) · [LightUSD](#lightusd) · [Limits](#limits)

## Sub-assets

| Kind | Line in the `.meta` file | Blob |
|---|---|---|
| Mesh | `mesh.<prim path>`, or `mesh.<prim path>#<n>` for each part of a mesh that is split; a point instancer's prototype is `mesh.prototypes/<prim name>` | Cooked by the stage |
| Texture | `texture.<image path>@<role>`, such as `texture.main_sponza/textures/wall_Roughness.png@mask.r` | Cooked by the stage |
| Material instance | `material_instance.<material path>`, with `#two_sided` for a two-sided mesh's | Cooked by the material pass, from text that the stage generates |
| Instance set | `instance_set.<instancer path>`, or `instance_set.<instancer path>#<n>` for each mesh of an instancer whose prototypes have several | Cooked by the stage |
| Prefab | `prefab.stage` | Cooked by the scene pass, from text that the stage generates |

A prim path is the prim's absolute path without its leading `/`. An image path is from the folder that holds the stage's first sublayer's folder, as a download's, or else from the stage's own folder. Names are keys, so an `=` in one becomes `_`.

The material instances and the prefab are text, which the cooker writes to `<cache>/generated/stages/<guid>.material_instance` and `.prefab` and adds to the pass's assets as sources that the stage owns. The material and scene passes cook them as they would files, so nothing downstream tells them apart. They are not files of the content: the index lists them as the stage's sub-assets, and their problems are the stage's.

## Composition

LightUSD composes the stage: its sublayers, references, payloads, inherits, variants and specializes, the way its large-scene loader does. The stage's own folder is where its relative paths resolve, whatever the cooker's working directory. A sublayer path of the root layer may climb out of it with `..`, which LightUSD's own lookup refuses, and LightUSD's path check takes the drive off an absolute Windows path, so the cooker gives each of the root's sublayers its file's name and puts its folder among the root layer's search paths. That lets a stage in the content wrap files kept elsewhere, as a sample's downloads are (see [samples/intel](../../../samples/intel/README.md)).

- **Only the root layer's** `upAxis` and `metersPerUnit` count, so a stage that wraps another restates them.
- **A missing root sublayer** is a warning, `not cooked`, and the stage makes nothing: a build without a sample's downloads passes. The stage's sub-assets from an earlier cook stay.
- **Tydra**, LightUSD's render-scene converter, turns the composed stage into nodes, triangulated meshes, materials and textures. It stops at the first mesh that it cannot convert, so the cooker converts again without what broke it. First the mesh's authored normals go, which is what exporters most often get wrong, and the cooker makes its own. If the mesh still fails, it becomes an empty `Xform` and is left out. Each is a warning that names the mesh and why.
- **A primvar reader whose `inputs:varname` connects to an input of a NodeGraph**, as 3ds Max writes every texture of Sponza, takes the input's value before Tydra sees it, because Tydra cannot follow that connection.

## Meshes

A Mesh prim is a Mesh sub-asset, in its own space. Its GeomSubsets of the `materialBind` family are its submeshes, in name order, then the faces that no subset holds. A Mesh_Renderer has 8 material slots, so a mesh of more than 8 subsets is split into parts of 8, `#1`, `#2` and on, each a mesh and an entity of its own.

- **Axes and units:** USD is right-handed. A Y-up stage mirrors x, as glTF does ([Meshes](meshes.md#meshes)); a Z-up stage turns z up to y, then mirrors x. Both reverse each triangle's winding, unless the mesh's `orientation` is `leftHanded`. Positions are scaled by `metersPerUnit`, then by the `scale` setting.
- **UVs:** USD's `st` has v up, and the engine's textures have it down, so v becomes 1 - v.
- **Normals** are the mesh's own, or, for a mesh without them, the area-weighted normals of the faces that share each position, so a smooth mesh stays smooth.
- **Tangents** are always made, in MikkTSpace, because USD rarely carries them.
- The rest is a model's mesh: `finish_mesh` welds, orders, clusters and writes it (see [Meshes](meshes.md#meshes)).

## Textures

A texture is an image as one material input reads it: its **role**. One image read two ways is two textures.

| Input | Role | Usage |
|---|---|---|
| `diffuseColor`, `emissiveColor` | `color` | BC7 in sRGB |
| `normal` | `normal` | BC5 |
| `metallic`, `roughness`, `opacity` | `mask.r`, `mask.g`, `mask.b` or `mask.a`, by the channel that the input reads, with `.srgb` when the texture says `sourceColorSpace = "sRGB"` | BC4, with that channel moved to red |

- A float input connected to `outputs:rgb` reads red.
- A scalar's image is raw unless it says sRGB. UsdPreviewSurface reads `auto` as sRGB for 8-bit images, but exporters write `auto` for roughness and metalness maps that hold linear values.
- Opacity from the base color's alpha is no texture of its own: the material samples the base color's.
- Each texture cooks as a texture asset does ([Textures](textures.md#textures)), halved until it fits `texture_max_size`. The image is not an asset of its own: the scan never sees it, because a stage's downloads are in a folder whose name starts with a dot, and its GUID is the stage's.
- An image that is not there is a warning, and its input keeps its value.

## Materials

A UsdPreviewSurface material is an instance of one of six built-in materials, `lib/engine/content/materials/preview_surface*.material`, which share their evaluate, `lib/engine/content/shaders/preview_surface.hlsli`. An instance overrides parameters and switches but not settings, so the six are the settings: opaque, masked and transparent, each one-sided and two-sided.

- **Blend:** opaque when `opacity` is 1 and no texture. With `opacityThreshold` above 0 it is masked: the shader compares the opacity with the threshold, and the material cuts at 0.5. Otherwise it is transparent.
- **Sides:** `doubleSided` is a mesh's, not a material's, so a material that two-sided meshes use has a second instance, `#two_sided`.
- **Inputs:** each of base color, metallic, roughness, emissive and opacity is the material's value, or, with its switch on, its texture, which replaces the value as UsdPreviewSurface defines it. A normal map has a switch alone.
- **UsdTransform2d** on a material's textures becomes its `uv_transform`, the first one's scale and translation for all of them, with v's offset made for v down. Its rotation is not drawn.
- **Not drawn:** `occlusion`, which the lit shading model has no input for, and the specular workflow, which draws as metallic 0. Each is a warning that counts the materials.

## Point instancers

A UsdGeomPointInstancer places its prototypes at its points: Jungle Ruins has 778 of them, with 8.7 million points. The cooker keeps each one whole, as an `Instance_Set` sub-asset for each mesh that its prototypes draw, which an `Instanced_Mesh_Renderer` draws the mesh at (see [Rendering: GPU scene](../../rendering/gpu-scene.md#instanced-meshes)). That is the default, `point_instancers = instanced`.

- **Prototypes** are prims of the stage, under their instancer, which Tydra converts as it does any mesh. The prefab leaves them out, so a prototype is not drawn where it was modeled.
- **Shared prototypes.** A scene that tiles its instancers has a copy of each prototype in each tile: Jungle Ruins' 773 prototype meshes are 53 meshes. A prototype's mesh that is the same as one before it, by its corners, subsets, materials and sides, draws as that one, which is the only one that cooks. A prototype's mesh is named for its prim alone, `prototypes/<name>`, since its copies are in different tiles; a second mesh of the same name gets `_2`.
- **Poses.** An instance's pose is the mesh's pose under its prototype, then its point's, from `positions`, `orientations` and `scales`, in the instancer's space, turned into the engine's axes in meters as a child entity's is. A point that `invisibleIds` or `inactiveIds` hides is left out, and so is one whose `protoIndices` entry is out of range, with a warning. A pose with shear is posed without it, with a warning that counts them.
- **The blob** (`format.Instance_Set_Blob`, `lib/engine/asset/format/instances.odin`) holds 32 bytes an instance: its position, its rotation as a unit quaternion in snorm16, its scale in `f16`, and its point's index. The instances are in the order of a Morton curve over their bounds, in cells of at most `INSTANCE_CELL_SIZE` (256), and each cell has a sphere about its positions and the largest scale of any of their axes, which culling grows a mesh's sphere by.
- **The prefab** has an entity for each point instancer, under the root and posed in the stage, whose `Instanced_Mesh_Renderer` draws its set. An instancer of several sets has a child for each, and a mesh in parts a child for each part, all drawing the same set.
- **`point_instancers = skip`** leaves instancers out, prototypes too; **`entities`** makes an entity of each point, as Tydra expands them, which is far too many for a forest.

## Prefab

The stage's prims are one prefab: a root named for the stage, at the origin, and an entity for each prim that holds a mesh or has one below it, posed under its parent with a `Local_Transform`. An entity's ID is the hash of its prim's path, so a scene's overrides of the prefab's entities survive a cook (see [Prefabs](../../editor/prefabs.md#instances-in-a-scene)).

- **A pose** is the prim's local matrix, turned into the engine's axes in meters, then split into an offset, a rotation and a scale. A matrix with shear cannot be split exactly; such a prim is posed without its shear, with one warning that counts them.
- **A mesh** is the entity's `Mesh_Renderer`, whose slots are the instances of its subsets' materials. A mesh in parts is an entity with a child for each part.
- **Instances** of USD's scene-graph instancing, and the points of point instancers with `point_instancers = entities`, are entities under the root, posed in the stage.
- **Point instancers** are entities with an `Instanced_Mesh_Renderer` (see [Point instancers](#point-instancers)), and their prototypes are not entities.
- **Cameras and lights** are not in the prefab.

A scene places the prefab as it places any: an entity with `prefab = $<guid>` (see [Prefabs](../../editor/prefabs.md#instances-in-a-scene)). The editor opens it for viewing; edits to it are overrides in the scene, because the stage writes it again.

## Cooking

A stage cooks each sub-asset on its own and writes its blob at once, in an arena that is freed after it, so a stage of gigabytes of images never sits in memory whole. A sub-asset that fails keeps its old blob, and the stage fails.

- **Each sub-asset's key** covers what it is made from. A texture's is its image's path, size and modification time, its role and the settings; a mesh's is its corners and subsets after conversion; an instance set's is its instancer's points and its prototypes' poses of its mesh. A change to one image cooks only its textures.
- **The manifest**, `<cache>/stages/<guid>.deps`, holds what the last cook read and made: the stage's key, the size and modification time of every USD file under its sublayers' folders and of every image, and each sub-asset with its blob's key and its generated text. A stage whose manifest still matches is current without being opened: on Sponza that takes milliseconds, where opening it takes seconds.
- **The stage's key** covers the cooker's version, LightUSD's, meshoptimizer's and Compressonator's, the configuration, the path, the source, the GUID and the settings. The sub-asset lines of the `.meta` file are not in it, because the cooker writes them.
- **The daemon's watcher** does not see a stage's downloads, which are outside the content or in a dot folder, so after changing them, re-import the stage or run `just stages`.
- **`cook stage-report <stage>...`**, which `just intel-report` runs, opens stages as a cook would and prints what they would make, with point instancers as instance sets: prims, the meshes that cook and their parts, triangles, point instancers, points, prototype meshes and the meshes they share, instance sets, material instances, textures and lights, and the meshes, textures and instance sets resident at once (see [Rendering: Assets](../../rendering/assets.md#gpu-residency)).

## Import settings

| Setting | Values | Default | What it does |
|---|---|---|---|
| `scale` | `0.001`, `0.01`, `0.0254`, `0.1`, `1`, `10`, `100` | `1` | Scales the stage after its `metersPerUnit`. |
| `cluster_lod` | `true`, `false` | `true` | Builds the meshes' meshlet hierarchies (see [Meshlets](meshes.md#meshlets)). |
| `collision` | `true`, `false` | `false` | Writes the meshes' collision data. |
| `impostor` | `true`, `false` | `false` | Bakes each mesh's impostor (see [Impostors](meshes.md#impostors)). |
| `texture_max_size` | `256` to `16384` | `4096` | Halves each texture until it fits. |
| `normal_y` | `file`, `flip` | `file` | Negates the normal maps' green channel, for maps made for the other convention. |
| `point_instancers` | `instanced`, `skip`, `entities` | `instanced` | Draws each point instancer with an instance set, leaves them out, or makes an entity of each point (see [Point instancers](#point-instancers)). |

## LightUSD

LightUSD is the submodule `vendor/lightusd` (github.com/lighttransport/tinyusdz), pinned to a release, and `just update-lightusd <tag>` moves the pin. It is C++17 without dependencies. `just lightusd` builds it with `tools/cook/usd/CMakeLists.txt`, which turns off its image loader, tools and extras, and builds `cn_usd.cpp`, the cooker's C interface to it (`cn_usd.h`), which `tools/cook/usd.odin` binds. One handle holds one composed and converted stage, and gives its nodes, meshes as triangle corners grouped by subset, materials, textures and point instancers as flat C structures. Point instancers come from the composed stage, not from Tydra: their prototypes' meshes, each with its pose under its prototype, and their points' matrices, which it computes only when asked, so a forest is never a list of millions of instances.

## Limits

- **`.usdz`** is not yet a stage.
- **Images** are those that `stb_image` decodes: PNG, JPEG, TGA and HDR. A TIFF or EXR image is a warning, and its input keeps its value.
- **Instance sets** draw at their meshes' finest level until their impostors take over on a device without mesh shaders, and cast no traced shadows (see [Rendering: GPU scene](../../rendering/gpu-scene.md#instanced-meshes)). A stage bakes impostors with `impostor = true`.
- **Nested instancing**, a point instancer in another's prototype, is left out, with a warning that counts them; the outer instancer draws its prototypes' meshes.
- **Size:** a mesh cooks whole, so its triangles fit in memory. Jungle Ruins' meshes that cook are 18.6 million triangles; converting it with its point instancers expanded took about 26 GB.
- **Residency:** Jungle Ruins makes 1,173 meshes, textures and instance sets, within the renderer's `MAX_RESIDENT` of 4,096.
- **Decals** that a stage models as quads on a surface, as Sponza's `decals_*_floor` are, z-fight with the surface: the engine has no decals yet, and an opaque or masked material takes no depth bias.
- **Not imported:** cameras, lights, skins, animation, variants other than the stage's selections, and materials other than UsdPreviewSurface, such as MaterialX.

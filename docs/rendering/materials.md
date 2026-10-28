# Materials

Shading models, materials as node graphs or HLSL, their permutations, instances, the runtime's material table and pipelines, and the editor's previews. The cooker's side is in [Content pipeline](../content/kinds/materials.md).

**In this document:** [Shading models](#shading-models) · [Material](#material) · [Parallax occlusion mapping](#parallax-occlusion-mapping) · [Vertex displacement](#vertex-displacement) · [Permutations](#permutations) · [Material instance](#material-instance) · [Runtime](#runtime) · [Material previews](#material-previews)

```mermaid
flowchart LR
    SM["Shading model<br/>lit.shading + lit.hlsl"]
    GRAPH["Material<br/>rock.material (graph)"]
    INST["Material instance<br/>rock_mossy.material_instance"]
    COOK["tools/cook<br/>codegen + DXC"]
    BLOB["Material blob<br/>shaders, parameter layout, defaults"]
    IBLOB["Instance blob<br/>parent GUID, values"]

    SM --> GRAPH
    GRAPH --> COOK --> BLOB
    INST -->|"parent"| GRAPH
    INST --> COOK --> IBLOB
```

A material is content from end to end: a shading model is two files, a material is a text file that the editor's graph editor writes, the cooker generates and compiles the HLSL, and the renderer loads the blob and makes pipelines from it. [Content pipeline](../content/kinds/materials.md#materials) has the file formats and the cook; this section has the design and the runtime.

## Shading models

A shading model is a lighting model, such as `Unlit` or `Lit` (metallic and roughness). It is two content files, so a game adds its own in its content root:

- `<name>.shading` declares it (see [Content pipeline](../content/kinds/materials.md#materials)): its surface inputs with their types and defaults, and its flag `no_lighting` (skip the light loop). Its name is the file's, such as `lit`.
- `<name>.hlsli`, beside it, implements it. It is an include, not an asset. The cooker generates the `Surface` struct and `default_surface()` from the declaration, and the file defines:

```hlsl
float3 shade_emission(Surface s);
float shade_opacity(Surface s);
// Unless no_lighting:
float3 shade_direct(Surface s, Shading_Point p, Light light);
float3 shade_area(Surface s, Shading_Point p, Area_Light light);
float3 shade_indirect(Surface s, Shading_Point p, Indirect indirect);
```

- **The engine's:** `lib/engine/content/shading/lit` (GGX specular with Smith visibility and Schlick's Fresnel, Lambert diffuse, linearly transformed cosines for area lights, and Karis's fit of the environment BRDF for indirect specular) and `unlit` (its color, as it is).
- **Area lights:** `shade_area` multiplies the light's radiance by `ltc_integral` of each of its lobes. A lobe is given by a 3x3 matrix's inverse: the identity for Lambert's diffuse, or `ltc_ggx`'s for Lit's specular (see [Area lights](lighting-and-shadows.md#area-lights)). A shading model with another specular fits its own tables as `tools/ltc_fit` does.
- **A tangent-space normal:** a shading model whose inputs include a `float3 normal` takes it in tangent space, as a normal map gives it, and the template maps it to the world before shading.
- **Emission** is radiance in the scene's linear units, the units of the lights' colors: a surface whose emission is 1 is as bright as a white surface lit by a directional light of 1 from straight on. The graph's Emission node gives it as a color at a brightness in stops, color × 2^EV, which is how the sample's glowing panel and a material instance keep a sane number; the `Emission` [debug view](post-processing.md#debug-views) shows the emission alone. Emission reaches bloom and the [global illumination](global-illumination.md#global-illumination) as any light in the scene does.
- The engine's forward template owns the light loop. For each directional light and each light in the pixel's cluster, it calls `shade_direct` with the light's color after its falloff and its shadow, or `shade_area` for an area light (see [Lights and clusters](lighting-and-shadows.md#lights-and-clusters)). Then it calls `shade_indirect`, and adds the emission. `Unlit` has `No_Lighting` and only emits.
- The indirect light is the [global illumination](global-illumination.md#global-illumination)'s diffuse and specular light, or without it the ambient light: the sky's color from above and the ground's from below (`Environment`). The template scales both by the [ambient occlusion](ambient-occlusion.md#ambient-occlusion) before it calls `shade_indirect`.
- The material graph's output node has one input for each surface input of its shading model. The cook link sends the shading models to the editor with the importers, so the editor shows the right inputs.
- Fog, exposure, the ambient occlusion and the shadow mask are applied by the template, not by shading models.

## Material

A material is a `.material` text file (see [Content pipeline](../content/kinds/materials.md#materials)). The editor's material editor writes its graph, as the editor writes scenes (see [Editor](../editor/material-editor.md#material-editor)). It has:

- **Settings:** the shading model, the blend mode (`Opaque`, `Masked`, `Transparent` or `Additive`, see [Transparency](transparency.md#transparency)), a transparent material's transparency (moment-based or sorted), the geometry (`mesh`, or `patches` for a [patch surface](surfaces.md#materials-for-patches)), two-sided, casts shadows, and the displacement bound (see [Vertex displacement](#vertex-displacement)).
- **Parameters:** scalars, vectors, colors, textures and static switches, each with a name, a default and a group for the editor.
- **The graph:** nodes and links (see [Content pipeline](../content/kinds/materials.md#material-graphs)). Nodes include math, texture samples, parameters, time, world position (relative to the render origin, see below), object position (in the mesh's own space), vertex attributes, static switches, material functions (`.material_function` assets, graphs that a node calls) and a custom HLSL node.

The cooker turns the graph into an HLSL function, `Surface evaluate(Material_Inputs inputs)`, and compiles it into each pass's template. A material's `evaluate` can also be HLSL written after a `---` line of the file, which is how the built-in materials exist. `evaluate` reads its parameters from the generated `params`, and its static switches as defines; a graph's switch nodes are decided when each variant generates its source, so they need no defines.

**World position.** `Material_Inputs.position` is relative to the camera, which is what the passes need, but a pattern made from it would slide with the camera. The World Position node gives `world_position(inputs)`: the position relative to the render origin, `inputs.position + frame.origin_offset`, which stays put while the camera moves and keeps `f32`'s precision, because the origin is within 1.5 cells of the camera. The origin snaps to 1024 m, so a pattern whose period divides 1024 m has no seam when it moves; any other pattern jumps there. In a preview, the origin is the mesh's middle.

**No raw stage inputs.** Generated code reads attributes only through `Material_Inputs`, and samples textures only through `cn_sample`, which takes the derivatives from the inputs, so a material does not depend on how its inputs are made.

## Parallax occlusion mapping

The Parallax Occlusion node (`cn_parallax`, in `material_parallax.hlsli`) gives a flat surface relief: a height map marched along the view, so that each pixel samples its textures where the view ray meets the relief, not where it meets the face.

- **The height map** is a `mask` texture (see [Content pipeline](../content/kinds/textures.md#textures)) whose red channel is 1 at the surface and 0 at the node's `scale` below it, in UV units. The node takes the map, the UV, the scale and the steps, and gives the UV that the pixel sees and the height there, which a material feeds to its texture samples and can use to pick colors or darken crevices.
- **The march** goes from the surface down in equal layers, as many as `steps` where the view is edge on and a quarter of that head on, at most `PARALLAX_MAX_STEPS` (64), and interpolates between the last two layers for where the ray crossed the relief. It samples with the pixel's derivatives of the UV taken before the march (`cn_sample_grad`), since the march's steps differ between neighbouring pixels, which would break the implicit derivatives inside the loop.
- **Depth is not moved.** The forward pass tests depth `Equal` against the prepass, so a per-pixel depth offset would have to be written by both and would turn early depth off. The relief therefore changes what a pixel samples, and through the prepass's normal what it shades, but not the silhouette, and not where a shadow falls on it. The node runs in the prepass too, so the normal map and the opacity mask follow the relief.
- The sample's bricks material (`samples/mygame/content/materials/bricks.material`) is a graph that uses it, on the Cornell box's short box, with a height map that `just sample-textures` writes.

## Vertex displacement

A material can move its vertices: waves, wind, a height map. It defines `float3 displace(Vertex_Inputs v)`, which gives an offset in meters in the world, in HLSL after the `---` line, or as a graph with a Vertex Offset node (`vertex_output`), whose nodes run in the vertex shaders.

- **`Vertex_Inputs`** is the vertex before its offset, placed by its instance's pose: `position` relative to the camera, `object_position` in the mesh's space, `normal`, `tangent`, both UV sets, the color, and `time`. `world_position(v)` gives the position relative to the render origin, as it does for `Material_Inputs`.
- **Both poses.** `finish_vertex` (`material_vertex.hlsli`) adds `displace` to the vertex at this frame's pose and time, and again at last frame's pose and `Frame_Constants.previous_time`, so an offset that moves with time gives a velocity, and temporal AA follows a wave. Every vertex path goes through it: vertex pulling, the mesh shaders and the patch surfaces, so the prepass, the shadow maps and the forward pass agree.
- **In a graph,** the vertex offset's nodes read `Material_Inputs` made from the vertex (`vertex_material_inputs`), so the same nodes, custom HLSL and material functions serve both; a material function that both outputs reach is generated once for each stage. A texture sample takes its first mip, since a vertex shader has no derivatives. The View Direction, Front Facing, Fresnel and Parallax Occlusion nodes read what only a pixel has, and reaching one from the Vertex Offset is an error on that node. The Time node reads `inputs.time`, which is the frame's in evaluate and the pose's in the offset.
- **Culling.** The material's `displacement_bound` setting is how far the offset may reach, in meters. Culling adds it to each item's sphere after the instance's scale (`Cull_Item.bound`), and the mesh shader path adds it to each meshlet's sphere (`Draw_Record.bound`) and skips the normal cone test, since the offset may turn a meshlet. A material that leaves it 0 may vanish at the frustum's edge when it moves far.
- **Limits.** The offset is in the vertex, so the prepass normal is the mesh's unless the material gives one: a wave lights right only with an analytic normal through the shading model's `normal` input. Ray-traced shadows trace the mesh as it is, without the offset. The levels of detail pick by the mesh's own errors, which the offset does not change. The blob flag `Displaces` marks such a material.

## Permutations

The cooker compiles each material for each pass and each vertex path:

| Axis | Values |
|---|---|
| Pass | `Forward`, `Prepass` (depth, normals, velocity), `Depth` (shadow maps) |
| Vertex path | Vertex pulling, and for the opaque passes the mesh shader path's `as_cluster` with `ms_forward`, `ms_prepass` and `ms_depth` (see [GPU scene](gpu-scene.md#mesh-shader-path)); or for a `patches` material the patch path alone (see [Surfaces](surfaces.md#patches)) |
| Static switches | Each combination that the material or an instance uses |

- One generated source holds every pass, each by its entry points (see [Content pipeline](../content/kinds/materials.md#materials)). DXC keeps only what each pass's outputs need: the depth pass of an opaque material has no pixel shader and no material code.
- The cooker names each generated source by its hash, which covers what it includes, so identical permutations compile once, and a source that an earlier cook compiled is not compiled again.

## Material instance

A `.material_instance` names its parent (a material or another instance) and overrides parameters. Changing a parameter changes data, never shaders.

- **Static switches** can be overridden in an instance. The override selects another permutation of the parent material. The cooker compiles each permutation that some instance uses, once, under the hash of its generated HLSL, so instances that set the same switches share it.
- A material's blob holds every permutation that its instances use. A new instance that sets switches no other instance set cooks the material again.
- A dynamic instance cannot change static switches at runtime, because that would need a permutation that was never cooked.
- The editor shows how many permutations each material has, so a material whose instances set many combinations of switches is easy to see.

At runtime, `render.material_instance(parent)` makes a dynamic instance whose parameters a game or a script sets every frame.

## Runtime

- **One table.** Each frame uploads a table with a block for each material or instance that it draws (`Material_Table`, in `lib/engine/render/materials.odin`). A block holds the parameters in the layout that the material's blob gives, with each texture's bindless index written: the resident texture, or the default for its parameter (white, black or a flat normal) until it is resident. Each draw record holds its block's offset.
- **Pipelines by material.** The renderer creates the pipelines of each material and switch combination that a draw needs, one for each pass, from the material's blob, at most `MAX_MATERIAL_PIPELINES` combinations. With mesh shaders, an opaque material has mesh pipelines for its opaque passes too (see [GPU scene](gpu-scene.md#mesh-shader-path)). Instances with the same switches share them. A two-sided material culls no faces. The forward pipeline tests depth `Equal` and does not write it.
- **The default material.** A submesh without a material, or whose material cannot draw (not cooked, or without the variant that its instance needs), draws with the engine's default material, `lib/engine/content/materials/default.material`.
- **Bins.** Culling writes each visible draw into the bin of its pipeline. Each bin is one indirect draw with a count buffer (see [GPU](../gpu/gpu-driven-and-mesh-shaders.md#gpu-driven-rendering)).
- **Hot reload.** A new material blob updates its pipelines with `update_graphics_pipeline`, so the old shaders draw until the new ones compile. A new instance blob rewrites its parameter block. Both come through `asset.poll` (see [Content pipeline](../content/blobs-and-loading.md#loading)).
- **Missing pipelines.** A bin whose pipeline is not compiled yet draws nothing until it is, which is the backend's rule for every pipeline.

## Material previews

The editor's material editor shows the material on a mesh. The game renders it with the renderer, as a second kind of view, into a second shared target. The preview therefore uses the same shaders, shading models and passes as the game.

- **Its own scene.** A preview does not draw the world. It draws one preview mesh with the material, lit by one directional light from over the camera's shoulder and the default ambient light, with the material's prepass and forward pipelines, then tone maps it with the output pass, through the frame's lookup table. It is not pre-exposed (`Post.unit_exposure`) and has no bloom. The mesh is one of the engine's, a sphere, a cube or a plane, each 1 m across (`lib/engine/content/models/preview.gltf`, `render.preview_mesh`), or a mesh asset. Its records are relative to its camera, which orbits the mesh's middle. It has no shadows, no clusters, no fog, no GI and no temporal passes, so it keeps no history.
- **In the frame's graph.** `Frame_Desc.previews` gives the previews that a frame draws (`render.Preview_Desc`): the target, the material, the mesh and the camera. `draw_frame` adds each one's passes to its graph: a copy of its records into the renderer's preview buffers, which the shaders read from their starts, its prepass, its forward pass and its output pass. A preview without its mesh or its material clears its target to the background.
- **Complete.** `draw_frame` sets a preview's `complete` when its mesh was resident, its pipelines were compiled (`gpu_pipeline_ready`), its textures were resident and the lookup table was baked, so the game draws it again until it shows the material as it is.
- **Its own shared target.** Each preview has a set of shared textures and a fence, named and paced as the viewport's are (see [GPU](../gpu/presentation.md#presentation) and [Editor](../editor/viewport.md#viewport)): `<name>.preview<id>.g<generation>.texture0..2`, with IDs below `gpu.MAX_PREVIEW_TARGETS` (4). `gpu_preview_target` gives the game a target's texture for a frame, at most `gpu.MAX_PREVIEW_SIZE` (1024) on each side, and `gpu_release_preview_target` releases it.
- **Only when needed.** The game's editor package (`editor.previews`, which the game's frame puts in `Frame_Desc.previews`) draws a preview when its material, its mesh, its camera or its size changes, until it is complete, and every frame while its material reads the time (the blob's `Reads_Time`). It draws at most one in each frame, in turn, and none whose target the editor may still be reading.
- **Editor link messages:** `Open_Preview` with the preview's ID, the material or instance GUID and whether to load the unsaved blob, `Preview_Settings` with the mesh, the orbit camera and the size, `Close_Preview`, and `Preview_Target` from the game with the shared target's name and generation. The editor acknowledges each frame that it copies with `Preview_Acknowledged`, which the host handles. The editor's side is in [Editor](../editor/material-editor.md#material-editor).
- **Unsaved changes.** The preview shows a graph that the user has not saved. The editor sends the graph's text to the cook daemon in a `Cook_Preview` message on the cook link. The daemon cooks it under the material's GUID into a separate preview area of the cache, `build/dev/content/preview/<guid>.blob`, and once a cook has succeeded, the editor opens the preview again with `unsaved`, so the game loads the preview's material from there (`asset.preview_blob`). The game checks the blob's time each frame while the preview is open, and a new one makes the renderer update the preview's own pipelines, which draw the old shaders until the new ones compile. The game's material changes only when the file is saved. A preview of an instance shows its cooked blob.
- **Time:** materials read the frame's time as `Frame_Constants.time`: seconds since the host started, wrapped every hour so that a float keeps its precision.

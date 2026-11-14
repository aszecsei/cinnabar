# Lighting and shadows

Why the renderer is clustered forward with a prepass, the prepass's outputs, the forward pass's quad overdraw and the visibility buffer that was measured against it, lights and their clusters, area lights with linearly transformed cosines, local reflection probes, stochastic screen-space reflections, and shadows as maps, virtual maps or traced masks.

**In this document:** [Clustered forward](#clustered-forward) · [Prepass](#prepass) · [Quad overdraw](#quad-overdraw) · [Visibility buffer](#visibility-buffer) · [Lights and clusters](#lights-and-clusters) · [Area lights](#area-lights) · [Reflection probes](#reflection-probes) · [Screen-space reflections](#screen-space-reflections) · [Shadows](#shadows) · [Soft shadows](#soft-shadows) · [Virtual shadow maps](#virtual-shadow-maps)

## Clustered forward

The renderer has one shading path: forward shading with a prepass.

- **Many shading models cost nothing.** Each material's pixel shader runs its own shading model. A deferred path would have to pack every model's inputs into one G-buffer and branch on a model ID.
- **Transparent surfaces** use the same light loop as opaque ones.
- **The prepass gives the screen-space passes their inputs:** depth, a normal, a velocity and a roughness for each pixel. Ambient occlusion and screen-space GI then run before the forward pass, and the forward pass applies them to indirect light only, which a deferred or a plain forward path gets wrong or gets a frame late.
- **The clusters serve fog too.** The fog volume's froxels and the light clusters share their depth slices, so fog reads the same light lists.
- **The prepass removes overdraw.** The forward pass tests depth with `Equal` and shades each pixel once.

### Prepass

- Writes depth, the normal in the world (folded into the octahedron, `NORMAL_FORMAT`, `RG16_Float`) and the velocity: how far the surface moved on the screen since last frame, in UV (`VELOCITY_FORMAT`, `RG16_Float`), from the instance's last pose and last frame's camera and projection, without the camera's jitter. The pass clears the velocity to `VELOCITY_NONE` where it draws nothing, which temporal AA then moves with the camera.
- **The roughness** (`Frame.roughness`, `ROUGHNESS_FORMAT`, `R8_Unorm`) is the shading model's `roughness` input, or 1 for a model without one, as [hit shading](ray-scene.md#hit-shading) takes it: both call `shading_roughness` in `material_vertex.hlsli`. The pass clears it to `ROUGHNESS_NONE`, 1, which reflects nothing sharp, where it draws nothing, so a game's own draws in `world_draw` have it too. The GI's gathers read it for the sky's [cubemap](sky.md#specular-light) past their probes. The `Roughness` [debug view](post-processing.md#debug-views) shows it.
- **The roughness's cost.** It is its own target, not a channel beside the normal, which the ambient occlusion and the GI read as two channels. Both were measured against the prepass without roughness, in the Intel sample's Sponza on an RTX 5090, at High quality with temporal AA, in the editor's viewport at 911x481, with the median of five captures (see [Quad overdraw](#quad-overdraw)'s Measuring). The prepass took 0.055, 0.059 and 0.045 ms in the nave, the courtyard from the upper gallery and the outer wall without roughness; 0.056, 0.061 and 0.044 ms with the normal widened to `RGBA16_Float` and the roughness in its third channel; and 0.055, 0.062 and 0.044 ms with the `R8_Unorm` target. Each is within the captures' spread of about 0.005 ms, and the late prepass stayed at 0.005 ms. The prepass is bound by its geometry, not by its targets, so the separate target costs nothing measurable and keeps the normal's format, which the ambient occlusion and the GI read, as it was. The lit image is the same: two captures with and without roughness differ no more than two captures of one build.
- **The IDs stay in the forward pass.** It shades each visible pixel once, so it writes each pixel's ID as the prepass would, and a game's own draws in `world_draw` write theirs in the same target.
- The normal is the material's normal, normal maps included. The prepass's pixel shader returns only the normal and the roughness, so DXC drops the parts of `evaluate` that only the other surface inputs need; the opacity still discards for a masked material. The vertex-pulling path, the mesh shader path and the impostors write the same targets.
- The forward pass places vertices with the same code, `clip_position` in `material_vertex.hlsli`, whose result is `precise`, so its depths equal the prepass's for its `Equal` test.

### Quad overdraw

A pixel shader runs on 2x2 quads of pixels, so it has derivatives. A triangle that covers part of a quad still runs all four lanes, and the lanes outside it are helper lanes, whose work is lost. Small triangles leave most of their quads' lanes as helpers.

- **Counting.** With `Frame_Desc.shading_stats` (the editor viewport's Shading Stats), `count_quad` in the forward pixel shader counts each quad and its lanes that cover a pixel (`lib/engine/render/shading.odin`). A lane of each quad adds 1 to the quad's texel of `Shading_Frame.quad_counts`, at half the scene's size, which the `Quad_Overdraw` debug view shows as heat colors from 1 to 4 (see [Debug views](post-processing.md#debug-views)). Each wave adds its quads and its pixels to `Shading_Stats`, which comes back through three readback copies, as the culling stats do, and which the Resource Monitor shows as the quads' efficiency: the pixels over four times the quads. The rest are helper lanes.
- **Which pixels.** Wave operations leave helper lanes out, but quad reads take them, so `count_quad` finds the quad's covering lanes with quad reads. The forward pixel shader has `[earlydepthstencil]`, which it may have since the pass writes no depth, so only the pixels that pass the `Equal` test count, and the counting's writes do not move the test after the shader.
- **The cost.** Without the stats or the view, the push constants' indices are 0, and the shader's first branch leaves.
- **Measuring.** A capture's sidecar has the last profile summary, with each pass's GPU time, and `editorctl`'s `viewport` and `camera` commands set the viewport's settings and its camera, so a script can measure each view of a scene with each setting (see [Capture](../editor/capture.md#editorctl)).

### Visibility buffer

A visibility buffer writes each pixel's triangle in a pass of its own, then shades the pixels in compute, so no pixel shader runs on mostly empty quads (see Burns and Hunt in the [References](README.md#references)). One was built as a prototype on the [mesh shader path](gpu-scene.md#mesh-shader-path) and measured against clustered forward. The decision is in the README's [Decisions](README.md#decisions): clustered forward stays the shading path, and the prototype is not in the engine.

**The prototype.**

- **The visibility pass,** after the prepass, and a late one after the late prepass, drew the camera's opaque bins on the mesh shader path in place of the prepass. It wrote the prepass's normal and velocity, and an `RGBA32_Uint` target: the draw's index, the instance ID, the meshlet, and the triangle with whether it is a front face and the pipeline that drew it. The mesh shader gave these to each triangle as a per-primitive attribute. A stencil bit kept the forward pass off its pixels.
- **Binning:** four compute passes, as [hit shading](ray-scene.md#hit-shading)'s: each 2x2 quad went into the bin of each material pipeline that one of its pixels had, and each bin's dispatch was indirect.
- **Shading:** each material compiled a compute entry that shaded its bin, a 2x2 quad of threads for each quad of pixels. A thread rebuilt its pixel's triangle with `place_vertex`, as the mesh shaders place it, and took its barycentrics where the camera's ray through the pixel's center meets the triangle's plane. It filled `Material_Inputs` as the forward pass does, ran `evaluate`, and lit the pixel with the forward pass's lighting at the prepass's depth.
- **Derivatives.** A pixel of the quad that was not the material's took the quad's first triangle of the material, so where one triangle covered the quad, `ddx` and `ddy` of the real UV were exact. Where two triangles of the material shared the quad, the quad was mixed, and `cn_sample` took the analytic derivatives of `uv0` instead. These are wrong for a material that scales or computes its UVs, or samples with `uv1`.

**Measurements.** On an RTX 5090 at 1320x800, High quality with temporal AA, in the Intel sample (see `samples/intel/README.md`), measured with the tools of [Quad overdraw](#quad-overdraw). Each value is the median of five captures, or three for Jungle Ruins, in at least two runs. The pass times are the profiler's GPU spans, which can overlap their neighbours (see [Profiling](../core/profiling.md#gpu-timestamps)). The forward pass's cost is its prepass and its world pass. The visibility buffer's is what was left of the prepass with the visibility passes, the binning, the shading, and what was left of the world pass.

| View | Forward quad efficiency | Visibility buffer's mixed quads | Forward prepass + world (ms) | Visibility buffer: visibility + binning + shading + world (ms) | GPU frame, forward → visibility buffer (ms) |
|---|---|---|---|---|---|
| S1: Sponza's nave, the scene's camera | 56 % | 45 % | 0.13 + 0.14 | 0.23–0.25 + 0.09 + 0.11 | 4.23 → 4.46–4.73 |
| S2: Sponza's upper gallery, looking down | 59 % | 36 % | 0.12 + 0.13 | 0.22 + 0.11 + 0.11 | 3.99–4.10 → 4.23–4.64 |
| S3: Sponza's outer wall, large triangles | 99 % | 1 % | 0.06 + 0.06 | 0.11 + 0.04 + 0.06 | 2.10 → 2.14–2.22 |
| S4: Sponza's curtains, close | 59 % | 43 % | 0.07 + 0.08 | 0.10 + 0.07 + 0.10 | 3.89–3.93 → 4.08–4.14 |
| J1: Jungle Ruins, the scene's camera | 33 % | 60 % | 21.1–31.7 + 20.1–27.0 | 39.5–39.8 + 0.24 + 0.18 + 2.5 | 46.3–63.6 → 47.2–47.6 |
| J2: Jungle Ruins' ground cover, close | 35 % | 59 % | 6.3–8.4 + 6.8–8.0 | 9.6–10.1 + 0.29 + 0.27 + 2.2 | 17.9–21.1 → 17.2–17.6 |
| J3: Jungle Ruins from above | 30 % | 57 % | 96–150 + 90–126 | 182–183 + 0.29 + 0.18 + 2.8 | 190.9–280.6 → 190.2–191.0 |

What they show:

- **Quad overdraw is real.** The forward pass's lanes are 40 to 70 % helper lanes wherever triangles are small: Sponza's curtains and Jungle Ruins' foliage, at the level of detail's 1 pixel of error. The visibility buffer shaded 1.6 to 2.1 times fewer quads there.
- **Shading is not where the frame's time goes.** In Sponza, the forward pass's world pass is 0.08 to 0.14 ms. The visibility buffer's shading of the same pixels was 0.06 to 0.11 ms, a fifth cheaper on the nave and dearer on the curtains, where it rebuilt a triangle for each pixel. The binning added 0.04 to 0.12 ms, so the shading as a whole was not cheaper.
- **The visibility pass cost more than the prepass that it replaced:** 1.5 to 2 times the prepass of the same bins in Sponza, and in Jungle Ruins against the forward pass's faster runs. Writing constants in place of the per-primitive IDs cost the same, so the IDs' attribute was not the cause. So every Sponza view was 2 to 12 % slower with the visibility buffer.
- **Jungle Ruins is bound by geometry.** The forward path draws its millions of meshlets twice, once in the prepass and once in the world pass. The visibility buffer drew them once, but its visibility pass cost about as much as both. Its frame was the same as the forward pass's best runs, and up to a third faster than the slowest. The forward pass's times on Jungle Ruins came in two groups from one run to the next, with the same draws and the same image, and the visibility buffer's did not. The cause is not known.
- **Mixed quads are common:** 36 to 45 % of the visibility buffer's quads in Sponza's dense views, and 57 to 60 % in Jungle Ruins. Their samples took `uv0`'s analytic derivatives, so the dense foliage's texture levels differed a little from the forward pass's, and it was slightly greyer. Sponza's images matched the forward pass's.

**The decision.** Clustered forward stays the shading path. A visibility buffer removes the quad overdraw, but in these scenes the overdraw is not the cost: Sponza's shading is a tenth of a millisecond, and Jungle Ruins' frame is its geometry. It is worth measuring again if a visibility pass can cost no more than the prepass, or for content that the forward pass's second pass over the geometry bounds.

### Lights and clusters

- **Light components:** `Directional_Light`, `Point_Light` and `Spot_Light`, and the [area lights](#area-lights) `Quad_Light`, `Disk_Light` and `Line_Light` (see [Components](assets.md#components)). Each frame, `extract_lights` writes them relative to the camera into the upload ring (`Light_Record`), the directional ones first, at most `MAX_LIGHTS` (1024), of which `MAX_DIRECTIONAL_LIGHTS` (4). The editor's hidden entities light nothing.
- **A light's falloff:** its color times its intensity. A punctual light falls off with the square of the distance, windowed to 0 at its range: `saturate(1 - (d / range)^4)^2 / d^2`. A spot light's cone also falls off from 1 at its inner angle to 0 at its outer angle, squared.
- **Clusters:** a compute pass (`cluster_lights.hlsl`) assigns the punctual and area lights to clusters: tiles of `CLUSTER_TILE` (64) pixels, in `CLUSTER_SLICES` (32) depth slices, exponential from the near plane to `CLUSTER_FAR` (500 m); the last slice reaches on to infinity. A thread for each cluster tests each light's sphere against the cluster's box in view space, so a spot light counts as its whole sphere. It takes room for its lights in one index list with an atomic add, and writes its offset and count. The list has room for `CLUSTER_AVERAGE_LIGHTS` (32) lights per cluster on average; a cluster that finds it full gets fewer. The clusters' buffers live in the `Renderer` and grow with the frame's size. The same thread then bins the [reflection probes](#reflection-probes) into a list of its own, and with probes the frame makes the clusters without punctual lights too.
- **In an [orthographic view](frame.md#orthographic-views)** the slices are even between the near and the far plane, and each cluster is a box (`slice_constants`, `slice_of` in `view_projection.hlsli`).
- **The forward pass** finds its pixel's cluster from its position and its depth (`cluster_of`), and calls the shading model's `shade_direct` for each directional light, then for each light of its cluster, with the light's shadow (`material_lighting.hlsli`). It calls `shade_area` for an area light. Without the cluster pipeline, the forward pass leaves the punctual and area lights out.
- The directional lights are not clustered. Every pixel loops over them.
- **The sun:** an `Environment` in Atmosphere mode can name a directional light as its sun. The air between the camera and the sun then dims and colors that light's own light, to 0 below the horizon (see [The sun](sky.md#the-sun)).

### Area lights

- **Shapes:** `Quad_Light` is a rectangle, `Disk_Light` a disk or an ellipse, and `Line_Light` a tube with round ends, or an ideal line when its radius is 0. A quad or a disk shines along its entity's +z, or from both faces when it is two-sided. A line is along its entity's +x.
- **Intensity** is a point light's: an area light gives what a point light of the same intensity would give along the light's +z, so a bigger light spreads the same light over more of its surface. Its radiance is its color times its intensity over the area that it shows along its normal: 4·hx·hy for a quad, π·rx·ry for a disk, 4·h·r + π·r² for a tube, and 2·h for an ideal line, whose radiance is per meter of its width.
- **The record** (`Light_Record`) holds an area light's middle, its normal in `direction`, its half size along its +x in `extent`, and in `extent_y` a quad's half height, a disk's radius along its +y, or a line's radius. Its range is the component's range plus its shape's bounding radius, so the clusters' sphere test covers the whole shape. Its range's window starts from its middle.
- **Shading:** linearly transformed cosines (`ltc.hlsli`). A lobe that is a clamped cosine transformed by a 3x3 matrix integrates over a shape as the cosine does over the shape transformed by the matrix's inverse. `shade_area` calls `ltc_integral` with Lit's specular inverse from `ltc_ggx`, and with the identity for Lambert's diffuse, then multiplies by the light's radiance.
  - A quad is a polygon, clipped to the horizon and integrated edge by edge.
  - A tube is the polygon of its outline from the point: the hull of its ends' spheres, an arc of four edges for each, joined by their tangents. End on, the outline is the near sphere's.
  - An ideal line has a closed form, and a disk is the sphere with its ellipse's form factor, clipped to the horizon by a table (Heitz and Hill, 2017).
- **The tables:** two 64x64 `RGBA32_Float` textures (`ltc_ggx.bin`, which `lights_init` uploads). The first holds the inverse matrices, by roughness across and by sqrt(1 − cos θ) of the view down. The second holds the specular's magnitude and Fresnel term, and the horizon-clipped sphere's form factor.
- **Fitting:** `just ltc-fit` fits the tables (`tools/ltc_fit`). For each texel, Nelder–Mead finds the matrix whose lobe best matches `shade_direct`'s GGX specular without Fresnel, first about the specular's average direction, then tilted. The tool prints how much of the light each fit puts in the wrong place: little except at grazing views, where linearly transformed cosines cannot follow GGX. Run it after a change to Lit's specular, and commit the table.
- **Fog** sees an area light as a point light at its middle, whose light a quad or a disk sends out with the cosine of its face.

### Reflection probes

`Reflection_Technique.Probes`, the Low preset's reflections, which also run under the [screen-space](#screen-space-reflections) and [traced](#ray-traced-reflections) reflections and fill in where their rays find nothing (`reflection_probes.odin`, `material_reflections.hlsli`, `reflection_probe_face.hlsl`, `cube_downsample.hlsl`): cubemaps captured at placed points, prefiltered by roughness, and looked up for each pixel in the forward pass with a box projection. Where no probe counts, the sky's [cubemap](sky.md#specular-light) fills in.

- **The component:** `Reflection_Probe` (54) has these fields:
  - `extent` is the influence box's half size along its entity's x, y and z (0 means `DEFAULT_PROBE_EXTENT`, 5 m), scaled by its `Transform`.
  - `blend_distance` is how far inside the box the probe fades out.
  - With `box_projection`, a reflection turns toward where it meets the box of `projection_extent` (0 means `extent`), so a room's probe lines up with its walls. Make the influence box a little larger than the walls and set the projection box to the walls, so the fade ends outside the room.
  - `priority` orders overlapping probes, the higher first.
  - `intensity` scales the probe's light (0 means 1).
  - `update` is when the probe captures again: `On_Load` never, `On_Change` when its entity moves or one of its fields changes, and `Realtime` over and over, in turn with the other `Realtime` probes.
  - The editor's hidden entities have no probe.
- **Slots and storage:** a cube array of `RG11B10_Float` cubes holds a cube for each of the level's slots and one spare. A separate source cube is what the capture draws into.
  - With more probes than slots, the probes with the highest priority, then the nearest to the camera, take the slots. A probe past the slots keeps its own until a ranked probe needs it.
  - A probe whose slot has no cube yet counts for nothing, so its pixels take the sky's cubemap.
  - When the quality turns the reflections `Off`, the cubes are freed. `Screen` and `Ray_Traced` keep them, with `REFLECTION_PARAMS[.Probes]` at their level. A level of another size makes them again and captures every probe again.
- **The capture's turns:** the level gives a budget of faces a frame. One probe captures at a time, in this order:
  1. The `On_Load` probes with no cube yet, the nearest first.
  2. The other probes with no cube yet, the nearest first.
  3. When the frame's inputs are complete, the probes whose capture is provisional, the nearest first.
  4. An `On_Change` probe whose key changed since its capture.
  5. The `Realtime` probes, the one whose capture is oldest first.

  A probe that changes during its capture starts it over, and a probe that loses its slot ends it.
- **A capture on request:** the editor's Capture and Capture All Probes (see [Editor](../editor/viewport.md#reflection-probes)) mark probes forced (`capture_reflection_probe`, `capture_reflection_probes`).
  - A forced probe comes before every other in the turns, the nearest first, and ends a capture in flight of a probe that is not forced, which starts over later. Forcing the probe whose capture is in flight starts that capture over, so every face of the capture that answers the force is drawn after it.
  - A forced capture draws all six faces in one frame, whatever the level's budget, and the probe is no longer forced once it finishes. So one probe captures a frame, and N probes take N frames.
  - Only a probe that holds a slot can be forced. A probe added in this frame has its slot from the next.
- **Provisional captures:** a capture records whether its inputs were complete (`reflection_probe_inputs_complete`). A frame's inputs are complete when all of these are true:
  - No asset streams to the GPU.
  - Each material that the scene draws has its textures resident and its own pipelines compiled, so no bin draws a stand-in. A material whose pipelines failed draws its stand-in until its shader changes, so a capture does not wait for it.
  - The scene has at least one item to draw.

  A capture is provisional if the inputs of any frame that drew its faces were not complete. For example, an `On_Load` probe captures in the first frames of a level, while the meshes still stream. The probe uses its provisional cube and does not capture again while the inputs stay incomplete. In the first frame whose inputs are complete, it captures again. A texture that never becomes resident keeps the inputs incomplete, so the probe keeps its provisional cube.
- **Each face** is a view of the GPU scene, after the voxel cones' views: a square 90° view along the face, as a `TextureCube` samples it, from `REFLECTION_PROBE_NEAR` (5 cm).
  - It draws the opaque and masked surfaces, in a prepass and a forward pass of its own, into targets of its own, which take the textures of the face before it ([Render graph](../gpu/render-graph.md#render-graph)). It draws no view model, particles, transparent surfaces, patch surfaces or post-processing.
  - It takes the camera's level of detail, as the shadow views do, so it draws the meshlets that the camera's walk of their hierarchy picked.
  - **Its light** is linear, not pre-exposed. It has no fog, screen-space or traced reflections, or reflection probes. Its indirect light comes from the frame's [global illumination](global-illumination.md#global-illumination), by its technique:
    - **The [voxel cones](global-illumination.md#voxel-cones):** the clipmap is in world space around the camera, and the faces draw after the levels' injection and filter. So between its prepass and its forward pass, the face gathers the cones at its own pixels (`reflection probe gi`, `add_voxel_capture_gather`), as the camera's gather does at its pixels: the diffuse cones around the normal and the cone along the reflection, with no history. The forward pass reads that light as the camera's reads its GI. A texel outside every level takes the ambient light along its normal and the sky's cubemap along its reflection. A probe outside every level (`reflection_probe_voxels`) has no gather, and all of its texels take that light.
    - **The [split cascades](global-illumination.md#split-cascades):** the [world probes](global-illumination.md#world-probes)' light, where they run.
    - **The screen cascades, or no GI:** the screen cascades and their history are the camera's screen, so a face cannot read them. The face takes the ambient light along the normal and the sky's cubemap along the reflection, scaled by the ambient occlusion of its own depth (`ao_face`). It is the camera's technique, radius and power, along the face's axes, on the graphics queue. A capture has no temporal AA, so its noise stays at one slice and the denoiser takes both of its passes. Without the camera's ambient occlusion, a face has none.
  - **Its lights:** the face bins the punctual and area lights into clusters of its own, from the probe's position (`cluster_lights.hlsl`). It uses a copy of the lights without mask channels, because the mask covers only the camera's screen. The punctual lights keep their shadow maps, which are in world space. A light traced into the mask has no shadow in a capture.
  - **The directional light's shadow:** the camera's cascades do not cover a probe far from the camera. So while a probe captures, the first directional light that casts shadows gets a shadow view of its own, in a slot of the atlas (`add_orthographic_shadow_view`). It is an orthographic view of the sphere around the probe's boxes, from 1 m to 200 m across. The faces take every depth in their first cascade, which is that view. The other directional lights have no shadow in a capture.
  - **The copy** (`reflection probe copy`) writes the face into mip 0 of the source cube. Where the face drew nothing, it writes the sky's cubemap's light along the texel.
- **After the last face:**
  - The source's mip chain is made one pass per mip, each mip the mean of the one before it (`reflection probe downsample`).
  - The sky's [prefilter](sky.md#specular-light) convolves the source into the spare cube, from a mirror at mip 0 to roughness 1 at the last.
  - The probe uses that cube from that frame's view on: the frame's records give the probe the spare cube, which the view's lookups read after the prefilter, and a face looks no probe up. Its old cube, or a cube that no slot holds, becomes the spare once the frame executes. So a probe's cube never changes while a frame reads it.
  - The cube records the frame and the host's time (`platform.time_seconds`) when it finished, which the editor shows as when the probe was captured (`reflection_probe_state`).
- **Binning:** the records of the probes with a cube are in the upload ring, in this order: highest priority first, then the smallest box, so a room's probe wins over the hall around it, then by slot.
  - The cluster pass tests each probe's turned influence box against the cluster's box, using the box around it in view space. `probe_reaches_box` is the matching Odin test.
  - Each cluster keeps the first `MAX_CLUSTER_PROBES` (7) probes in a fixed list: its count, then its indices.
- **The lookup** (`reflection_probe_specular`): the forward pass finds its cluster from its point, as it does for the lights, so the view model and the transparent surfaces get their probes too.
  - Each probe's weight is its box's fade at the point, times what the probes before it left, until the weights reach 1.
  - A probe samples its cube along the reflection, at the mip for the surface's roughness, times its intensity. With a projection box, the reflection is box-projected first.
  - The rest of the light comes from the sky's cubemap.
- **With the GI**, on opaque surfaces, the probes blend over the GI's specular light below a roughness fade, from `rough_start` to `rough_end`, so rough surfaces keep the GI's dynamic occlusion. The ambient occlusion scales the probes' light, which has no local occlusion of its own. Transparent surfaces take the probes and then the sky's cubemap, never the GI's specular light.
- **The capture's brightness**, measured in Intel's Sponza with the probe that fills its courtyard, `Realtime`. A mirror, 4 m by 3 m, stood in the courtyard and reflected the arcade behind the camera, through the probe. The reference is the arcade itself, seen from the camera's image across the mirror's plane with the mirror taken away, flipped. Both views had a manual exposure, no tone mapping, bloom or clouds, and the reflections at `Probes`. The table gives the mirror's mean linear luminance over the reference's, for the arcade above the floor and for the floor. The mirror's reflectance is about 0.95.

  | Quality | Arcade, without the GI in captures | Arcade, with it | Floor, without | Floor, with |
  |---|---|---|---|---|
  | Ultra, voxel cones | 10.5 | 1.92 | 2.53 | 1.31 |
  | Low, voxel cones | 8.9 | 1.79 | 2.46 | 1.27 |
  | Ultra, screen cascades | 2.28 | 1.80 | 1.56 | 1.52 |
  | Low, screen cascades | 2.21 | 1.93 | 1.56 | 1.54 |

  - With the shadows off in both views, the voxel cones' ratios were 1.59 for the arcade and 1.08 for the floor. So part of what is left is the capture's own shadow view, which lights the floor under the arcade where the camera's shadows do not.
  - The faces' own ambient occlusion on top of the voxel cones took the arcade's ratio only from 1.92 to 1.81, for 14 to 34 µs a face, so the faces take it only where their light is the ambient light.
- **The fade's range** is 0.2 to 0.45 at every level. It comes from the same courtyard, from the frame's mean linear luminance with the probes over the frame without them, at three views: the courtyard from its end, the arcade, and the nave.
  - Before captures had GI, with the fade at 0.5 to 0.8, Sponza's stone, at roughness 0.5 to 0.75, took the captures' unoccluded light: at Ultra with the voxel cones, the frame's mean brightness rose from 52 to 70, and the columns and arches turned milky.
  - With GI in the captures, the fade at 0.5 to 0.8 still made the frame brighter with the voxel cones, at every level: by 5 to 10% in the view of the courtyard, 2 to 7% in the nave, and 0.4 to 1% at the arcade. With the screen cascades it changed the frame by -2 to +1%, and with the split cascades by +1 to +2%.
  - From 0.2 to 0.45, the stone and the curtains keep the GI's specular light, and the probes change the frame by at most 0.1%, or 2% with the split cascades. Only glossy surfaces take the probe.
- **Parameters:** `REFLECTION_PARAMS[.Probes]` at the reflections' level (see [Quality](quality.md#quality)), with the sky cubemap's samples per texel.

| Level | Faces | Mips | Slots | Faces a frame | Fade | Memory |
|---|---|---|---|---|---|---|
| Low | 64 | 5 | 16 | 1 | 0.2 to 0.45 | 2.25 MiB |
| Medium | 128 | 6 | 32 | 2 | 0.2 to 0.45 | 17.0 MiB |
| High | 128 | 6 | 64 | 3 | 0.2 to 0.45 | 33.0 MiB |
| Ultra | 256 | 7 | 64 | 6 | 0.2 to 0.45 | 132.0 MiB |

- **Memory** is the array's cubes, with the spare, and the source cube, with their mips (`reflection_probe_memory`).
- **Cost** was measured on an RTX 5090, in the editor's viewport at 911x481, in the glass scene with its `Realtime` probe. Each level ran at its own preset, and each figure is the mean of three captures of 16 frames.
  - A face is its prepass, its forward pass and its copy. A capture's end is its mips and its prefilter, after every sixth face.
  - A frame with faces also bins the faces' lights, which takes 4 to 5 µs.
  - At Ultra, the probes add about 0.4 ms to the frame: 1.99 ms with them, against 1.57 ms with the reflections off.

| Level | A face | A capture's end |
|---|---|---|
| Low | 30 µs | about 19 µs |
| Medium | 26 µs | about 30 µs |
| High | 28 µs | about 30 µs |
| Ultra | 24 µs | 82 µs |

- **The GI's cost in a face** was measured the same way in Sponza, whose faces draw more than the glass scene's, with the courtyard's probe `Realtime`, in a viewport of 746x481. Each level ran at its preset, with the reflections at `Probes` and the GI's technique set. A face is its prepass, its forward pass, its copy, and its gather or its ambient occlusion.

| Level | A face without the GI | With the voxel cones | Their gather | With the screen cascades | Their ambient occlusion |
|---|---|---|---|---|---|
| Low | 57 µs | 113 µs | 56 µs | 71 µs | 14 µs |
| Medium | 60 µs | 148 µs | 85 µs | 79 µs | 16 µs |
| High | 62 µs | 185 µs | 119 µs | 84 µs | 18 µs |
| Ultra | 77 to 86 µs | 226 µs | 144 µs | 115 µs | 34 µs |

- **The debug view** `Reflection_Probes` colors each pixel by its strongest probe's cube, and red where no probe counts.
- **The Resource Monitor** shows the probes, the slots whose probe has a cube, and the faces that the frame captured (`reflection_probe_stats`), and the reflections' memory: the probes' cubes while they are made, and the screen-space or traced reflections' histories (`reflection_memory`).
- **The sample:**
  - The room scene's probe fills the room, and its projection box is the walls. Its polished floor reflects the pillar at the pillar's foot.
  - The glass scene has two probes that overlap over the glass. The sorted side's probe is `Realtime`, so it follows the lamp that the spinner carries.
  - Both show at every quality but `Off`. At Medium, the screen-space reflections are in front of them, and from High up the traced reflections where the device has `Ray_Query`.
- **Limits:**
  - A capture sees no patch surfaces, particles or transparent surfaces.
  - A probe's light is the light at its position. The box projection corrects the parallax only for its box.
  - A probe has no occlusion of its own beyond the ambient occlusion, so the reflections in a dark corner are as bright as in the middle of the probe.
  - A capture is still brighter than the scene that it reflects: 1.8 to 1.9 times in Sponza's arcade (see [The capture's brightness](#reflection-probes)). Its own shadow view is a part of that, and so are the faces' sun without the clouds' shadow, and the box projection, which spreads each part of the cube over another share of a surface than the scene's own view does.
  - The voxel cones' gather costs 56 to 144 µs a face, so at Ultra a `Realtime` probe adds about 0.9 ms to each frame for its six faces.

### Screen-space reflections

`Reflection_Technique.Screen`, the reflections of the Medium preset, and of High and Ultra on a device without `Ray_Query` (`screen_reflections.odin`, `ssr_common.hlsli`, `ssr_march.hlsli`, `ssr_depth.hlsl`, `ssr_trace.hlsl`, `ssr_resolve.hlsl`, `ssr_temporal.hlsl`, `ssr_lit.hlsl`): stochastic screen-space reflections, after Stachowiak's "Stochastic Screen-Space Reflections" (SIGGRAPH 2015). Rays from each pixel's surface, sampled by its roughness, march the depth buffer and take last frame's lit scene where they hit. Where they find nothing on the screen, the [reflection probes](#reflection-probes) fill in, which run under this technique too, over the GI or the sky's cubemap.

- **The frame's reflections:** `Frame.reflections` is an `RGBA16_Float` texture at the scene's size.
  - Its rgb is the specular light along the reflection, already filtered for the pixel's roughness, and pre-exposed. Its alpha is its weight.
  - The forward pass's specular light becomes `lerp(below, reflections.rgb, reflections.a)`. `below` is the probes over the GI or over the sky's cubemap. The ambient occlusion scales `below` only, because a hit on the screen is already occluded.
  - Only the camera's view reads it. `Frame_Constants.reflections` is 1 in the camera's constants and 0 in the constants of the view model, the probes' captures and the material previews. Transparent surfaces do not read it, because they have no prepass.
  - The [traced reflections](#ray-traced-reflections) write the same texture, with the same contract.
- **When it runs:** `begin_screen_reflections` decides, after `begin_gi` and before the scene's constants are written. A frame whose technique is `Ray_Traced` but that cannot trace has these reflections at the same level (see [Ray-traced reflections](#ray-traced-reflections)). Some frames have no texture and no pass, and their `Frame.ssr` is nil:
  - a frame whose technique is neither `Screen` nor `Ray_Traced`, or whose settings have `off`;
  - a frame before the five pipelines are ready;
  - a frame before the noise texture is resident.
- **The passes** run on the compute queue after the prepass, beside the ambient occlusion and the GI:
  1. **The depth pyramid** (`reflections depth`, two dispatches):
     - The occlusion's [depth pyramid](gpu-scene.md#occlusion-culling) holds the farthest depth of the early prepass, so it does not serve.
     - This pyramid holds the nearest depth of the whole prepass. With the depth reversed, the nearest depth is the largest.
     - Level 0 is the depth at the scene's size, with the view model's pixels at the far plane, because the view model is not where it seems to be. Each later level is half the one before, rounded up, to `SSR_DEPTH_LEVELS` (9).
     - A group covers 16x16 texels of its source and writes four levels through group-shared memory. The first dispatch writes levels 0 to 4. The second reads level 4 and writes levels 5 to 8.
     - Each level is an `R32_Float` texture of its own, because the graph has no views of a transient texture's mips.
  2. **The trace** (`reflections trace`):
     - A thread starts from each pixel, or from one pixel of each block of the level's stride, 2x2 at Low and Medium, which changes from frame to frame (`ssr_offset`: the diagonal first in a 2x2 block, `SSR_HALF_OFFSETS`).
     - Its rays reflect the view direction about a normal sampled from GGX's distribution of visible normals, at the pixel's roughness (Heitz, "Sampling the GGX Distribution of Visible Normals", JCGT 2018).
     - Each ray marches the pyramid on the screen, where the reversed depth is linear (`ssr_march.hlsli`, which the traced reflections' trace shares). In front of a texel, the ray skips to the texel's edge or to the depth that the texel holds, and climbs a level. Behind a texel, it descends a level. This continues until the ray is behind a texel of level 0.
     - The ray hits there if it is within 3% of the surface's view depth (`THICKNESS`). If it is further behind, it has passed behind the surface and finds nothing.
     - A hit takes the light in last frame's lit scene at the place where the hit point was then, times this frame's exposure.
     - Each ray keeps its direction, its distance to the hit (0 for a miss) and its pdf. The pdf is clamped to `MAX_PDF` (60000) so that it fits a half float.
  3. **The resolve** (`reflections resolve`, at the scene's size):
     - Each pixel reuses the rays of its own trace texel, the one whose block holds it, and of three neighbors, from a ring that the noise turns each frame.
     - A ray counts by this pixel's GGX specular times the cosine, without Fresnel, divided by the ray's own pdf. This is Stachowiak's ratio estimator: the weighted light divided by the sum of the weights is the light filtered by the pixel's own lobe.
     - The ray's direction from this pixel goes toward the ray's hit, or along the ray for a miss.
     - The resolve also keeps the mean distance to the hits.
  4. **The temporal pass** (`reflections temporal`) blends the resolve into last frame's result:
     - It reprojects the place where the reflected point was. A mirror shows that point at the hit's distance behind the surface, along the view ray, so a reflection does not smear as the camera moves.
     - A pixel whose rays found nothing reprojects its surface, by its velocity.
     - The history is rescaled by the change in exposure, clamped to the 3x3 neighborhood's mean ± 1.25 standard deviations, and blended in with a weight of 1 / frames.
     - The frames grow from `SSR_MIN_FRAMES` (2) on a mirror, whose reflection changes with every move, to `SSR_MAX_FRAMES` (16) at the cutoff, whose noise needs the most averaging.
     - The result is `Frame.reflections`.
- **The lit scene:** the rays read last frame's scene without its pre-exposure.
  - At half resolution, the [GI's lit scene](global-illumination.md#global-illumination) serves when the GI runs. It is half the scene's size, a mean of each 2x2 block, and holds the fog in front of each surface, which is acceptable at Low and Medium.
  - Otherwise, the pass `reflections lit scene` keeps a copy of its own after the world pass, on the graphics queue. From High up, the copy is at the scene's size.
  - Both copies hold only the opaque surfaces, the sky and the fog.
- **The weight** is 0 for these rays:
  - a miss, which includes a ray that leaves the screen or passes behind a surface;
  - a hit on a surface that faces away from the ray, because the lit scene does not have the surface's back;
  - a hit whose point was off the screen last frame.

  The weight also fades out over the last 10% of the screen toward each edge, at the hit point, and over the 0.1 of roughness below the level's cutoff (`CUTOFF_FADE`). Above the cutoff, a pixel traces nothing.
- **Noise:** the rays and the resolve's ring read spatiotemporal blue noise from `stbn_vec2.png`: 32 layers of 128x128 uniform 2D values. `tools/stbn` makes the texture (`just stbn`). The [ambient occlusion](ambient-occlusion.md#ambient-occlusion) samples the same texture. `blue_noise.odin` requests it, and the passes that read it wait until it is resident. `blue_noise.hlsli` reads it.
  - The method is Wolfe, Morrical, Akenine-Möller and Ramamoorthi's, "Spatiotemporal Blue Noise Masks" (EGSR 2022), for vector values. Each slice starts with the same stratified set of values in a random order, so each slice's values stay exactly uniform. A swap of two values in a slice is kept when it lowers Georgiev and Fajardo's energy, with σ = 1.9 in space and in time. The energy is summed over the pairs of texels in each slice and the pairs of slices at each pixel, with a half share each.
  - Multiplying the space and time terms instead, over a window in space and time, gives too little of the energy to the pairs at one pixel. On a 16x16x8 test, the product left 41% of white noise's low-frequency power in space and 73% in time. The sum left 4% and 18%.
  - At its 256 swaps a texel, the texture keeps 4.3% of white noise's power at the lowest spatial frequencies and 4.5% at the lowest temporal frequency. The tool takes 33 s on 32 threads, and the same seed gives the same bytes.
  - The texture's `.meta` file sets `usage = data`, so it is not compressed, and `layout = array_strip`, so it cooks into a 2 MiB array. Each pixel's rays read it at their own offsets, and the slice changes each frame.
- **Parameters:** `REFLECTION_PARAMS[.Screen]` at the reflections' level (see [Quality](quality.md#quality)). The table gives the memory at 2560x1440. Kept is what stays between frames: the history and the lit scene of its own. Transient is the pyramid, the rays and the resolve.

| Level | Rays from | Rays a pixel | Steps | Cutoff | Kept | Transient |
|---|---|---|---|---|---|---|
| Low | 1 pixel of 2x2 | 1 | 16 | 0.3 | 56 MiB, or 70 MiB without the GI | 68 MiB |
| Medium | 1 pixel of 2x2 | 1 | 32 | 0.4 | 56 MiB, or 70 MiB without the GI | 68 MiB |
| High | Each pixel | 1 | 48 | 0.5 | 113 MiB | 110 MiB |
| Ultra | Each pixel | 2 | 64 | 0.6 | 113 MiB | 167 MiB |

- **Cost** was measured on an RTX 5090, in the room scene, with the camera inside the room and looking down it at the mirror and the brushed panel.
  - Each level ran at its own preset, with `Screen` at that level, in the editor's viewport at 2563x835. Each figure is the median of five captures, and each capture is an average over a quarter of a second.
  - The monitors are 2560x1440, so the editor's viewport cannot be that size. The 1440p figures are the measured figures scaled by the number of pixels, 1.72 times. Every pass is per pixel, so the estimate is close, but the trace's rays are also longer on a larger screen.
  - At Low and Medium, the GI's lit scene serves, so these levels have no lit pass.

| Level | Depth | Trace | Resolve | Temporal | Lit scene | Total at 2563x835 | Total at 1440p, scaled |
|---|---|---|---|---|---|---|---|
| Low | 22 µs | 18 µs | 31 µs | 21 µs | None | 92 µs | About 0.16 ms |
| Medium | 22 µs | 25 µs | 31 µs | 22 µs | None | 100 µs | About 0.17 ms |
| High | 22 µs | 73 µs | 32 µs | 22 µs | 20 µs | 169 µs | About 0.29 ms |
| Ultra | 22 µs | 136 µs | 46 µs | 22 µs | 20 µs | 246 µs | About 0.42 ms |

- **The debug view** `Reflections` shows the texture's rgb times its weight. It is black where the probes take over.
- **The sample:**
  - The room scene has a mirror on its floor, which shows the green partition sharply.
  - A panel of brushed metal at roughness 0.3 blurs the red pillar.
  - The checker floor, at roughness 0.08, reflects the walls.
  - When the camera strafes and turns, neither reflection leaves a trail.
- **Limits:**
  - The screen has only what the camera sees. The back of a surface, what is behind it and what is off the screen come from the probes.
  - A ray that passes behind a thin object finds nothing past it, because the march stops there.
  - On a glossy surface, a fine grain stays in the debug view. Temporal AA averages it in the lit frame.
  - The lit scene is last frame's, so a light that turns on shows in reflections one frame late.
  - A moving object's reflection is reprojected as if the reflected point were still. The neighborhood clamp limits the error.

### Ray-traced reflections

`Reflection_Technique.Ray_Traced`, the reflections of the High and Ultra presets on a device with `Ray_Query` (`traced_reflections.odin`, `rtr_common.hlsli`, `rtr_trace.hlsl`, `rtr_light.hlsl`). Rays from each pixel's surface, sampled by its roughness as the [screen-space reflections](#screen-space-reflections)' are, trace the [ray scene](ray-scene.md#ray-scene), and [hit shading](ray-scene.md#hit-shading) shades their hits. They see what the screen does not: what is behind the camera, off the screen and hidden behind other surfaces. They are the screen-space reflections' frame, `Frame.ssr`, with its noise, its lit scene, its resolve and its temporal pass, so they write `Frame.reflections` with the same contract, and the [reflection probes](#reflection-probes) fill in where they have no weight.

- **When it runs:** `begin_screen_reflections` calls `begin_traced_reflections`, which gives the frame's traced reflections, or nil, and the frame then has the screen-space reflections at the same level:
  - on a device without `Ray_Query`. `clamp_quality` already gives `Screen` there, so a settings file's `Ray_Traced` does not reach the frame; `CINNABAR_DISABLE_FEATURES=Ray_Query` hides the feature for a test;
  - before the two pipelines, the binning's, the fallback's and the hit light's and screen light's have compiled;
  - in a frame without draw items or a hit table. Once the pipelines are ready, `begin_traced_reflections` requests the ray scene, whose first request makes the hit table from the next frame on.

  When the passes are added, a frame whose hit shading cannot take another batch (`hit_shading_ready`), or whose light list does not fit the upload ring, takes the screen-space trace at the same level too: its params, stride, trace size and constants, which one proc (`configure_ssr`) sets for both fallbacks. Only the lit scene stays as the frame chose it for the traced reflections, since a history is used once a frame. So `Frame.reflections` is always written once `Frame.ssr` is set.
- **The passes** run on the compute queue after the prepass, after the GI's:
  1. **The depth pyramid** (`reflections depth`), the screen-space reflections', when the level marches the screen first.
  2. **The trace** (`reflections ray trace`, `rtr_trace.hlsl`): a thread for each trace texel, whose ray starts from one pixel of its block, in turn from frame to frame (`ssr_offset`).
     - The ray's direction is the screen-space reflections' (`sample_ray`), from GGX's distribution of visible normals at the prepass's roughness, and the blue noise.
     - With the level's steps, the ray first marches the screen (`screen_ray` in `ssr_march.hlsli`). A hit there whose whole weight holds, which is not near the screen's edge, not a back face and on the screen last frame, takes last frame's lit scene, and the ray traces nothing.
     - Otherwise the ray starts at the pixel's surface, moved off it along the normal by 1.5 pixels at its depth, and traces `RAY_MASK_SURFACES` with `trace_hit` as far as `RTR_FAR` (10 km). Its cone widens by the larger of a pixel's angle and the GGX alpha, so a rough reflection samples coarser texture levels.
     - A hit past the level's distance is stored as a miss, so hit shading skips it, and has no weight. So does a ray below the surface.
  3. **Hit shading** of the rays as a batch of their own (`add_hit_shading`, named `reflections`): with the world probes and the split cascades, the frame's third of `MAX_HIT_BATCHES`. The turn is taken before the trace. When it fails, as when an upload fails, the trace still runs, and its hits have no weight.
  4. **The hits' light** (`reflections hit light`, `reflections hit screen`): the GI's passes (see [World probes](global-illumination.md#world-probes)). A hit's light is its emission, the directional lights and up to 16 punctual lights whose spheres reach the level's distance, each with a shadow ray, and the world probes' light at the hit where they run. Without them the grid has no levels, and the hit takes the ambient light. A hit that the screen shows takes last frame's lit scene instead.
  5. **The light** (`reflections ray light`, `rtr_light.hlsl`): each waiting ray's light, pre-exposed, into the trace's radiance texture. A ray that found nothing takes the sky's [cubemap](sky.md#specular-light) along it, at roughness 0, and `RTR_FAR` as its distance, so the temporal pass reprojects a point far away and not the surface. A back face has no weight.
  6. **The resolve and the temporal pass**, the screen-space reflections': the ratio estimator over four trace texels, by the pixel's own lobe, so a mirror takes almost no blur, and the temporal pass reprojects the reflected point by the hit's distance.
  7. **The lit scene** (`reflections lit scene`) after the world pass, or the GI's at Low and Medium.
- **Metal in reflections.** `Hit_Surface` carries the specular albedo beside the diffuse albedo, in 32 bytes still (see [Hit shading](ray-scene.md#hit-shading)), and the hits' light adds it times the probes' light at the hit, or the sky's cubemap along the hit's reflection. So a gold box in a mirror is gold, not black. The direct lights' highlights on a reflected metal are not drawn.
- **The march first.** A short march on the screen before the trace was measured against tracing every ray. The march saves no time: the binning, the hits' light and the light pass still run over every ray, and the pyramid costs 32 µs at 1461x800. It costs about 0.1 ms more at 1440p in both scenes below. But the ray scene has no instance sets, patch surfaces or particles, and the march shows foliage, terrain and water where they are on the screen, so every level marches 16 steps first. A level with `steps = 0` traces every ray and builds no pyramid.
- **Parameters:** `REFLECTION_PARAMS[.Ray_Traced]` at the reflections' level. No preset takes Low or Medium, but a custom quality may. A trace larger than `MAX_HIT_RAYS` rays doubles the block along x, then y, until it fits (`reflection_stride`), so Ultra at 3840x2160 traces one pixel of each 2x1 block.
  - Kept is what stays between frames: the screen-space reflections' history and lit scene, and the rays' hits (32 B), surfaces (32 B) and light (16 B) and hit shading's order (4 B), for each ray. Transient is the pyramid, the ray and radiance textures and the resolve. The memory is at 2560x1440.

| Level | Rays from | Steps | Cutoff | Distance | Kept | Transient |
|---|---|---|---|---|---|---|
| Low | 1 pixel of 2x2 | 16 | 0.3 | 50 m | 130 MiB, or 144 MiB without the GI | 68 MiB |
| Medium | 1 pixel of 2x2 | 16 | 0.4 | 100 m | 130 MiB, or 144 MiB without the GI | 68 MiB |
| High | 1 pixel of 2x1 | 16 | 0.5 | 200 m | 261 MiB | 82 MiB |
| Ultra | Each pixel | 16 | 0.6 | 500 m | 408 MiB | 110 MiB |

- **Cost** was measured on an RTX 5090, in the editor's viewport at 1461x800, with each preset's own quality and `Ray_Traced` at its level, so the world probes and the split cascades ran too. Each figure is the median of five captures, and each capture is an average over a quarter of a second. The 1440p figures are scaled by the number of pixels, 3.15 times.
  - The room scene: the camera near the front wall, looking down the room at the wall mirror.
  - Sponza's nave: the scene's camera, at the nave's end, looking down it. The nave's figures varied by about 10% between two runs; the table has the first.

| Scene, level | Depth | Trace | Hit bins | Hit shading | Hit light | Light | Resolve | Temporal | Lit scene | Total at 1461x800 | Total at 1440p, scaled |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Room, High | 33 µs | 37 µs | 37 µs | 11 µs | 24 µs | 8 µs | 14 µs | 13 µs | 13 µs | 189 µs | About 0.60 ms |
| Room, Ultra | 33 µs | 59 µs | 47 µs | 14 µs | 33 µs | 12 µs | 14 µs | 13 µs | 13 µs | 237 µs | About 0.75 ms |
| Nave, High | 32 µs | 52 µs | 69 µs | 34 µs | 60 µs | 8 µs | 17 µs | 15 µs | 13 µs | 300 µs | About 0.95 ms |
| Nave, Ultra | 32 µs | 85 µs | 149 µs | 104 µs | 115 µs | 14 µs | 23 µs | 16 µs | 13 µs | 551 µs | About 1.74 ms |

  Without the march, the same views took 156 and 210 µs in the room and about 258 and 515 µs in the nave. The screen-space reflections took 98 and 119 µs in the room and 119 and 203 µs in the nave.
- **Checks** in the room scene at High:
  - The wall mirror shows the gold box behind the camera, gold. The screen-space reflections show the probe's cube there.
  - Where both see the same surface, the floor under the far wall, the traced and the screen-space reflections agree within 4% in each channel, and tracing every ray without the march within 1%.
  - Over 40 screenshots of the `Reflections` debug view from a still camera, each pixel's spread is at most 1 code at the 99th percentile and 2.3 at the 99.9th (the screen-space reflections: 0.8 and 12, see [Flicker](../editor/capture.md#flicker)). While the camera strafes, the mirror and the floor leave no trail.
- **The debug view** `Reflections` shows the texture, as for the screen-space reflections.
- **The sample:** the room scene has a mirror on the far wall, facing the camera, and a gold box behind the camera's start.
- **Limits:**
  - The ray scene has no instance sets, patch surfaces or particles, so foliage, terrain and water are missing from what the rays see, except where the march finds them on the screen.
  - Transparent surfaces are not in what the rays see, and transparent surfaces do not trace: they keep the probes.
  - A hit's light is the GI's hit light: diffuse, with the probes' light for the specular part. A reflected metal shows no highlights of the direct lights, and its reflection is the probes' light around its normal, not along its reflection.
  - Each ray is one sample of the pixel's lobe. A rough surface near the cutoff takes the temporal pass's longest history, so a light that moves in its reflection lags.

### Shadows

| Light | With `Ray_Query` | Without |
|---|---|---|
| Directional | A screen-space mask: a compute pass traces from the prepass depth | A [virtual shadow map](#virtual-shadow-maps), or cascaded shadow maps at Low and when the quality turns it off, with screen-space contact shadows for the sun |
| Spot, point | A mask for the few most important; maps for the rest | A shadow atlas |
| Quad, disk, line | A mask channel that traces toward the light's shape | As a point light at the light's middle, as soft as the light's size |

- **Which lights:** the lights that cast shadows take them in order: the directional lights, then the punctual lights by how much light they bring to the view (their brightest channel over their squared distance), leaving out those whose spheres miss the view (`assign_shadows`). With `Ray_Query` and traced shadows in the [quality](quality.md#quality), the first `MAX_MASK_LIGHTS` (4) take the mask's channels. The others take shadow maps while the atlas has room. Only one directional light has a virtual shadow map or cascades; another without a mask channel has no shadow.
- **The cloud shadow:** with [clouds](clouds.md#shadow), the directional light that lights them, the sky's linked sun, also has their shadow map, whatever its own shadow: `light_falloff` darkens its light by the map wherever the light loop runs, so the forward pass, the transparent surfaces, the sprites, the fog, the global illumination's hits and the voxel cones all see it. For the fog, the sprites and the transparent surfaces it is the only directional shadow past the shadow maps' 100 m.
- **The shadow mask** is a screen-space texture, `RGBA8_Unorm`, with one channel for each traced light. A compute pass (`shadow_mask.hlsl`) rebuilds each pixel's position from the prepass's depth, where the camera's jitter put the pixel's center, moves it off the surface along the prepass's normal by a hair, a tenth of a millimeter per meter of depth plus two thousandths of a millimeter per meter from the render origin, which is up to 1.5 km away, and traces one ray toward each light with `RayQuery` from the same hair along the ray, accepting the first hit, against the instances that cast shadows (`RAY_MASK_SHADOWS`). An offset along the normal moves a shadow's edge across the surface by the offset over the tangent of the light's angle to the normal, so two surfaces that meet at a crease disagree on where the shadow crosses their seam by as much; an offset along the ray moves nothing, so the hair is only what the depth's precision needs. A light records its channel, and the forward pass reads the channel at its pixel. A light with no size traces toward its middle, and its shadow is hard; a light with a size traces toward its shape, and the mask's denoiser averages its rays (see [The traced mask](#the-traced-mask)). This is the sample's ray-traced shadow, made general.
- **Contact shadows:** a frame whose sun has a shadow map and no channel of the mask, on a device without `Ray_Query` or at a quality that does not trace, gives the sun contact shadows too, for the contacts that the map's texels are too coarse for: a foot on a floor, a cup on a table, a curtain's hem. A compute pass (`contact_shadows.hlsl`, `contact shadows`), on the compute queue after the [ambient occlusion](ambient-occlusion.md#ambient-occlusion), marches each pixel 0.3 m toward the sun on the screen in 16 steps (`CONTACT_LENGTH`, `CONTACT_STEPS`), from a start that the ambient occlusion's blue noise offsets, through the ambient occlusion's depth levels: a step `d` pixels out reads the level `log2(d) - 3.3`, as the ambient occlusion's search does, whose texels take the surface behind over a thin one in front, so a thin pole does not cast a wide shadow. A step occludes where it is behind the surface there by less than 5 cm or two steps (`CONTACT_THICKNESS`), and the occlusion fades out over the march's last quarter. The pixel's plane comes from its neighbors' depths, not from the prepass's normals, which a normal map tilts, and a surface occludes only if it rises above that plane by 0.2% of the pixel's depth plus as much again as its distance along the plane (`CONTACT_BIAS`, `CONTACT_SLOPE`): a depth bias alone would not do on a surface seen at a grazing angle, where one pixel spans more depth than any bias, and the slope keeps the facets of a coarse mesh that its normals shade smooth from shadowing themselves, while an object that the surface touches rises far more steeply. The view model neither casts nor takes them, as the ambient occlusion keeps the two apart. The result is one `R8_Unorm` target, not a channel of the mask: a frame that has it traces no mask, and a mask channel means that a light has no shadow map, where the contact shadows darken the map's light. The sun's record has `Contact_Shadow` (`LIGHT_CONTACT_SHADOW`), and the forward pass's opaque surfaces multiply its light by the target, which they read from `Material_Push.shadow_mask`, since a frame has one or the other. The transparent surfaces, the sprites, the GPU particles and the fog do not take them: only the forward template's own push constants define `MATERIAL_SCREEN_SHADOWS`. Without the ambient occlusion, as with `Ambient_Occlusion.off` or the quality's technique `Off`, there are no depth levels, so there are no contact shadows, and the forward pass reads white. The `Shadow_Mask` debug view shows them in red, as the sun's channel of the mask. The punctual lights have none.
- **Contact shadows' cost** was measured on an RTX 5090 in Sponza without `Ray_Query`, in the editor's viewport at 1196x568, as the median of five captures, each an average over a quarter of a second, and scaled to 1080p by the pixels. The march is the same at every level, and so is its cost:

  | Level | `contact shadows` at 1196x568 | At 1080p, scaled |
  |---|---|---|
  | Low | 25.0 µs | 76 µs |
  | Medium | 25.1 µs | 77 µs |
  | High | 25.2 µs | 77 µs |
  | Ultra | 25.2 µs | 77 µs |

- **Acceleration structures:** the mask traces the ray scene, which traced shadows request (see [Ray scene](ray-scene.md#ray-scene)). A mesh's bottom-level structure holds all its triangles, opaque. The residency table creates it when the mesh becomes ready, once the first frame has traced (see [GPU residency](assets.md#gpu-residency)); that frame also creates the top-level structure and gives every resident mesh its own. The frame that next traces builds them, then the top-level structure, before the prepass. When the quality turns tracing off, they stay.
- **The atlas:** one `D32_Float` texture, a frame's transient, as large as the level's `Shadow_Params` say (`SHADOW_PARAMS`; 4096 at High, see [Quality: Levels](quality.md#levels)). A cascade takes a cell (1024 pixels at High), from the first cells; a spot light takes a slot (512 at High), four to a cell, and a point light six slots, one for each face of its cube.
- **Cascades:** the level's, up to `SHADOW_CASCADES` (4), which cover the view to `SHADOW_DISTANCE` (100 m), split between even and exponential by `SHADOW_SPLIT_LAMBDA` (0.75), unless the volumes' `Shadows` settings give others (see [Settings](frame.md#settings)). Each is an orthographic view of the bounding sphere of its slice of the view's frustum. The sphere's radius is rounded up to sixteenths of a meter, and its center snaps to the cascade's texels in the render origin's space, so the shadow's edges stay still as the camera moves and turns. Depth is clamped, not clipped, and culling has no plane toward the light, so casters between the light and the view still cast.
- **In an [orthographic view](frame.md#orthographic-views)** the cascades split evenly from the near plane to the shadows' distance past it, or to the far plane if that is nearer, and each slice of the view is a box. The virtual shadow map gives way to the cascades there, and the screen-space and ray-traced reflections to the reflection probes.
- **Spot and point lights:** a perspective view with reversed depth from `SHADOW_NEAR` (5 cm), as wide as the spot light's cone or 90° for each cube face, culled at the light's range. An area light's shadows are a point light's from its middle, as soft as its size (see [Soft shadows](#soft-shadows)). A light with a size widens its views by a guard band.
- **The depth pass:** the shadow maps are one render pass with a piece for each view, each with its own viewport of the atlas. Each draws its view's bins with each material's depth pipeline, so masked materials cast the right shadows. The pipelines have a depth bias and a slope bias against acne, `SHADOW_DEPTH_BIAS` and `SHADOW_SLOPE_BIAS`.
- **Sampling:** the forward pass moves the point half a texel of the view toward the light, against the map's depth precision, and along its normal by half a texel times the sine of the light's angle to the normal, against the taps' spread where the light grazes the surface. A normal offset moves the edge across the surface by the offset over the tangent of that angle, so the sine keeps a crease's seam within half a texel, and the casters' slope bias covers the rest. It projects the moved point and takes the level's bilinear comparisons with a comparison sampler (`Frame_Constants.shadow_filter`): one, the hardware's 2x2; four a half texel apart, which filter a 3x3 neighbourhood; or nine a texel apart, which filter 4x4. The taps stay inside the view's rectangle. A directional light with cascades picks the first that reaches the pixel's depth; beyond the last, it casts no shadow. A point light picks the face of the direction from the light.
- The ray-tracing pipeline path stays the sample's alternative (see [GPU](../gpu/ray-tracing.md#ray-tracing)). Every ray-traced path has the shadow map fallback: a device without `Ray_Query`, and the lights after the mask's four, take shadow maps.

### Soft shadows

A light with a size casts shadows whose edges, the penumbrae, widen with the distance from their casters. Each light has one size, for every shadow path that takes it.

- **The sizes:** `Directional_Light.angular_diameter`, in degrees, and `Point_Light.source_radius` and `Spot_Light.source_radius`, in meters (see [Components](assets.md#components)). An area light's size comes from its shape: the radius of a sphere with its quad's or its disk's area, `sqrt(4·hx·hy / π)` or `sqrt(rx·ry)`, or its line's half length. A size of 0 is a point, whose shadows are hard.
- **The record:** a directional or a punctual light has no shape, so `Light_Record.extent.x` holds its size: the tangent of a directional light's angular radius, which is its disk's radius 1 m away, and a punctual light's source radius. `light_size` (`lights.odin`, `light_record.hlsli`) gives any light's.

| Path | Soft shadows |
|---|---|
| The atlas's spot, point and area lights | Percentage-closer soft shadows, from Medium up |
| The traced mask | One ray toward the light's shape, and a denoiser |
| The virtual shadow map | Shadow map ray tracing, from High up |
| The cascades | None: hard, as the directional light's fallback at Low and in orthographic views |

#### The traced mask

A channel of the [shadow mask](#shadows) whose light has a size is soft (`Shadow_Frame.mask_soft`, a bit each): its ray goes toward a point on the light's shape, and a denoiser of two passes averages the rays over time and over the surface. A light with no size traces toward its middle as before, and the denoiser passes its channel through. A frame with no soft channel runs no denoiser, and a frame whose denoiser has not compiled yet traces every channel toward its light's middle.

- **The point** (`light_point` in `shadow_mask.hlsl`): a quad's uniform point, a disk's or an ellipse's, a point along a line, a uniform point of a sphere's disk that faces the pixel, or a point of the sun's disk 1 m away. The blue noise picks it, a new slice each frame, at an offset of the noise for each channel, so the channels' points do not move together.
- **Facing:** a ray toward a point of a soft light behind the surface is lit, as an area light's ray toward a middle behind the surface was: the shading says how much of the light is above the horizon, and the mask only what blocks it.
- **The penumbra:** a ray that a blocker stops writes the radius of the penumbra that the blocker casts, into a second target, `RGBA16_Float`, beside the raw visibility: the light's size times the hit's distance `t` over the blocker's distance from the light's point, or `t` times the tangent of the sun's angular radius.
- **The temporal pass** (`shadow_denoise_temporal.hlsl`, `shadow mask temporal`) averages each soft channel with its history, last frame's average where the velocity says the surface was, in a pair of `history_texture`s: the average, `RGBA16_Float`, and its frames over `MASK_HISTORY_FRAMES` (16), `RGBA8_Unorm`. The history is clamped to the raw visibilities around the pixel, two pixels apart, so a shadow that moves or a surface that the history did not see starts again, while a penumbra's mostly lit or mostly shaded side keeps its average.
- **The history follows its light:** `assign_shadows` ranks the lights anew each frame, so two lights can swap channels. `Mask_History` in the view's state holds each soft channel's light entity, which the frame sets once it executes, and `mask_history_channels` gives each channel last frame's channel of the same light, or none, so that channel starts again.
- **The spatial pass** (`shadow_denoise_spatial.hlsl`, `shadow mask spatial`) blurs each soft channel's average over a disk of 12 taps, as wide as half the widest penumbra within a few pixels, at most `MASK_MAX_BLUR` (24) pixels, into the mask. A lit ray says nothing of the penumbra, so the search takes the widest among the blocked rays, three pixels apart; a channel with none near is not blurred. A tap counts when it is on the pixel's plane, within a tenth of its distance from the pixel, and by its normal's agreement to the fourth power. The blue noise turns the disk, and temporal AA averages it.
- **The cost** was measured on an RTX 5090 at 1920x1080, High, in `soft_shadows.scene`, with the sun, the point, the quad and the spot light in the mask's four channels, three of them soft, as the median of five profile summaries: `shadow mask` 0.082 ms, against 0.079 ms with every channel hard; `shadow mask temporal` 0.021 ms; `shadow mask spatial` 0.058 ms.
- **The `Shadow_Mask` debug view** shows the denoised mask. Over 32 screenshots of a still view, 99% of its pixels varied by less than one 8-bit code.

#### The virtual shadow map

Shadow map ray tracing (SMRT) softens the [virtual shadow map](#virtual-shadow-maps)'s light when it has an angular diameter, from High up (`virtual_soft_shadow` in `material_lighting.hlsli`). Its rays march through the map's depth toward points of the light's disk, so a penumbra grows with the distance from its caster, with no blocker search.

- **The rays:** `Smrt_Params.rays` from each pixel, toward points of the light's disk on a Vogel disk that the blue noise turns, each with `Smrt_Params.steps` steps out to `Smrt_Params.length` (`SMRT_LENGTH`, 20 m). The steps are nearer together near the pixel, as the square of their share of the way, and the blue noise moves them for each pixel. The point moves as for the comparison taps.
- **The level:** a ray's steps read the level that the point's lookup found, through the page table, and a step on a page that is not allocated reads the next coarser level that has one. A step with no page in any level does not count.
- **Occlusion:** a step is blocked when it is behind the map's depth by more than a thickness of two of the level's texels and 2% of its distance from the pixel, against the texels' size and the surfaces' own slopes. Behind the map's depth counts as solid: that is how the map's depth is extrapolated behind a blocker, so a ray that passes behind a thin caster such as a pole or a fence's slat is blocked whatever its steps' spacing. A blocked ray stops.
- **Far casters:** a ray's last step is at its end, so a caster farther than the rays reach still casts, with the penumbra that one at their reach would cast: its edge is as wide as the light's size times 20 m, 9 cm for the sun.
- **Marking:** a pixel also marks the pages that its rays may read: as far around its block as a ray's end strays from the pixel, the light's size times the rays' length (`virtual_mark`'s reach). The marks for the fog and the sprites do not.
- **Who reads it:** the forward pass's opaque and masked surfaces, in the camera's views, as for the atlas's soft shadows. Everything else keeps the comparison taps. A light with an angular diameter of 0 keeps them too, so its shadows are as they were.
- **The levels** (`Smrt_Params` in `SHADOW_PARAMS`): Low and Medium keep the comparison taps; High has 4 rays of 6 steps, and Ultra 8 rays of 8 steps.
- **The cost** was measured on an RTX 5090 at 1920x1080, with tracing off, in a test scene of a sun of 2° over a tower, a pole, a fence and a table that fill the view, as the median of five profile summaries, against the same sun with an angular diameter of 0. The `world` pass took 0.29 ms against 0.08 ms at High, and 0.66 ms against 0.09 ms at Ultra: 0.21 ms and 0.57 ms for the rays. The marking took 0.003 ms more, and the allocation 0.014 ms more. Over 32 screenshots of a still view at High, 99% of the pixels varied by less than one 8-bit code.

#### The atlas

Percentage-closer soft shadows (PCSS; Fernando, 2005) soften the atlas's spot, point and area lights that have a size (`soft_shadow_map` in `material_lighting.hlsli`). A quad, a disk or a line is still one point light's cube from its middle, with its shape's size.

- **The view's depth** is reversed and perspective: a texel holds `SHADOW_NEAR` over its distance from the light. The ratio of two distances is the inverse ratio of their depths, so the near plane cancels out of every formula below. At the point's distance `z`, the light is `size / (z · texel)` texels across its radius, where `texel` is the view's texel 1 m away.
- **The point** moves toward the light and along its normal as for [the comparison taps](#shadows), and projects into its view.
- **The receiver plane:** two steps along the surface, projected, give the surface's slope in the map's depth per texel. Each tap compares against the plane's depth at its offset, not the point's, so a wide filter on a sloped surface does not shadow the surface itself. At a grazing angle the slope is held to that of a surface at 85° from the light.
- **The blocker search** gathers the map's depths, 2x2 texels at a time (`GatherRed`, with no comparison), at `Soft_Params.search` points of a Vogel disk. It reaches as far as a blocker at the near plane could stand from the point, `(z / SHADOW_NEAR − 1)` times the light's texels, and at most `Soft_Params.radius` texels. The texels nearer the light than the plane are blockers. With none, the point is lit and the filter does not run. With every texel a blocker, the filter still runs, since a shortcut to the umbra would flicker along its edge as the noise turns the search.
- **The penumbra** is the light's texels times `z / z_blocker − 1`, where `z_blocker` is the blockers' mean distance, from the mean of their inverse depths. It is held between 1 texel and `Soft_Params.radius`.
- **The filter** takes `Soft_Params.taps` bilinear comparisons on a Vogel disk as wide as the penumbra, and averages them.
- **Noise:** the frame's blue noise (`blue_noise.hlsli`) turns each pixel's disk. With temporal AA or an upscaler, each frame takes the noise's next slice, and the history averages the turns. Without either, the noise stays where it is. Before the noise is resident, every pixel's disk has the same turn.
- **The guard band:** a soft light's spot view or cube faces are wider than their own field of view, so that the field fills the slot but for `soft_guard` texels on each side: the filter's reach and 2 texels for a gather's and a comparison's 2x2 (`Soft_Params.radius + 2`). A point picks the face of its direction, so it projects inside the face's own field, and its taps reach into the guard band, which holds what lies past the edge. So the taps never read a neighbouring view, and a penumbra crosses a cube's edge with no seam. The band takes some of the slot's texels: 36 of 512 at High.
- **Who reads it:** the forward pass's opaque and masked surfaces, in the camera's views. The transparent surfaces, the sprites, the GPU particles, the fog, the global illumination's hits and the reflection probes' captures keep the comparison taps, because they have no stable pixel for the noise or no temporal AA history. They read the same widened views.
- **A light with no size** takes the comparison taps, and its views have no guard band, so its shadows are as they were.
- **The levels** (`Soft_Params` in `SHADOW_PARAMS`):

  | Level | Search gathers | Filter taps | Widest reach |
  |---|---|---|---|
  | Low | – | – | – (comparison taps) |
  | Medium | 4 (16 texels) | 8 | 16 texels |
  | High | 8 (32 texels) | 16 | 16 texels |
  | Ultra | 8 (32 texels) | 24 | 32 texels, in slots of 1024 |

- **The cost** was measured on an RTX 5090 at 1920x1080, with tracing off, in a scene of 12 point lights of a 10 cm radius among 36 posts, whose 10 nearest fill the atlas, as the median of five profile summaries of the `world` pass. Against the same lights with no size:

  | Level | `world`, soft | `world`, hard | Soft shadows |
  |---|---|---|---|
  | Low | 0.092 ms | 0.092 ms | None: 2 lights' maps fit, with comparison taps |
  | Medium | 0.192 ms | 0.130 ms | 0.06 ms |
  | High | 0.253 ms | 0.130 ms | 0.12 ms |
  | Ultra | 0.367 ms | 0.144 ms | 0.22 ms |

  The `shadow maps` pass takes the same 0.24 ms either way.
- **The sample:** `samples/mygame/content/scenes/soft_shadows.scene`, which F7 in mygame cycles to, has a spot light over a tall pillar, a point light low between a pole and a box, whose shadows cross its cube's faces, and a quad light over a box. From High up with `Ray_Query`, they and the sun take the mask's four channels (see [The traced mask](#the-traced-mask)); below High, or without `Ray_Query`, the atlas.

### Virtual shadow maps

A virtual shadow map gives a directional light a stack of clipmap levels around the camera (`lib/engine/render/virtual_shadows.odin`, `virtual_shadow.hlsli`). Each level is a virtual texture of 16384² texels, in 128 pages of 128² texels on a side (`VIRTUAL_PAGES`, `VIRTUAL_PAGE_TEXELS`). Only the pages that the frame reads have memory, from one pool of pages. Texel density follows each pixel's footprint out to the last level's reach, and memory follows the screen, not the reach.

- **Where it applies:** it takes the directional light wherever the cascades would: a light without a mask channel, with `shadows.virtual` in the [quality](quality.md#quality). So on a device with `Ray_Query`, it takes the light at Medium, or with `shadows.ray_traced` off. Low has none, and draws cascades. So does a frame whose compute pipelines have not compiled yet. Spot and point lights keep the atlas.
- **Levels:** the first level is `VIRTUAL_FIRST_EXTENT` (16 m) across, with texels of about a millimeter, and each level is twice the extent of the one before. The quality's level sets the count (`Shadow_Params.virtual_levels`). A level's half extent is about 8.8 times the distance whose footprint matches its texel at 1080p, and past the last level's match, a pixel takes more of its texels than it can show, and more of its pages, with nothing coarser to fall back to. So the count is set by the match, which is 4 km at Medium, 2 km at High and 4 km at Ultra, and the last level reaches 16 km, 16 km and 32 km. Each level's origin snaps to whole pages of the world's space, from the camera's `World_Position`, so a page stays at the same texels as the camera moves and turns, and a rebase of the render origin moves no page. Each level's grid is on every second line of the one before's, so a page has one parent in the next level. Each level's depth is centered on an anchor along the light, with a range of twice the level's extent on each side, and the anchor stays while the camera is within the level's extent of it (`virtual_depth_anchor`), so the range always holds the level's extent around the camera.
- **Which level:** a point picks the level whose texel is nearest its footprint: its distance from the camera times the angle that a pixel takes up, with the level's bias (`Shadow_Params.virtual_bias`, in levels). Only the distance counts, so the marking, the lights and the compute passes, which have no derivatives, all agree, and turning the camera changes no point's level. At 1080p with a 60° view, a point 1 m away has texels of about a millimeter, against 1.7 cm in High's first cascade. It is a level nearest the footprint and not the first finer than it, so a texel is from 0.7 to 1.4 times the footprint.
- **The valid rectangle:** a level's depth pass rasterizes only the part of the level that the view's frustum covers out to the level's reach, in whole pages, with room around the camera for the [view model](layers-and-output.md#view-model), which `Shadow_View.rect` holds. It is the pass's scissor and the level's culling bounds. Without it, a flat ground that covers a level runs the pixel shader 268 million times, for texels that mostly have no page. With it, a level's fragments follow the screen. The marking and the lookups treat a point outside the rectangle as outside the level, so a mark never lands on a page that does not draw.
- **Marking:** after the prepass, a compute pass (`virtual_shadow_mark.hlsl`) rebuilds each pixel's position from its depth, as the shadow mask does, picks its level, and sets the bits of the pages that its filter's texels read, with a texel's margin for the lookup's offsets. Each level has a request bitmask. In a frame with fog, transparent surfaces or sprites, which have no prepass, a second dispatch marks through the view's frustum to `VIRTUAL_VOLUME_REACH` (100 m), the cascades' reach, from a grid of 64x40x32 points, at levels 3 coarser than their footprints (`VIRTUAL_VOLUME_LEVELS`), which gives them coarse shadows; past it, the fog and the sprites are lit, as they are past the cascades. Every caster over those pages draws, so a frame without them marks none. With [soft shadows](#the-virtual-shadow-map), a pixel also marks the pages around its block that its rays may read.
- **Allocation:** compute passes (`virtual_shadow_allocate.hlsl`, a dispatch each) give the marked pages physical pages, and write the page table: a virtual page's physical page, or `VIRTUAL_NO_PAGE`. Marks that fit the pool stay where they are, so no level draws pages that nothing reads. Marks that do not fit move to their pages' parents, finest level first and a page at a time, until they fit, so a pool that is a little short loses a little detail. The stats count the pages that moved as misses. Then the pool's pages that the frame keeps take their entries, and the new pages take free pages, coarsest level first (see [Caching](#caching)). The coarsest level has nothing to fall back to, so a pool that cannot hold that level's own pages leaves the rest of its pixels lit. Its pages are wide, so they follow the view's area and not the screen's pixels: an aerial view of Jungle Ruins several kilometers deep takes about 230 of them. The levels' pools are 1024 pages or more. A last dispatch clears the pages that draw, from their list.
- **The pool:** one `R32_Uint` texture, sized by the level (`Shadow_Params.pool_pages`; see [Quality: Levels](quality.md#levels)). It is not a graph transient, because every view's `Frame_Constants` holds its indices, which are written before transients have any. It is made again when the quality's size changes, with the records of its pages.
- **Drawing:** each level is a culling view against its valid rectangle, with no plane toward the light, as a cascade is. The depth pass is a render pass with no attachments (see [GPU: Pass rules](../gpu/command-buffers.md#pass-rules)), a piece for each level, whose viewport is the level's 16384² and whose scissor is its valid rectangle. The levels' views cull after the page table is written, in dispatches of their own, so only a cell, an instance or an item that reaches a page that the frame draws, whose entry has `VIRTUAL_DRAW`, draws (`virtual_view_reaches_draws`), and each meshlet's amplification shader tests the same (`virtual_sphere_draws`). A sphere too big to test page by page draws if its level draws any page. A level's cost so follows its new pages, not what is over its valid rectangle. Every material has a `Virtual_Depth` pixel stage, and those of the mesh's and the impostor's paths draw with the depth passes' other stages. The stage translates its texel through the page table, and leaves if the frame does not draw the page or a nearer depth is there already, so most fragments never run the material: a masked material's opacity runs only for a 2x2 quad with a fragment that may write, and then discards as it does for the atlas. The others write their depth with `InterlockedMax`. Depth is reversed, so the nearest to the light is the largest, and a float's bits that are not negative order as the float does. A page that draws clears to 0 first. A pipeline's bias and clamp have no depth attachment to act on, so the stage applies `SHADOW_DEPTH_BIAS` and `SHADOW_SLOPE_BIAS` itself, and clamps, so casters between the light and the view still cast.
- **Sampling:** the lights take a page that the pool holds whether or not this frame drew it, and the same offsets as the atlas's lookup, by the level's texel, and read the texels that `Frame_Constants.shadow_filter` gives: 2x2, 3x3 or 4x4 `Load`s, with the weights of 1, 4 or 9 bilinear comparisons. A lookup starts one level finer than the point's footprint, where the marking may have placed a point at a level's edge, whose distance it rebuilt from depth. A level without the page that holds the point leaves the point to the next coarser level, so a pool that runs out costs detail and not shadows. All of a lookup's texels are of one level. A mark that moved is only its page's parent, so a block across a coarser level's page line may reach a page that does not exist, and those texels read the point's own page at its edge. A point with no page in any level, or outside every level, is lit. The fog and the sprites read the map the same way.
- **The cost:** on an RTX 5090 at 1087x481, High quality, Sponza's depth pass takes 0.3 ms, against 0.1 ms for the cascades. Jungle Ruins' takes 3 ms from a view close over its plants, against 6 ms, because its pages are few and fine. It takes 18 ms at the scene's view, against 5 ms, because the cascades stop at 100 m and the levels draw to the horizon. From 400 m up, it takes 26 ms, against 0.02 ms for cascades that have nothing to shadow within their reach. Their pages are 50 to 230 of the pool's 2048.
- **Debug and stats:** the `Shadow_Virtual` [debug view](post-processing.md#debug-views) shows each pixel's level, half red where it fell back to a coarser level, and magenta where it found no page. The Resource Monitor shows the pages requested, allocated and missed, the pages that the pool held, that drew and that left the pool, and the pool's fill (see [Editor](../editor/shell-and-panels.md#resource-monitor)).
- **A note on the tests:** the null backend runs no shaders, so `virtual_shadows.odin` keeps the marking, the allocation's phases and the lookup as procedures that match the shaders, which the tests on it call.

#### Caching

With `shadows.virtual_cache` in the [quality](quality.md#quality), the page table and the pool last from frame to frame, in the view's `Virtual_State`. A page that the pool holds keeps its physical page and does not draw again, so a still light over a still scene draws only the pages that the camera uncovers. No preset has it, because a caster that moves leaves its old shadow in the pages that the pool keeps.

- **What a page holds:** each physical page has a record, which lasts with the pool: its level, the absolute page that it holds, and the last frame that asked for it (`Virtual_Page`). A level's table is toroidal: an absolute page's entry is at the page modulo 128 on each axis (`virtual_table_slot`). So when a level's origin moves by whole pages, the pages that stay in the level keep their entries and their contents, and nothing is copied.
- **The allocation's phases:** `fit` makes the marks fit the pool. `retire` goes over the pool's pages, a thread each. A page leaves if its level's origin moved past it, if its level is dropped or past the quality's levels, and otherwise takes its entry again. A page that the frame marked is a hit: its mark is cleared and its age starts over. Every other page's age goes into a histogram of 1024 bins, in frames since a frame asked for it. `select`, one thread, counts how many pages the new marks need beyond the free pages, and walks the histogram from the oldest bin, summing, to the bin where enough pages are older. `collect` lists the free pages and the pages that leave: every page older than that bin, and as many of the bin's as are still needed. `assign` gives each new mark the next page of the list, coarsest level first, sets `VIRTUAL_DRAW` on its entry, and counts each level's new pages after the table. Nothing is read back.
- **Eviction:** when the pool is full, the pages that were asked for longest ago leave first, and a page that the frame asks for never leaves. The marks fit the pool, so every mark gets a page, and the view shows no holes. Pages older than the histogram's last bin count as equally old.
- **What drops pages:** the frame plans what it keeps in one place (`virtual_cache_plan`). It starts again, with every entry and record cleared, without a cache, with the cache off, and when the light's direction, the shadows' `Shadow_Params` or their settings changed. A sun that turns every frame so draws every page each frame, as without the cache. A level drops its own pages when its depth anchor moves, after the camera moves its extent along the light: 16 m at level 0. The plan is kept in `Virtual_State.cache` only once the frame has executed (`commit_virtual_cache`), so a frame that fails keeps what the GPU last drew, and a frame that executes without the virtual shadow map forgets it. A new pool and a soft restart, which makes a new `View_State`, start with none. A rebase keeps everything: the grids and the anchors are of the world's space, not the render origin's.
- **Limits:** casters that move, appear or leave are not tracked yet. A cached page keeps the shadow that was drawn into it, and a mesh's finer meshlets that stream in later do not draw into it, until the page leaves the pool or the cache starts again. [Cached shadow maps](https://github.com/aszecsei/cinnabar/issues/141) for the atlas's lights will share the tracking of moving casters with this cache.
- **The cost:** on an RTX 5090 at 1920x1080, High quality without traced shadows, Jungle Ruins' depth pass takes 24.2 ms over its plants with the cache off, and 0.04 ms with it on and the camera still, where every page that the frame asks for is in the pool; the GPU frame goes from 83 ms to 55 ms. The playground's takes 0.053 ms and 0.030 ms. The allocation's phases take about 0.2 ms either way, most of it `assign`'s one thread over the request words, and the pool clear falls from 0.044 ms to 0.002 ms with no page to clear. A camera that moves draws the pages that it uncovers in the frames that it moves.
- **With the cache off,** every frame starts again, which is the same work as before the cache: the table and the records are cleared, every mark draws, and its pages clear.

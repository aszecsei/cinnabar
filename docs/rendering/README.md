# Rendering

The built-in renderer in `lib/engine/render`: the frame, the GPU scene, layers, lighting, materials, the screen-space effects and post-processing.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [Frame](frame.md) | The passes, the `Renderer`, hooks, settings and views. |
| [GPU scene](gpu-scene.md) | Instance records, the render origin, slots, culling and the acceleration structure. |
| [Layers and output](layers-and-output.md) | The world, view model, UI and debug layers, the output pass and HDR output. |
| [Lighting and shadows](lighting-and-shadows.md) | Clustered forward, the prepass, lights, area lights and shadows. |
| [Transparency](transparency.md) | Moment-based and sorted transparency. |
| [Materials](materials.md) | Shading models, materials, permutations, instances, the runtime and previews. |
| [Ambient occlusion](ambient-occlusion.md) | GTAO as XeGTAO builds it. |
| [Global illumination](global-illumination.md) | Screen-space radiance cascades. |
| [Volumetric fog](fog.md) | The froxel volume. |
| [Post-processing](post-processing.md) | Temporal AA, exposure, bloom, tone mapping, debug views and post effects. |
| [Assets and components](assets.md) | GPU residency, asset fields and the renderer's components. |

## Overview

`lib/engine/render` is game-side code. It holds the render graph (which [GPU](../gpu/render-graph.md#render-graph) describes, because it is the engine's layer over the backend) and the renderer built on it. Everything persistent is handles in a `render.Renderer` in `Game_State`; everything per frame is in frame memory.

| File in `lib/engine/render` | What it holds |
|---|---|
| `graph.odin` | `Graph`: passes, uses, transient and imported resources, barriers, culling and execution ([GPU](../gpu/render-graph.md#render-graph)) |
| `cache.odin` | `Texture_Cache`: transient textures and history pairs kept between frames |
| `extract.odin` | Extractors and `extract`, the ECS-to-GPU step ([World](../world/render-extraction.md#render-extraction)) |
| `view.odin` | `View`: a camera's pose, projection and viewport; `view_projection`, `view_depth`, `camera_view` ([Views](frame.md#views)) |
| `renderer.odin` | `Renderer`, `Frame_Desc`, `Frame`, the hooks, the frame's targets and `draw_frame` ([Frame](frame.md#frame)) |
| `settings.odin` | The settings components on volumes and `resolve_settings` ([Settings](frame.md#settings)) |
| `scene.odin` | `Gpu_Scene`: every instance's record at a stable slot, the render origin, culling into bins ([GPU scene](gpu-scene.md#gpu-scene)) |
| `components.odin` | The render components' stable IDs: `Camera`, `Mesh_Renderer`, the lights, `View_Model` ([Components](assets.md#components)) |
| `materials.odin` | `Material_Table`, pipelines by material, bins, the default material ([Runtime](materials.md#runtime)) |
| `shaders.odin` | `Shader_Pipeline` and the `sync_*_pipeline` procedures that compile from shader assets ([GPU residency](assets.md#gpu-residency)) |
| `residency.odin` | `Residency`: the GPU resources of texture and mesh assets ([GPU residency](assets.md#gpu-residency)) |
| `lights.odin` | Light extraction, the cluster pass, the area lights' tables ([Lights and clusters](lighting-and-shadows.md#lights-and-clusters)) |
| `shadows.odin` | Shadow assignment, the atlas, cascades, the ray-traced mask ([Shadows](lighting-and-shadows.md#shadows)) |
| `transparency.odin` | Moment-based and sorted transparency ([Transparency](transparency.md#transparency)) |
| `ambient_occlusion.odin` | GTAO on the compute queue ([Ambient occlusion](ambient-occlusion.md#ambient-occlusion)) |
| `gi.odin` | Screen-space radiance cascades ([Global illumination](global-illumination.md#global-illumination)) |
| `fog.odin` | The froxel fog volume ([Volumetric fog](fog.md#volumetric-fog)) |
| `post.odin` | Temporal AA, exposure, bloom, the tone mapping lookup table ([Post-processing](post-processing.md#post-processing)) |
| `post_effects.odin` | A game's own post passes at fixed points ([Post effects](post-processing.md#post-effects)) |
| `debug_views.odin` | The editor's debug views and feature toggles ([Debug views](post-processing.md#debug-views)) |
| `preview.odin` | Material previews into their own shared targets ([Material previews](materials.md#material-previews)) |

The shaders are engine content in `lib/engine/content/shaders`: one `.hlsl` asset per pass (`cull_draws`, `cluster_lights`, `shadow_mask`, `gtao*`, `gi_*`, `fog_*`, `temporal_aa`, `exposure_*`, `bloom`, `tone_lut`, `output`, `debug_view`, `debug`, and the editor's `overlay`, `pick` and `icons`), and the material templates as `.hlsli` includes (`material_passes.hlsli` and the files it includes). Shading models are in `lib/engine/content/shading`.

**How a frame is built.** The game calls `render.draw_frame(&renderer, &world, frame_desc)` once a frame. `draw_frame` resolves the settings at the camera, extracts the lights and the GPU scene's instances, builds a `render.Graph` in frame memory with every pass that the settings and the frame need, calls the game's hooks at their points, and executes the graph, which records the barriers and submits ([Frame](frame.md#frame)). The main types:

| Type | Where it lives | What it is |
|---|---|---|
| `Renderer` | `Game_State` | Handles only: the residency table, the texture cache, the debug lines, the extractors, the materials, the GPU scene, the lights' clusters, the shadows' acceleration structure, the volumes' query, and each feature's pipelines |
| `Frame_Desc` | Frame memory | What the game asks for this frame: the view, the size, the editor's flags, the settings or nil, the hooks, the previews |
| `Frame` | Frame memory | What the hooks see: the graph, the view and its projections, the targets, the exposure, the jitter, the hooks' `data` |
| `View` | Either | A camera: pose, projection, viewport, and the view model's projection |
| `Gpu_Scene` | `Renderer` | The persistent instance buffer, its slots, the render origin, the draw items and bins |
| `Material_Table` | `Renderer` | The loaded materials and instances, their pipelines, and the frame's parameter blocks |
| `Residency` | `Renderer` | The resident textures and meshes by GUID, and their streaming state |
| `Texture_Cache` | `Renderer` | Transient textures and history pairs, keyed by description and label |

## Goals

- **Layers:** the world, the view model, the UI and debug drawing each have their own target and their own rules, and one output pass combines them.
- **Shading models:** a new lighting model is one HLSL file and one declaration. Materials pick a shading model, and every pass that draws them works without changes.
- **Materials from graphs:** a node graph in the editor makes a material. A material instance changes its parameters and needs no new shaders.
- **Room to grow:** volumetric fog, global illumination, bloom, exposure, tone mapping, ambient occlusion and ray-traced shadows each have a fixed place in the frame and the inputs they need.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Shading path | Clustered forward, with a depth and normal prepass | See [Clustered forward](lighting-and-shadows.md#clustered-forward). |
| Depth | Reversed infinite Z: depth is `near / z`, test `Greater`, clear 0 | `D32_Float` has its precision near 0. Reversing puts that precision in the distance instead of at the near plane, where nothing needs it. See Reed in [References](#references). |
| Scene color | `RGBA16_Float`, linear, pre-exposed | Bloom, exposure and tone mapping need HDR. Pre-exposure keeps bright values inside the half-float range. |
| View model | A second view drawn into the scene's targets, not a separate target | See [View model](layers-and-output.md#view-model). |
| UI and debug | Separate targets, combined after tone mapping | Tone mapping and exposure do not change them, and the scene can render at a lower resolution than they do. |
| HDR output | HDR10 by default on a display in HDR, scRGB on request; the tone mapper's SDR result, opened up above a knee to the display's peak | The tone mappers keep their look, and SDR's white, which the UI has, is as bright as Windows shows SDR content. See [HDR output](layers-and-output.md#hdr-output). |
| Instance positions | Relative to a render origin that snaps to a 1024 m grid, in a persistent GPU scene | See [GPU scene](gpu-scene.md#gpu-scene). |
| Anti-aliasing | Temporal, no MSAA | Fog, GI and ambient occlusion all need temporal accumulation, so the frame has the history and velocities anyway. |

## Open questions

- **A visibility buffer.** The GPU-driven mesh shader path could write triangle IDs and shade in compute, bin by material, which removes the forward pass's quad overdraw on small triangles. `Material_Inputs` and `cn_sample` keep that path open. Decide after phase 5, with measurements. Reference: Burns and Hunt 2013.

## Future work

- **Thumbnails** for materials, meshes and textures from the preview view, rendered at a fixed size and read back, as a cook output ([Content pipeline](../history.md#content-pipeline), phase 4).

## References

Each entry names the section that follows it.

- Intel, [XeGTAO](https://github.com/GameTechDev/XeGTAO): the reference implementation that [Ambient occlusion](ambient-occlusion.md#ambient-occlusion) follows for its depth levels, slice search, Hilbert-curve noise and edge-aware denoiser.
- Jorge Jimenez, Xian-Chun Wu, Angelo Pesce, Adrian Jarabo, [*Practical Real-Time Strategies for Accurate Indirect Occlusion*](https://www.activision.com/cdn/research/Practical_Real_Time_Strategies_for_Accurate_Indirect_Occlusion_NEW%20VERSION_COLOR.pdf), SIGGRAPH 2016: GTAO, and the specular occlusion and bent normals in Future work.
- Alexander Sannikov, [*Radiance Cascades: A Novel High-Resolution Formal Solution for Multiresolution Global Illumination*](https://github.com/Raikiri/RadianceCascadesPaper): the cascades, intervals and merge of [Global illumination](global-illumination.md#global-illumination), in their screen-space form.
- Cedrick Münstermann, Stefan Krumpen, Reinhard Klein, Christoph Peters, [*Moment-Based Order-Independent Transparency*](https://momentsingraphics.de/I3D2018.html), I3D 2018: the four power moments of [Transparency](transparency.md#transparency).
- Morgan McGuire, Louis Bavoil, [*Weighted Blended Order-Independent Transparency*](https://jcgt.org/published/0002/02/09/), JCGT 2013: the particle path in Future work.
- Eric Heitz, Jonathan Dupuy, Stephen Hill, David Neubelt, [*Real-Time Polygonal-Light Shading with Linearly Transformed Cosines*](https://eheitzresearch.wordpress.com/415-2/), SIGGRAPH 2016, and Eric Heitz, Stephen Hill, [*Real-Time Line- and Disk-Light Shading with Linearly Transformed Cosines*](https://blog.selfshadow.com/publications/s2017-shading-course/), SIGGRAPH 2017 course: [Area lights](lighting-and-shadows.md#area-lights), including the horizon-clipped sphere table.
- Ola Olsson, Markus Billeter, Ulf Assarsson, [*Clustered Deferred and Forward Shading*](https://efficientshading.com/2012/01/01/clustered-deferred-and-forward-shading/), HPG 2012: [Lights and clusters](lighting-and-shadows.md#lights-and-clusters).
- Nathan Reed, [*Depth Precision Visualized*](https://developer.nvidia.com/content/depth-precision-visualized), 2015: the reversed infinite Z in [Decisions](#decisions).
- Brian Karis, [*Real Shading in Unreal Engine 4*](https://cdn2.unrealengine.com/Resources/files/2013SiggraphPresentationsNotes-26915738.pdf), SIGGRAPH 2013: the `Lit` shading model's GGX, Smith visibility, Schlick Fresnel and the environment BRDF fit in [Shading models](materials.md#shading-models).
- Brian Karis, [*High Quality Temporal Supersampling*](https://de45xmedrsdbp.cloudfront.net/Resources/files/TemporalAA_small-59732822.pdf), SIGGRAPH 2014, and Lasse Jon Fuglsang Pedersen, [*Temporal Reprojection Anti-Aliasing in INSIDE*](https://www.gdcvault.com/play/1022970/Temporal-Reprojection-Anti-Aliasing-in), GDC 2016: the velocity dilation, YCoCg clipping and reversible tone map of [Post-processing](post-processing.md#post-processing)'s temporal AA.
- Jorge Jimenez, [*Next Generation Post Processing in Call of Duty: Advanced Warfare*](https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/), SIGGRAPH 2014: the 13-tap downsample with luminance weighting, the tent upsample and the Halton jitter in [Post-processing](post-processing.md#post-processing).
- Troy Sobotka, [AgX](https://github.com/sobotka/AgX); Khronos, [PBR Neutral tone mapper](https://github.com/KhronosGroup/ToneMapping); Academy, [ACES](https://github.com/ampas/aces-dev): the tone mappers in the lookup table of [Post-processing](post-processing.md#post-processing).
- Bart Wronski, [*Volumetric Fog: Unified compute shader based solution to atmospheric scattering*](https://bartwronski.com/publications/), SIGGRAPH 2014, and Sébastien Hillaire, [*Physically Based and Unified Volumetric Rendering in Frostbite*](https://www.ea.com/frostbite/news/physically-based-unified-volumetric-rendering-in-frostbite), SIGGRAPH 2015: the froxel volume, injection, temporal blend and integration of [Volumetric fog](fog.md#volumetric-fog). The phase function is Henyey and Greenstein, 1941.
- Martin Roberts, [*The Unreasonable Effectiveness of Quasirandom Sequences*](https://extremelearning.com.au/unreasonable-effectiveness-of-quasirandom-sequences/), 2018: the R2 sequence of [Ambient occlusion](ambient-occlusion.md#ambient-occlusion)'s noise. The jitter is the Halton (2, 3) sequence.
- Zina Cigolle, Sam Donow, Daniel Evangelakos, Michael Mara, Morgan McGuire, Quirin Meyer, [*A Survey of Efficient Representations for Independent Unit Vectors*](https://jcgt.org/published/0003/02/01/), JCGT 2014: the octahedral normals of the [Prepass](lighting-and-shadows.md#prepass) and the GI's direction folding.
- Microsoft, [*Common Techniques to Improve Shadow Depth Maps*](https://learn.microsoft.com/en-us/windows/win32/dxtecharts/common-techniques-to-improve-shadow-depth-maps) and [*Cascaded Shadow Maps*](https://learn.microsoft.com/en-us/windows/win32/dxtecharts/cascaded-shadow-maps): the cascades, texel snapping, bias and sampling of [Shadows](lighting-and-shadows.md#shadows).
- Ulrich Haar, Sebastian Aaltonen, [*GPU-Driven Rendering Pipelines*](https://advances.realtimerendering.com/s2015/), SIGGRAPH 2015: the GPU scene, bins as indirect draws, and the two-phase occlusion culling in Future work.
- Christopher Burns, Warren Hunt, [*The Visibility Buffer: A Cache-Friendly Approach to Deferred Shading*](https://jcgt.org/published/0002/02/04/), JCGT 2013: [Open questions](#open-questions).
- Khronos, [glTF Sample Assets](https://github.com/KhronosGroup/glTF-Sample-Assets): the DamagedHelmet that [Content pipeline](../content/kinds/meshes.md#meshes) measures, and the preview meshes' format.
- Sébastien Lagarde, Charles de Rousiers, [*Moving Frostbite to Physically Based Rendering*](https://seblagarde.wordpress.com/2015/07/14/siggraph-2014-moving-frostbite-to-physically-based-rendering/), SIGGRAPH 2014: the windowed inverse-square falloff of [Lights and clusters](lighting-and-shadows.md#lights-and-clusters), pre-exposure, and the histogram exposure with EV100 of [Post-processing](post-processing.md#post-processing).
- Microsoft, [*Using DirectX with high dynamic range displays and advanced color*](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range): HDR10, scRGB, PQ and the SDR white level in [HDR output](layers-and-output.md#hdr-output).

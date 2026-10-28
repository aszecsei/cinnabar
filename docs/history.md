# History

The implementation phases of each part, in the order they were built. A phase marked done is in the code; the rest is in each layer's Future work sections. This is history, kept so that the phase numbers that older notes mention still mean something.

## GPU
All phases are done. They are kept as the order in which the interface grew, which is also a sensible order for a new backend to pass the tests in.

| Phase | Result |
|---|---|
| 0 | `gpu` types and packet format. Null backend with tests. D3D12 device, debug layer, swapchain, clear and present with vsync. |
| 1 | Buffers, textures, samplers, upload ring, bindless heaps, fixed root signature, pipelines, deferred destruction. A vertex-pulled triangle. |
| 2 | Render graph with Enhanced Barriers. A multi-pass sample. |
| 3 | Parallel recording and translation. Pipeline compilation on jobs. Lifetime scopes and soft-restart cleanup. |
| 4 | Indirect commands with draw ID and count buffers. Async compute queue. GPU culling sample. |
| 5 | Mesh shaders, with the vertex fallback. |
| 6 | Acceleration structures and inline ray tracing. Then ray tracing pipelines. |
| 7 | Editor shared texture. Async copy queue for asset streaming. Cooker-built shaders and pipelines (cooked pipelines wait for the asset runtime). |

## Rendering
The order in which the renderer was built. Every phase is done; what remains is in [Future work](rendering/README.md#future-work).

| Phase | Result |
|---|---|
| 0 | *Done.* In order: reversed Z. Shader assets, and the sample's and the editor tools' shaders moved to them. The BC formats in `lib/core/gpu`, and texture assets. Mesh assets. Asset fields. The residency table, `Camera` and `Mesh_Renderer`, and the sample drawing a glTF mesh. |
| 1 | *Done.* The frame skeleton: one view, the world layer, a fixed tone mapper, the UI and debug targets, the output pass. The `debug` API, and the editor's overlay moved into the debug layer. |
| 2 | *Done.* The GPU scene with the render origin and stable slots, written in full every frame. Shading models and materials written in HLSL: `Unlit` and `Lit`, material and instance assets, the material table, pipelines by material and culling into bins. The sample draws with them. |
| 3 | *Done.* Clustered forward: the prepass with normals and velocities, the forward pass with `Equal` depth, the light components, clusters, shadow maps in an atlas with cascades, and ray-traced shadow masks with the GPU scene's acceleration structures. The sample's scene has a sun, a point light and a spot light. Also in `lib/core/gpu`: depth bias and clamping, and comparison samplers (see [GPU](gpu/resources-and-pipelines.md#pipelines)). |
| 4 | *Done.* The view model, with the stencil additions: the `View_Model` tag, its projection from the `Camera`, its stencil bit in the prepass and the forward pass, and positions rebuilt with its projection for its pixels. The sample's camera holds a rod that reaches through the triangles. In `lib/core/gpu`: stencil state in `Graphics_Pipeline_Desc`, the reference value in a command, the stencil's load and clear with the depth attachment, and a view of the stencil for shaders. |
| 5 | *Done.* The material graph: the `.material` graph format and material functions, the cooker's code generation with each permutation's switches decided and hash-named sources that compile once, the editor's node editor, and material previews in their own shared targets with `Cook_Preview`. The sample's checker material is a graph. In `lib/core/gpu`: preview targets beside the frame target (`gpu_preview_target`), and whether a pipeline is compiled (`gpu_pipeline_ready`) (see [GPU](gpu/presentation.md#presentation)). |
| 6 | *Done.* Post-processing: history textures in the render graph (`history_texture`, see [GPU](gpu/render-graph.md#render-graph)), temporal AA with the camera's jitter, the exposure from a luminance histogram, which pre-exposes the scene, bloom, and the tone mapping lookup table with AgX, Khronos PBR Neutral and ACES, and color grading. The `before_post` hook. |
| 7 | *Done.* GTAO with a temporal denoiser on the compute queue, later rebuilt on XeGTAO's depth levels and edge-aware denoiser with no history. Volumetric fog: the fog's component, a froxel volume with the clusters' slices, injection with traced or mapped shadows, integration, and the background's fog. In `lib/core/gpu`: 3D textures (`Texture_Desc.depth`, see [GPU](gpu/resources-and-pipelines.md#resources)), and the layout change for a compute-queue pass, which the texture's last pass on the graphics queue makes (see [GPU](gpu/render-graph.md#render-graph)). The sample's scene had low fog. |
| 8 | *Done.* Global illumination with screen-space radiance cascades on the compute queue: five cascades traced through the depth buffer into last frame's lit scene, merged with the ambient sky beyond, gathered into diffuse and specular histories that the forward pass reads in place of the ambient light. |
| 9 | *Done.* HDR output: HDR10 and scRGB frame targets from `core`, chosen by the display's HDR state (`gpu_output`, `gpu_request_output`, see [GPU](gpu/presentation.md#presentation)); paper white from Windows' SDR white; a lookup table that opens the tone mapper's SDR colors up to the display's peak; and the output pass, which blends the UI at paper white and encodes for the display. |
| 10 | *Done.* Settings on volumes: the settings components, `resolve_settings` at the camera, and `Fog` with a base height in the world. The sample's scene has a Global Volume. |
| 11 | *Done.* Post effects: `register_post_effect` with three points among the post passes, settings on volumes, and the bloom composite before tone mapping. The sample's lens is one. |
| 12 | *Done.* Debug views: the forward template's views of the albedo, the lighting, the light complexity and the cascades, the views from the frame's textures, the raw output, and the features that the editor turns off. |
| 13 | *Done.* The cascades' reach and split as `Shadows` settings on volumes. *The depth bias stays a constant: it is in the shadow pipelines' descriptions.* |
| 14 | *Done.* Transparency: the `Transparent` and `Additive` blends, moment-based order-independent transparency with four power moments, sorted draws as bins of their own, the editor's transparent IDs and the overdraw view. The sample's glass scene, which F7 switches to. |
| 15 | *Done.* Quality (see [Rendering](rendering/quality.md#quality)): `Quality` apart from the volumes' look, with each feature's level, `apply_quality` between the volumes and the editor's flags, and tables of levels in place of the shadows', GTAO's, GI's and fog's constants. Traced shadows as a choice, with the acceleration structures made the first frame that traces. Hardware caps and defaults by video memory, and the quality's keys in the project settings, which the game saves. In `lib/core`: `gpu_adapter` and `file_write` (see [GPU](gpu/interface.md#adapter)). The sample's F9 and Shift+F9. |
| 16 | *Done.* HBAO and SSAO as the quality's `Ao_Technique`s beside GTAO, each a search over the same depth levels, noise and edges, before the same denoiser, with what they share in `ao_common.hlsli` and a table of levels for each (`AO_PARAMS`). The sample's Ctrl+F9. |
| 17 | *Done.* FXAA and SMAA 1x as the quality's `Aa_Technique`s beside temporal AA (see [Rendering](rendering/anti-aliasing.md#anti-aliasing)). The output pass's tone mapping in `output.hlsli`, which the tone map pass runs on its own before them, so the output pass only blends the UI over their result. FXAA is the engine's own after FXAA 3.11; SMAA is the reference implementation, in `vendor/smaa` with its tables. The sample's Alt+F9. |
| 18 | *Done.* The render scale (see [Rendering](rendering/anti-aliasing.md#upscaling)): `Quality.render_scale`, the scene's targets and every pass before temporal AA at `Frame.size`, the UI at `Frame.output_size`, and `Frame.scene_size` for the passes after temporal AA. Temporal AA upscales into a history at the frame's size, from the jittered samples around each pixel, with a longer jitter sequence; without it, the output pass stretches the scene. The debug layer at the scene's size, and the editor's picks scaled to it. The sample's Ctrl+Shift+F9. |
| 19 | *Done.* FSR as the quality's `Aa_Technique` in temporal AA's place (see [Rendering](rendering/anti-aliasing.md#fsr)), with a motion pass that gives the camera's motion where the prepass drew nothing; temporal AA stands in where the device does not run it. In `lib/core/gpu`: upscalers as a resource type, `cmd_upscale`, and `gpu_upscalers`, with FSR in the D3D12 backend through the FidelityFX API of the AMD FSR SDK, whose libraries `just install` downloads (see [GPU](gpu/upscalers.md#upscalers)). |
| 20 | *Done.* The quality outside the engine's code: the `Render` script bindings in `lib/engine/project` (see [Scripting](scripting/api.md#render)), with which the sample's quality keys moved to Luau, F6 taking anti-aliasing from Alt+F9; the viewport's quality, anti-aliasing and render scale in `Viewport_Settings` (see [Editor](editor/viewport.md#quality)); and the quality presets in the Game Window group. |
| 21 | *Done.* The mesh shader path (see [Rendering](rendering/gpu-scene.md#mesh-shader-path)): the cooker's meshlets as a hierarchy of levels of detail, built with meshoptimizer's `clusterlod.h` (see [Content pipeline](content/kinds/meshes.md#meshlets)), resident in three more buffers; the opaque passes' amplification shaders, which pick each meshlet's level by `Quality.lod_error` and cull it by its sphere and its normal cone, and mesh shaders that place vertices as vertex pulling does; the `Meshlets` and `Lod_Depth` debug views. |
| 22 | *Done.* Materials: the Emission node and the convention of emission as radiance at a brightness in stops, the `Emission` debug view, and parallax occlusion mapping as a node over `cn_parallax` (see [Rendering](rendering/materials.md#parallax-occlusion-mapping)), with the sample's bricks on the short box and `just sample-textures`, which writes the sample's generated textures. |
| 23 | *Done.* Vertex displacement (see [Rendering](rendering/materials.md#vertex-displacement)): a material's `displace` in HLSL or a graph's Vertex Offset node, generated for the vertex stage with the material's functions written again for it, applied at both poses with `Frame_Constants.previous_time` for the velocities, and `displacement_bound`, which culling adds to the items' and the meshlets' spheres. |
| 24 | *Done.* Patch surfaces (see [Rendering](rendering/surfaces.md#surfaces)): `Surface_Renderer`, a quadtree of grid patches that `select_patches.hlsl` picks by their distance from the camera after Strugar's continuous LOD and `cull_patches.hlsl` writes into the item's reserved bin, the patch vertex path of `geometry = patches` materials with the morph that joins the levels and holes from a mask texture cooked with `filter = box`, previews of such materials as one patch, and the sample's lake with an island, which F7 cycles to. |

## Scripting
Phases 1 to 7 are done. Phase 8 is in [Future work](scripting/README.md#future-work).

1. **VM:** build Luau with the justfile, `lib/core/luau`, `script_open` with the host allocator and trampolines, and the binding registry. A test script survives a code reload with a suspended coroutine.
2. **Script assets:** GUIDs and `.meta` files, the `Loose_Cache` source, `cook scripts`, and `require`. The host polls the cache until the cook daemon exists.
3. **World view:** `Entity`, component references, `vector`, `Quaternion`, `WorldPosition`, `Time`, `Input`, `Debug`, and platform input in `core`.
4. **Behaviours:** the `Behaviours` component, the lifecycle, enabled state with `Disabled` and `Inactive`, events, the scheduler, the despawn log, and field schemas in the cooker.
5. **Tooling:** `--emit-script-types`, type checking in the cooker, `luau-lsp` configuration.
6. **Script hot reload:** module patching, behaviour classes and `on_reload`, main script restarts.
7. **Native code generation and direct field access.**
8. **Later:** editor inspector for fields, bundles.

## Content pipeline
The order in which the daemon was built. Phases 1 to 4 are done; phase 5 is in [Future work](content/README.md#future-work).

1. **Daemon:** one scan for every kind, scripts that fail without stopping the others, the watcher, the cache's generation and `asset.poll` that reads it, the lock, and `just watch`. No editor.
2. **Cook link:** problems by file and line, the index and its changes, `lib/engine/wire`, `cook_link` and its schema, and the editor's side (see [Editor](#editor)).
3. **Asset operations:** the operations, the importers' settings tables, orphans, and the editor's commands, menus, dragging and settings editors.
4. **GPU assets:** shaders, textures and meshes as assets, cooked in parallel, sub-assets, and the GPU residency table (see [Rendering](#rendering), phase 0).
5. **Later:** rewriting requires, pairing orphans, a saved index, and thumbnails as a cook output.

## Editor
The order in which the editor was built. Phases 1 to 15 are done; what comes next is in [Future work](editor/README.md#future-work).

1. **Viewport:** an Avalonia window that shows the host's live frames: the editor's D3D11 device, the copy into keyed-mutex textures, the host's `--adapter`, and the host in its Job Object.
2. **Shell:** the projects, the docking layout, the ribbon and the command registry.
3. **Link:** the server in `src/host`, the handshake, the schema and the C# generator, back-pressure, resizing, and the console. Tests in `Cinnabar.Editor.Tests` run the real host when it is built: the handshake, a refused version, a resize, and back-pressure measured on the shared fence.
4. **Read-only world:** types, the entity list and deltas, the outliner, and the properties panel for watched entities, with behaviours' fields.
5. **Scenes:** the `Name` component, the scene format, the loader, `cook scenes`, and snapshots over the link.
6. **Editing:** operations, transactions, undo history, save and autosave, and field editors.
7. **Viewport tools:** the editor camera, the ID buffer and picking, the selection outline, gizmos and snapping.
8. **Modes:** play, pause, step and stop, and input forwarding.
9. **Resource monitor and game commands:** the host's and the game's stats, script memory by module, and the game's commands in the ribbon.
10. **Content browser:** after the cook daemon's first phase (see [Content pipeline](#content-pipeline)), `Cinnabar.Editor.Content`, the cook link and its schema in the generator, the daemon's log and problems in the console, and the read-only content browser: the index, search, opening scenes and scripts, and dragging a script to add a behaviour.
11. **Asset operations:** create from a template, folders, rename, move, duplicate, delete with its dependents, import settings, and re-import.
12. **Rendering parity:** field tags as lists, colors with a picker, sliders for ranged numbers and two-number fields; volume settings with override check boxes; the viewport's debug views, feature toggles and exposure (see [Rendering](#rendering)).
13. **Capture:** screenshots with a JSON sidecar and the renderer's debug views, the host's history ring and the GIF encoder, the frame target's readback in the backend, the automation socket, and `editorctl` with `just screenshot` and `just gif` (see [Editor](editor/capture.md#capture)).
14. **Mesh editing** (see [Editor](editor/mesh-editing.md)), in six steps: the `.mesh` asset, its parsers, `mesh_bake` and the cooker's importer; the live path, `live_meshes`, `build_simple_meshlets`, the residency override and `MeshOperation` on the scene's stack; the mode, with `MeshPick`, `Mesh_Overlay`, the gizmo on the sub-selection, the grid, Block and the dev materials; the mesh tools, the primitives, Draw and the loop cut; the texture tools, the Face panel, the texel density, tool textures and hotspots in the index, and Transform Texture; and Keep Planar, Select Linked, Grow and Shrink, Edit Pivot and Clean's report.
15. **Prefabs** (see [Editor](editor/prefabs.md)), in four steps: the scene format's version 2, `scene_path_id`, `scene_expand`, the `Prefab` kind and `cook scenes` cooking both kinds flat, with the shared fixture; instances in the editor, with `PrefabExpansion`, `Expanded`, `BlockOperation` and its wire form from the expansion's difference, the content browser's drop, the outliner's and the properties panel's marks, Duplicate, Unpack and Make Prefab; prefab editing, with `PrefabOperation`, Apply and Revert, a prefab as the document, reload from disk and Make Variant; and spawning, with `Field.asset`, the `Asset` value, `scene.spawn_prefab` and `World.spawn(prefab)`.

## Physics
The seven phases, from the backend boundary and scripts in fixed ticks to plugins, are in [Physics: Phases](physics/design.md#phases).

1. **The boundary and the backend:** `lib/core/physics` and `physics.h`, the command format, `Host`, Jolt 5.6.0 with `just jolt` as `physics_jolt.dll` and static libraries, Jolt's jobs on fibers, the null backend, `Platform_API.physics`, the soft-restart cleanup, and the conformance suite.

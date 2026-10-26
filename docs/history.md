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
The order in which the editor was built. Phases 1 to 12 are done; phase 13 is in [Future work](editor/README.md#future-work).

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
13. **Later:** prefabs, which are their own design.

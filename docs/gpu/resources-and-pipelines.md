# Resources and pipelines

Buffers, textures, samplers and acceleration structures as generational handles with lifetime scopes, and pipelines that compile on background jobs and update in place.

**In this document:** [Resources](#resources) · [Pipelines](#pipelines) · [Future work](README.md#future-work)

## Resources

- **Handles:** resources are typed generational handles (`Buffer`, `Texture`, `Pipeline`, `Sampler`, `Accel_Struct`) into pools that `core` owns. A handle to a destroyed resource is detected.
- **Bindless indices:** see [Bindless indices](interface.md#bindless-indices).
- **Creation:** `create_*` returns the nil handle and logs an error if the description is invalid. The backend copies the description and the initial data, so neither can point into the DLL image after the call.
- **Block-compressed formats:** `BC1`, `BC4`, `BC5`, `BC6H` and `BC7`, with sRGB variants of `BC1` and `BC7`, store 4×4 blocks of texels. A texture in one is only sampled, and mip 0's sides are multiples of 4, as D3D12 requires; validation checks both. `format_size` is a block's size for them, and `surface_size` and `mip_chain_size` count whole blocks, so a mip smaller than a block takes one. Their rows in initial and streamed data are rows of blocks.
- **3D textures:** a `Texture_Desc` with a `depth` is a 3D texture of that many slices. It has one mip and no initial data, and only the `Sampled` and `Storage` usages, which shaders read as `cn_texture3d` and write as `cn_rw_texture3d`; validation checks this. The fog's froxel volume is one (see [Rendering](../rendering/fog.md#volumetric-fog)).
- **Initial data:** a buffer or texture created with data gets it through a staging buffer. The copies run before the command lists of the frame, so the resource is ready in the frame that creates it. Texture data is mip 0 with tightly packed rows.
- **Initial layout:** a texture starts in the layout of its first usage in this order: render target, depth stencil, storage, sampled. A texture created with data starts in the sampled layout, and so does a `Streamed` texture once its transfer is done. `gpu.initial_layout` gives the layout. The [render graph](render-graph.md#render-graph) takes over from there.
- **Deferred destruction:** `destroy` invalidates the handle at once. The backend releases the resource, and reuses the pool slot and its descriptors, when the GPU finishes the frame that destroyed it. Two frames are in flight.
- **Lifetime scopes:** each description has a `scope`: `Game` (the default), `Level`, `Asset` or `Permanent`. On a soft restart (see [Hot reload](../overview/hot-reload.md#reload-sequence)), `core` destroys every `Game` resource that the old game left, and keeps the others. `gpu_destroy_scope` destroys a `Level` or `Asset` scope. `Permanent` resources belong to `core` and the backend, for example the frame target and the upload rings.
- **Memory:** the first version uses committed resources. Suballocation is a later change inside the backend.
- **Upload ring:** `upload(size, align)` allocates CPU-written memory that is valid until the end of the frame. Each frame in flight has a 16 MB ring. An `Upload` holds the bytes, a buffer handle and an offset. Shaders read it through `read_index(upload.buffer)` at the offset, or as pass constants. Pass constants need `PASS_CONSTANTS_ALIGN` (256).

## Pipelines

- A pipeline description contains shader blobs, fixed-function state and attachment formats. D3D12 PSOs and Vulkan dynamic rendering both require the attachment formats.
- Pipeline kinds: graphics (vertex), mesh, compute, and later ray tracing. `Graphics_Pipeline_Desc` makes a mesh pipeline when it has a mesh shader instead of a vertex shader.
- Pipelines compile on background jobs. A pipeline handle is valid immediately. Draws and dispatches with a pipeline that is not ready are skipped, and so are those with a pipeline that failed to compile. The backend copies the shader blobs and the label, because the compile job can outlive the call and the blobs can be in the game DLL's image.
- `update_graphics_pipeline` and `update_compute_pipeline` compile a new version of a pipeline. The handle stays the same, and the current version keeps drawing until the new one is ready. If the new version fails to compile, the current one stays. The latest update wins if several are compiling at once.
- `pipeline_ready` (`gpu_pipeline_ready`) is whether a pipeline's latest version is compiled and in use: false while a job that creates or updates it runs, and after its first compile failed. The editor's material previews draw again until their pipelines are ready (see [Rendering](../rendering/materials.md#material-previews)).
- An update must keep the attachment formats, the topology and the pipeline kind, because validation and translation use them before the new version is ready. Such an update returns false and changes nothing, and the game creates a new pipeline instead.
- On a hot reload, the game updates its pipelines in `on_reload`, so the old shaders draw until the new ones compile.
- Blending uses presets (`Opaque`, `Alpha`, `Premultiplied`, `Additive`), one per color target.
- **Depth bias and clamping:** `depth_bias` and `slope_bias` add a constant and a slope-scaled offset to each fragment's depth, and `depth_clamp` clamps depth to the viewport's range instead of clipping. Shadow maps use them (see [Rendering](../rendering/lighting-and-shadows.md#shadows)).
- **Stencil:** a pipeline's `stencil` (`Stencil_State`) holds the test, its operations and its masks, the same for both faces, and `cmd_set_stencil_reference` sets the reference value, 0 at each pass's start. A pipeline that uses the stencil needs `D32_Float_S8_Uint`, whose attachment loads, clears (`Depth_Attachment.stencil_clear`) and stores the stencil with the depth. A sampled `D32_Float_S8_Uint` texture's stencil has its own view, at `gpu.stencil_index`, the write slot that a depth texture does not use; HLSL reads it with `cn_stencil_texture`, in g.
- **Comparison samplers:** a `Sampler_Desc` whose `compare` is not `Always` makes a comparison sampler, which shaders get with `cn_comparison_sampler` and use with `SampleCmp`.

## Future work

- **Suballocation.** Every resource is a committed resource. Placed resources in large heaps, with a free-list or buddy allocator per heap type, would cut allocation time and fragmentation once scenes have thousands of resources. The change stays inside the backend: handles and descriptions do not change. Do this when the resource monitor's memory in use diverges from the sum of the resources, or when creation shows in the frame time.
- **Asset resources on soft restart.** From [Open questions](README.md#open-questions): the residency table is in `Game_State`, so a soft restart destroys and re-streams every resident asset ([Rendering](../rendering/assets.md#gpu-residency)). Moving the table of resident handles into host-owned memory, with the `Asset` scope, would keep them up across a soft restart as the loaded blobs already are. Do this when soft restarts in the editor take long enough to notice.
- **Streaming and mip residency.** Streaming is whole-resource. Per-mip streaming (tiled or reserved resources, or a mip chain uploaded tail first) and a budget-driven residency policy come with larger scenes, together with the asset runtime's unloading by use.
- **Descriptor heap growth.** The heap ranges have fixed capacities (`MAX_BUFFERS`, `MAX_TEXTURES`, `MAX_ACCEL_STRUCTS`). The fixed index functions make growth a matter of larger constants, but a content budget should decide them before a scene fills one.

- **Cooked pipeline assets.** Pipeline descriptions live in game code and are created from shader blobs' entries. A cooked pipeline asset, with its shaders, state and attachment formats in one blob, would let the cooker validate state against the shaders and precompile where the API allows it (D3D12 PSO caching). It waits for the asset runtime to own GPU data.
- **Pipeline cache.** D3D12's pipeline library and Vulkan's pipeline cache would make the first frame after a start faster. Store the cache beside the loose cache, keyed by the driver.

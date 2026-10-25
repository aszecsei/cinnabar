# GPU

`lib/core/gpu` is the backend-agnostic GPU interface. The engine records command buffers, and the backend translates and submits them. See [Architecture](architecture.md#rendering) for the overview.

D3D12 is the first backend. Vulkan and Metal are possible later ports. A port must only add a backend package to `lib/core/gpu`. It must not require changes to `lib/engine`, to games or to shaders.

## Hardware floor

The interface targets the feature set that the three APIs share:

| D3D12 | Vulkan | Metal |
|---|---|---|
| Shader Model 6.6, Enhanced Barriers | 1.3 with descriptor indexing and `synchronization2` | Metal 3 with tier 2 argument buffers |

Older hardware is not supported. Each design rule below follows from this floor.

The D3D12 runtime built into Windows can be older than the floor. For example, Windows 11 23H2 has no Enhanced Barriers. The D3D12 backend therefore uses the D3D12 Agility SDK. The executable exports `D3D12SDKVersion` and `D3D12SDKPath`, and the build copies the Agility SDK runtime to `D3D12/` next to the executable. `just install` downloads the version that the justfile pins.

### Optional capabilities

Some features are above the floor. The backend reports them at device creation in a `Features` bit set:

- Mesh and amplification shaders.
- Inline ray tracing (ray queries).
- Ray tracing pipelines.

The engine checks `Features` before it uses a capability. Every capability must have a fallback path in the engine, or the engine must report that the device is not supported.

To test a fallback path on hardware that has the capability, set `CINNABAR_DISABLE_FEATURES` to a comma-separated list of `Feature` names, for example `CINNABAR_DISABLE_FEATURES=Mesh_Shaders`. `core` then hides those features from `gpu_features`. The null backend reports `Mesh_Shaders`, so it validates mesh pipelines and mesh draws.

## Packages

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/gpu` | Both | Pure Odin. Handles, descriptions, enums, command packet definitions, `Command_Buffer` recording procedures, the format hash. |
| `lib/core/gpu/d3d12` | Host | The D3D12 backend. The only package that imports `vendor:directx`. |
| `lib/core/gpu/null` | Host | Validates command buffers and executes nothing. Used for headless tests. |
| `lib/engine/render` | Game | Render graph (barriers, pass culling, transient textures), frame setup, render extraction. |

The engine imports `lib/core/gpu` for types and recording only. It never imports a backend package.

**Backend selection:** `lib/core` imports the backend as `gpu_backend:.`. The build points the `gpu_backend` collection at one backend package, for example `-collection:gpu_backend=lib/core/gpu/d3d12`. In the justfile, set `gpu_backend` to choose the backend. Every backend package provides the same procedures: `init`, `shutdown`, `features`, `frame_target`, `begin_frame`, `submit`, `end_frame`, `upload`, `create_*` and `destroy_*` for buffers, textures, samplers, pipelines and acceleration structures, `update_*_pipeline`, `accel_reference`, `destroy_scope`, `stream_buffer`, `stream_texture`, `transfer_done`, `read_buffer`, and `stats`, the live resources and the memory for the editor's resource monitor, which only the host calls. `core` exposes them to the game as `gpu_*` fields of `Platform_API`.

The null backend applies the same rules as the real backends: pass rules, barrier rules and handle validity. It also tracks texture layouts, so it rejects a barrier from the wrong layout. Use it to find code that only D3D12 accepts.

## Binding model

All resource binding is bindless. There is one fixed root signature for all pipelines:

| Slot | Contents |
|---|---|
| Root constants | 128 bytes of push constants. This is the size Vulkan guarantees. |
| Root CBV | Per-pass constants. |
| Root constant | The draw ID of an indirect draw (`CN_DRAW_ID`, `b2`). 0 for every other draw. |
| Descriptor heaps | Every buffer, texture, acceleration structure and sampler view. Shaders use `ResourceDescriptorHeap` and `SamplerDescriptorHeap`. |

- A shader receives resources as `u32` bindless indices, usually in push constants.
- There are no per-pipeline root signatures and no descriptor tables.
- Shaders include `lib/core/gpu/shaders/cinnabar.hlsli`. It declares push constants (`CN_PUSH_CONSTANTS`) at `b0`, pass constants (`CN_PASS_CONSTANTS`) at `b1`, and bindless accessors such as `cn_buffer` and `cn_texture`.

### Bindless indices

A bindless index is a fixed function of the handle's pool index: `gpu.read_index`, `gpu.write_index` and `gpu.sampler_index`. The game computes indices without a call to `core`, and an index never changes while the handle lives.

The resource heap has five ranges, in order: buffer reads, buffer writes, texture reads, texture writes and acceleration structures. Each range has the capacity of its pool (`MAX_BUFFERS`, `MAX_TEXTURES`, `MAX_ACCEL_STRUCTS`). Only top-level acceleration structures have a view. Samplers use their pool index in the sampler heap. Vulkan descriptor arrays and Metal argument buffers can use the same fixed indices.

- Every buffer but a `Readback` buffer has a read view (see [Readback](#readback)). Buffers with the `Storage` usage also have a write view.
- Textures with the `Sampled` usage have a read view. Textures with the `Storage` usage have a write view.
- Porting: DXC compiles `ResourceDescriptorHeap` to SPIR-V with descriptor indexing. `metal-shaderconverter` compiles DXIL to a metallib and implements the root signature as a top-level argument buffer.

### Vertex pulling

Pipelines have no input layout. Shaders read vertex data from byte-address buffers with `Load<T>`. Buffer views are raw, so structured buffers are not used. Index buffers are still supported.

## Resources

- **Handles:** resources are typed generational handles (`Buffer`, `Texture`, `Pipeline`, `Sampler`, `Accel_Struct`) into pools that `core` owns. A handle to a destroyed resource is detected.
- **Bindless indices:** see [Bindless indices](#bindless-indices).
- **Creation:** `create_*` returns the nil handle and logs an error if the description is invalid. The backend copies the description and the initial data, so neither can point into the DLL image after the call.
- **Block-compressed formats:** `BC1`, `BC4`, `BC5`, `BC6H` and `BC7`, with sRGB variants of `BC1` and `BC7`, store 4×4 blocks of texels. A texture in one is only sampled, and mip 0's sides are multiples of 4, as D3D12 requires; validation checks both. `format_size` is a block's size for them, and `surface_size` and `mip_chain_size` count whole blocks, so a mip smaller than a block takes one. Their rows in initial and streamed data are rows of blocks.
- **3D textures:** a `Texture_Desc` with a `depth` is a 3D texture of that many slices. It has one mip and no initial data, and only the `Sampled` and `Storage` usages, which shaders read as `cn_texture3d` and write as `cn_rw_texture3d`; validation checks this. The fog's froxel volume is one (see [Rendering](rendering.md#volumetric-fog)).
- **Initial data:** a buffer or texture created with data gets it through a staging buffer. The copies run before the command lists of the frame, so the resource is ready in the frame that creates it. Texture data is mip 0 with tightly packed rows.
- **Initial layout:** a texture starts in the layout of its first usage in this order: render target, depth stencil, storage, sampled. A texture created with data starts in the sampled layout, and so does a `Streamed` texture once its transfer is done. `gpu.initial_layout` gives the layout. The [render graph](#render-graph) takes over from there.
- **Deferred destruction:** `destroy` invalidates the handle at once. The backend releases the resource, and reuses the pool slot and its descriptors, when the GPU finishes the frame that destroyed it. Two frames are in flight.
- **Lifetime scopes:** each description has a `scope`: `Game` (the default), `Level`, `Asset` or `Permanent`. On a soft restart (see [Hot reload](hot-reload.md#reload-sequence)), `core` destroys every `Game` resource that the old game left, and keeps the others. `gpu_destroy_scope` destroys a `Level` or `Asset` scope. `Permanent` resources belong to `core` and the backend, for example the frame target and the upload rings.
- **Memory:** the first version uses committed resources. Suballocation is a later change inside the backend.
- **Upload ring:** `upload(size, align)` allocates CPU-written memory that is valid until the end of the frame. Each frame in flight has a 16 MB ring. An `Upload` holds the bytes, a buffer handle and an offset. Shaders read it through `read_index(upload.buffer)` at the offset, or as pass constants. Pass constants need `PASS_CONSTANTS_ALIGN` (256).

## Pipelines

- A pipeline description contains shader blobs, fixed-function state and attachment formats. D3D12 PSOs and Vulkan dynamic rendering both require the attachment formats.
- Pipeline kinds: graphics (vertex), mesh, compute, and later ray tracing. `Graphics_Pipeline_Desc` makes a mesh pipeline when it has a mesh shader instead of a vertex shader.
- Pipelines compile on background jobs. A pipeline handle is valid immediately. Draws and dispatches with a pipeline that is not ready are skipped, and so are those with a pipeline that failed to compile. The backend copies the shader blobs and the label, because the compile job can outlive the call and the blobs can be in the game DLL's image.
- `update_graphics_pipeline` and `update_compute_pipeline` compile a new version of a pipeline. The handle stays the same, and the current version keeps drawing until the new one is ready. If the new version fails to compile, the current one stays. The latest update wins if several are compiling at once.
- `pipeline_ready` (`gpu_pipeline_ready`) is whether a pipeline's latest version is compiled and in use: false while a job that creates or updates it runs, and after its first compile failed. The editor's material previews draw again until their pipelines are ready (see [Rendering](rendering.md#material-previews)).
- An update must keep the attachment formats, the topology and the pipeline kind, because validation and translation use them before the new version is ready. Such an update returns false and changes nothing, and the game creates a new pipeline instead.
- On a hot reload, the game updates its pipelines in `on_reload`, so the old shaders draw until the new ones compile.
- Blending uses presets (`Opaque`, `Alpha`, `Premultiplied`, `Additive`), one per color target.
- **Depth bias and clamping:** `depth_bias` and `slope_bias` add a constant and a slope-scaled offset to each fragment's depth, and `depth_clamp` clamps depth to the viewport's range instead of clipping. Shadow maps use them (see [Rendering](rendering.md#shadows)).
- **Stencil:** a pipeline's `stencil` (`Stencil_State`) holds the test, its operations and its masks, the same for both faces, and `cmd_set_stencil_reference` sets the reference value, 0 at each pass's start. A pipeline that uses the stencil needs `D32_Float_S8_Uint`, whose attachment loads, clears (`Depth_Attachment.stencil_clear`) and stores the stencil with the depth. A sampled `D32_Float_S8_Uint` texture's stencil has its own view, at `gpu.stencil_index`, the write slot that a depth texture does not use; HLSL reads it with `cn_stencil_texture`, in g.
- **Comparison samplers:** a `Sampler_Desc` whose `compare` is not `Always` makes a comparison sampler, which shaders get with `cn_comparison_sampler` and use with `SampleCmp`.

## Command buffers

The engine records commands into `Command_Buffer`s in frame memory.

- **Format:** a stream of packets. Each packet has a `{kind: u16, size: u16}` header and an inline payload. Push constants are part of the payload.
- **Plain data:** packets contain only handles, indices and POD data. Debug label strings are copied into frame memory. Packets never point into the DLL image (see [Hot reload](hot-reload.md#rules), rule 3).
- **Parallel recording:** each job records into its own `Command_Buffer`. A submission is an ordered list of command buffers for one queue.
- **Format hash:** `lib/core/gpu` is compiled into both the host and the game DLL. `Game_API` exports a hash of the packet layouts. If the hash differs from the host's, the host refuses the reload and asks for a restart.

### Pass rules

These rules come from Metal's encoder model. All backends enforce them.

- A pass begins and ends in the same command buffer. Debug markers also begin and end in the same command buffer, and they nest with passes. A [split pass](#split-passes) is a chain of such pieces.
- Draws occur only inside a render pass.
- Bindings reset at every pass boundary: the pipeline, pass constants and index buffer. Bind them again in each pass, and bind compute pipelines again after a pass. A render pass begins with the viewport and scissor set to the attachment size.
- A graphics pipeline's attachment formats must match the pass. A compute pipeline is bound only outside a pass.
- Copies, dispatches and acceleration structure builds occur only outside a render pass.
- A render pass declares its attachments with load and store operations. It maps to `BeginRenderPass` (D3D12), dynamic rendering (Vulkan) and a render command encoder (Metal).

### Split passes

A large render pass can be recorded in parallel as pieces, in consecutive command buffers of one submission. On the GPU, the pieces are one render pass.

- `Begin_Pass` has `Pass_Flags`. Each piece but the last is `Suspending`, and each piece but the first is `Resuming`.
- A suspending piece ends its command buffer and stores its attachments. A resuming piece starts its command buffer, loads its attachments, and has the same attachments as the piece before it. Only the first piece clears, and only the last piece can discard.
- Nothing runs between the pieces: no barriers and no debug markers. Each piece starts with nothing bound, like any pass.
- `validate_submission` checks the chains: every suspended piece is resumed by the next command buffer, and no chain crosses the end of a submission.
- **Mapping:** D3D12 `SUSPENDING_PASS` and `RESUMING_PASS`, in consecutive lists of one `ExecuteCommandLists` call. Vulkan dynamic rendering with `VK_RENDERING_SUSPENDING_BIT` and `VK_RENDERING_RESUMING_BIT` in one submission. Metal: the chain becomes one `MTLParallelRenderCommandEncoder`, with one child encoder per piece.
- **Instance IDs:** `SV_InstanceID` starts at 0 in each draw on D3D12 but includes the first instance on Vulkan. A piece that draws part of an instance range passes its first instance to the shader, for example in push constants.

### Barriers

- Barriers use the Enhanced Barriers model: sync stages (`Syncs`), access flags (`Accesses`) and texture layouts (`Texture_Layout`). This model maps one-to-one to Vulkan `synchronization2`. On Metal, most barriers become nothing or fences.
- `cmd_barriers` records buffer, texture and acceleration structure barriers. Barriers occur only outside a render pass. A barrier covers the whole resource. Acceleration structures have only the `Accel_Read` and `Accel_Write` accesses.
- An empty `Syncs` means no synchronization, and an empty `Accesses` means no access. A side with no synchronization has no access.
- `Undefined` as the layout before discards the contents, whatever the texture's layout is.
- The backend does not track resource states to translate barriers. State tracking would serialize parallel recording.
- Validation in debug builds and in the null backend tracks texture layouts. It rejects a barrier whose layout before is wrong, and a render pass whose attachments are not in the render target or depth write layout.
- **Frame boundary:** a frame starts after the GPU completes the work of the previous frame, on both queues. A resource therefore needs no barrier for work in an earlier frame, only a layout change. In D3D12, the completion of an `ExecuteCommandLists` call finishes all work and flushes all caches, and the compute queue's first work in a frame waits for the previous frame's end. A Vulkan backend adds a full barrier at the start of each frame.
- **Cross-queue use** works the same way: after a fence wait, the earlier work of the other queue is complete and visible, so only a layout change needs a barrier (see [Queues](#queues)).
- The render graph in `lib/engine/render` records all barriers.

### Render graph

The game builds a `render.Graph` every frame in frame memory. Passes declare how they use each resource, and the graph computes the barriers.

- **Passes:** `add_render_pass` or `add_compute_pass`, in execution order. Each pass has a `Pass_Proc` that records its commands through a `Pass_Context`. The graph records the barriers, a debug marker with the pass name, and for a render pass `Begin_Pass` and `End_Pass`.
- **Pieces:** `pieces = n` splits a pass across `n` jobs (at most `MAX_PASS_PIECES`). The `Pass_Proc` runs once per piece, and `Pass_Context.piece` and `piece_count` tell it which share of the work to record. The first piece records the barriers. A render pass becomes a [split pass](#split-passes): the graph makes the pieces load and store between each other, and puts each piece's debug marker inside its pass. A compute pass's pieces are plain command buffers.
- **Uses:** `color` and `depth` declare attachments with load and store operations. `read` and `write` declare shader access to textures and buffers. `index_buffer` declares an index buffer, and `indirect_buffer` declares indirect arguments or a count. `import_accel`, `build_accel`, `read_accel` and `build_input` declare acceleration structures, their builds, traces against them, and the geometry and bottom-level structures that a build reads. `add_ray_tracing_pass` adds a pass whose shader accesses synchronize with the ray tracing stage. `copy_source` and `copy_dest` declare the buffers of `cmd_copy_buffer`. A pass can read a resource in several ways, but any other second use of the same resource in one pass is an error.
- **Imported resources:** `import_texture` and `import_buffer` add resources that outlive the frame. An imported texture has a resting use, and the graph returns it to that layout at the end of the frame. The frame target rests as `Color`. A texture created with data rests as `Sampled`.
- **Transient textures:** `create_texture` adds a texture that exists for one frame. The graph adds the usages that its uses need. A `Texture_Cache` in `Game_State` keeps the textures between frames, keyed by description and label, and destroys a texture after `CACHE_LIFETIME` frames without use. When all `MAX_CACHED_TEXTURES` are in use, it destroys the least recently used one that the frame does not use, so a window resized every frame does not fill it.
- **History textures:** `history_texture` adds a pair of textures that the `Texture_Cache` keeps between frames and swaps every frame, as temporal passes need: a pass writes `current` in shaders, and reads `previous`, which holds what `current` held in the last frame. Both are imported and rest in the storage layout, with the `Sampled` and `Storage` usages. `previous` is valid only if the history was used in the last frame with the same description, so the first frame, a frame that skipped it, or a new size, which makes the pair again, starts over. Each label is one history, used at most once a frame, and at most `MAX_HISTORY_TEXTURES` exist.
- **Barriers:** a use needs a barrier when it changes the layout, when it follows a write, or when it writes after any access. Reads in the same layout merge without a barrier, so a later write waits for all of them. A transient texture starts `Undefined`, and sampling it before a pass writes it is an error.
- **Culling:** the graph walks the passes backward from the imported resources. A pass is live if it writes a resource that a later live pass reads, if it writes an imported resource, or if `keep_pass` marks it. A write that does not read (for example a clear) makes earlier writers of that resource unnecessary.
- **Handles:** graph handles are valid for one graph. In a `Pass_Proc`, `gpu_texture` and `gpu_buffer` return the `gpu` handles, because transient textures exist only after recording starts.
- **Queues:** `add_compute_pass(..., queue = .Compute)` runs a compute pass on the compute queue. When a pass uses a resource that another queue used last in the frame, the pass waits for that queue, and the resource's state resets as at a frame boundary. Only a layout change still needs a barrier. The compute queue can change a texture only between the undefined, sampled and storage layouts, so when a compute-queue pass needs a texture that a render pass left as a target, the texture's last pass changes its layout after its own work, and the wait orders the change. The ambient occlusion reads the prepass's depth, normals and velocity this way.
- **Execution:** `execute` computes all barriers and queue waits in pass order first. Then each piece of each live pass records into its own command buffer on its own job, so `Pass_Proc`s run in parallel. Consecutive live passes on one queue form one `Submission`, and `execute` submits them in pass order. A last command buffer returns imported textures to their resting layouts.

## GPU-driven rendering

The engine culls and builds draws on the GPU.

- **Indirect commands:** `cmd_draw_indirect`, `cmd_draw_indexed_indirect` and `cmd_dispatch_indirect`. A draw takes an argument buffer, an offset, a maximum draw count and an optional count buffer: the `u32` at the count offset caps the draws. `cmd_draw_mesh_indirect` is the mesh version (see [Mesh shaders](#mesh-shaders)).
- **Records:** `Draw_Indirect_Args`, `Draw_Indexed_Indirect_Args` and `Dispatch_Indirect_Args` define the argument layouts. Argument and count buffers need the `Indirect` usage, and offsets are multiples of 4. Validation checks that the records are in range.
- **Draw ID:** each draw record starts with a `u32` draw ID, followed by the standard arguments. Shaders read it with the `CN_DRAW_ID` macro. The D3D12 backend delivers it as a root constant through the command signature. A Vulkan backend delivers the `DrawIndex` built-in, which is the record's index from the command's offset. So portable code stores each record's index as its draw ID, and keeps per-draw data in a buffer indexed by it.
- **Instance IDs:** `SV_InstanceID` does not include the first instance on D3D12, but does on Vulkan. Shaders that need the first instance read it from their own data.
- **Barriers:** indirect reads use the `Execute_Indirect` sync and the `Indirect_Argument` access.

## Queues

- `Queue` is `Graphics` or `Compute`. `gpu_submit(buffers, queue, wait_for)` runs the command buffers on the queue, in order after the queue's earlier submissions in the frame. They start after the earlier submissions in the frame of each queue in `wait_for`.
- A compute-queue command buffer has no render passes. Its barriers use only `COMPUTE_QUEUE_SYNCS` and `COMPUTE_QUEUE_ACCESSES`, and its textures only the `Shader_Resource` and `Unordered_Access` layouts. Validation checks this.
- Work on both queues is frame-scoped: a frame's compute work starts after the previous frame's end, and the frame ends after its compute work. The upload ring and deferred destruction therefore cover both queues.
- **D3D12:** a direct and a compute queue, each with a fence. `end_frame` runs the submissions in order. Each queue's lists wait in a batch until another queue waits for them or the frame ends, and then run in one `ExecuteCommandLists` call after the batch's fence waits. A wait applies before the whole batch, which can only delay earlier lists. Each wait records the fence value at the time it is declared, so batching cannot make a wait cycle.
- **Vulkan and Metal:** queue submissions with timeline semaphores, and a Metal compute command queue with `MTLEvent`s.
- The backend has a copy queue for [streaming](#streaming). It is not a submission target: command buffers run on the graphics and compute queues, and those queues also run `cmd_copy_buffer`.

## Streaming

Streaming copies data into resources on the copy queue, beside the frame's work. The asset runtime will stream its GPU data this way.

- `gpu_stream_buffer(buffer, offset, data)` and `gpu_stream_texture(texture, data)` copy the data before they return and return a `Transfer`. Use the resource once `gpu_transfer_done(transfer)` is true.
- A streamed texture has the `Streamed` usage with `Sampled` and no other usage, and is streamed once with its whole mip chain: each mip tightly packed, mip 0 first (`mip_chain_size`). Copy queues cannot change texture layouts, so the texture is created in the common layout. When its copy is complete, the backend moves it to the sampled layout at the start of the next frame, and only then reports the transfer done.
- A failed stream logs an error and returns the zero `Transfer`. Validation rejects a range out of bounds, data of the wrong size, and a second stream of a texture.
- **D3D12:** each stream call records into the open copy batch with its own staging buffer, and `end_frame` executes the batch and signals the copy fence. A transfer's ID is its batch's fence value. A destroyed resource or a staging buffer is released only after both the frame fence and the copy fence pass, because a copy batch can outlive the frame.
- **Copies in command buffers:** `cmd_copy_buffer` copies between two different buffers, outside render passes, with the `Copy` sync and the `Copy_Source` and `Copy_Dest` accesses. The source can be the upload ring, which makes it the way to update or clear a default-heap buffer. The sample zeroes its draw count this way.

## Readback

- A buffer with the `Readback` usage is in CPU-readable memory. It has no views and no other usage, and takes no initial data. The GPU only writes it, as the destination of `cmd_copy_buffer`, so a shader writes a storage buffer and a copy moves the result.
- `gpu_read_buffer(buffer)` returns the buffer's memory once the GPU has finished every frame that copies into it, and false while one is in flight. The memory is the backend's: read it during the frame, and keep no pointer into it. Copy into a readback buffer again only after reading it.
- A buffer that nothing has copied into reads as ready. A caller that must know its copy ran, such as the editor's picks, writes a ticket into the data.
- **D3D12:** a readback buffer is a committed resource in a readback heap, mapped for its whole life. Translating a copy into one marks it in flight, `end_frame` stamps it with the frame's fence value, and `gpu_read_buffer` compares that with the fence's completed value.
- **Null backend:** a readback buffer is zeroed memory, always ready.

## Mesh shaders

- Mesh and amplification shaders are HLSL and compile with the other shaders. They map to `VK_EXT_mesh_shader` and to Metal object and mesh shaders.
- A mesh pipeline replaces the vertex stage with a mesh shader and an optional amplification shader. All other pipeline state is the same, except that the mesh shader declares its topology. A pipeline has a vertex shader or a mesh shader, not both, and creating a mesh pipeline without `Features.Mesh_Shaders` fails.
- `cmd_draw_mesh(groups)` launches amplification groups, or mesh groups if there is no amplification shader. `cmd_draw_mesh_indirect` reads `Draw_Mesh_Indirect_Args` records, which start with a draw ID like the other draw records. Validation checks that each draw matches the bound pipeline's kind, and mesh draws need no index buffer.
- An update cannot turn a vertex pipeline into a mesh pipeline or back, because validation uses the kind before the new version is ready.
- **D3D12:** mesh pipelines compile from a pipeline state stream on the same background jobs, and draws use `DispatchMesh` and a command signature with the draw ID.
- **Fallback:** the engine keeps a vertex-pulling path for devices without mesh shaders. The sample shows both: with mesh shaders, amplification shaders cull the objects and mesh shaders draw them; without, a compute pass culls on the compute queue and an indexed indirect draw draws them. Both paths place vertices with the same shader function.

## Ray tracing

- **Acceleration structures** are a resource type (`Accel_Struct`), and need `Ray_Query` or `Ray_Tracing_Pipeline`. A bottom-level structure holds triangle geometries from vertex and optional index buffers. A top-level structure holds instances. The backend sizes each structure at creation, for its largest build. Build scratch memory comes from the backend's scratch pool.
- **Builds:** `cmd_build_accel` builds a bottom-level structure from the geometry in its description. `cmd_build_top_accel` builds a top-level structure from `Accel_Instance` records, which can be in the upload ring. `update` refits a structure that has `Allow_Update`. Builds occur outside render passes and work on the compute queue. Validation rejects a build whose geometry buffer was destroyed.
- **Instances:** `Accel_Instance` is the 64-byte record that D3D12 and Vulkan share: a row-major 3x4 transform, a 24-bit ID and 8-bit mask, a 24-bit hit group offset and 8 flag bits, and a reference from `gpu_accel_reference`. That is a GPU address on D3D12 and a device address on Vulkan. A Metal backend converts the records in a compute pass at build time.
- **Inline ray tracing first.** `RayQuery` in any shader stage maps to `VK_KHR_ray_query` and to Metal intersection queries. Shaders get a top-level structure with `cn_accel(read_index(accel))`. This is the main ray tracing path.
- **Ray tracing pipelines second.** `Ray_Tracing_Pipeline_Desc` names a ray generation shader, miss shaders and hit groups in a DXIL library. The backend builds the shader table in that order, with no local data, because shaders get their resources bindless. `cmd_dispatch_rays` runs the bound pipeline outside a render pass. They map to `VK_KHR_ray_tracing_pipeline`. Metal has no native equivalent, so a Metal backend may not report this capability. Effects must have an inline or raster fallback.
- **Scratch pool:** each frame in flight has a pool of build scratch memory, and every build takes its own region of it. So builds in a frame never share scratch memory and need no barriers between them, on either queue. A pool resets when its frame's fence passes, like the upload ring. It grows in 16 MB blocks, and a larger build gets a block of its own size. Blocks are kept for later frames and never shrink.
- **D3D12:** Ray tracing pipelines compile to a state object on the background compile jobs, with the fixed root signature as the global root signature. The shader table is in an upload heap. A new version replaces the state object and table together, and the old ones are released after the frames that use them.
- **Sample:** the large triangles cast ray-traced shadows. With `Ray_Tracing_Pipeline`, a ray generation shader traces them. With only `Ray_Query`, a compute pass traces the same rays inline. Without either, there are no shadows.

## Presentation

- The game renders into a frame target texture that `core` provides. The engine never sees a swapchain.
- The frame target is in the render target layout when the frame starts, and the game must leave it in that layout. Its contents are undefined at the start of each frame.
- `core` reads the window size once at the start of each frame. The frame target has that size, and `window_size` returns it for the whole frame. While the window is minimized, the size is zero and the game renders nothing.
- **Standalone:** `core` copies the frame target to the swapchain and presents with vsync. Vsync paces the frame.
- **Output modes:** `gpu_output` gives the frame's `gpu.Output`: its `Output_Mode`, the frame target's format, which follows from the mode (`output_format`), and the `Display`. `Sdr` is `FRAME_TARGET_FORMAT`, with an sRGB view. `Hdr10` is `RGB10A2_Unorm`, with Rec. 2020 primaries encoded with the PQ curve of SMPTE ST 2084. `Scrgb` is `RGBA16_Float`, linear with Rec. 709 primaries, where 1 is 80 nits. `gpu_request_output` asks for a mode from the next frame on. Its default, `Auto`, is `Hdr10` while the display is in HDR. Set `CINNABAR_OUTPUT` to an `Output_Request` name, such as `CINNABAR_OUTPUT=Scrgb`, and `core` ignores the game's requests and uses that one. Shared mode is always `Sdr`, because the editor reads its textures as sRGB. See [Rendering](rendering.md#hdr-output).
- **The display** is the one that shows most of the window: whether the desktop is in HDR on it, its luminances from DXGI, and its SDR white, the brightness that Windows gives SDR content in HDR, from the display configuration. DXGI does not report the SDR white. The D3D12 backend finds the display again every 60 frames, and at once when its factory is no longer current, because the adapters or outputs changed, for example when HDR is turned on or off.
- **A change of mode** waits for the GPU, gives the swapchain's buffers the new format, and sets the swapchain's color space. A mode whose color space the swapchain cannot present falls back to `Sdr`, and is not tried again. The frame target keeps its handle, and its description has the new format, so a pipeline that draws into it needs a version for each format.
- **Editor:** `core` renders into shared textures and signals a shared fence instead (see [Editor](editor.md#viewport)). `host --shared <name>` selects this: the window is hidden, and nothing presents. The frame target has the window's size until the editor asks for another one with `core.resize_shared_target`. Each size is a generation of the shared target, and its objects are named `<name>.g<generation>.texture0..2` and `<name>.g<generation>.fence`. The D3D12 backend renders frame k of a generation into texture k % 3 and then signals k on the generation's fence, so a reader that sees fence value v reads texture v % 3. Frames count from 1 in each generation. A resize waits for the GPU, releases the old objects and makes the new ones, and readers keep the old ones alive until they open the new ones. A frame ends with its texture in the common layout, which other processes can use. The textures have the frame target's typed format, because D3D11 cannot open a shared typeless texture, and the editor reads them with D3D11. A high-resolution 60 Hz timer paces the frame. `--adapter <luid>` makes the host use the GPU whose LUID it gives, in hex, because shared objects open only on the adapter that created them.
- **Back-pressure:** while the editor is linked, `core.pace_shared_frames` is on, and the backend renders frame k into a shared texture only if k is at most the reader's acknowledged frame + 2 (`core.acknowledge_shared_frame`). Otherwise it renders into a scratch target that nothing reads, and signals nothing. A slow reader therefore drops frames and never stalls the host.
- **Preview targets:** in shared mode, the editor's material previews have shared targets of their own beside the frame target, at most `MAX_PREVIEW_TARGETS` (4), each at most `MAX_PREVIEW_SIZE` (1024) on a side, named `<name>.preview<id>.g<generation>.texture0..2` and `.fence` (see [Rendering](rendering.md#material-previews)). `gpu_preview_target(id, size)` gives the game a target's texture for the frame, in the render target layout, with its name prefix and generation; it makes the target the first time, and a new generation when the size changes, which waits for the GPU as a resize of the frame target does. The barrier that starts the frame's use goes in at the call, and the frame's end moves the texture to the common layout and signals frame k on the target's fence. A preview has no scratch target: while the reader may still read the texture that frame k would use (k > acknowledged + 2, with `core.acknowledge_preview_frame`), it gives false, and the game draws no preview. `gpu_release_preview_target` releases a target's objects after waiting for the GPU.
- `tools/viewer <name>` opens generation 0 by name and shows the frames in its own window. It has no editor link, so nothing resizes the target and nothing paces it: a viewer that falls more than a frame behind can read a texture that the host is drawing again. `just dev-shared` runs the host and the viewer.

## Submission

- `submit` translates each `Command_Buffer` into one native command list, each on its own job, and waits for them. The lists keep the submission order. Call `submit` from the frame code or from a job.
- Native command lists and allocators are pooled per frame in flight, not per thread, because a fiber can resume on a different thread (see [Core](core.md#job-system)). A translation job takes a list from the pool. The pool grows when a frame needs more lists.
- Command lists are pooled per queue type. `end_frame` executes the submissions as described in [Queues](#queues). The frame target's transitions in and out run in the first and last graphics batches.

## Shaders

- Shaders are HLSL. `tools/cook` compiles each shader to DXIL with DXC. A Vulkan port adds SPIR-V from DXC. A Metal port adds a metallib from `metal-shaderconverter`.
- Shaders are assets (see [Content pipeline](content-pipeline.md#shaders)). The cooker compiles each `.hlsl` file's `vs_main`, `ps_main`, `cs_main`, `as_main` and `ms_main` entry points into one blob, with the DXC release that the justfile pins. A file with `[shader("...")]` attributes is a ray tracing library, and its blob has one library entry.
- The cooker attaches the fixed root signature, `CN_ROOT_SIGNATURE` in `cinnabar.hlsli`, to every shader stage. So DXC rejects a shader that binds anything outside it, and the runtime never compiles or reflects shaders. A library gets its global root signature from the pipeline instead.
- A pipeline passes its root signature to D3D12, which then ignores the embedded one. So debug builds compare each shader's embedded root signature with the backend's, and refuse a pipeline whose shaders differ. That catches `CN_ROOT_SIGNATURE` drifting from the backend.
- Pipeline descriptions stay in game code until the asset runtime can load cooked pipeline assets.
- The game and `lib/engine/editor` load shader assets by GUID and create their pipelines from the blobs' entries. When `asset.poll` swaps a shader's blob, its pipelines update with `update_graphics_pipeline` or `update_compute_pipeline`, so a shader change needs no code reload (see [Rendering](rendering.md#gpu-residency)).

## Debugging

- Development builds enable the D3D12 debug layer and DRED. They also validate each command buffer, including barrier layouts, before translation.
- Every resource and pipeline has a debug name. Command buffers carry debug markers for PIX.

## Implementation phases

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

## Open questions

- **Dividing a split pass's work:** a pass has a fixed piece count, and each piece takes a share by index. A `Pass_Proc` that starts its own child jobs for pieces would suit work that is not an array, but the graph would then have to collect and order the pieces.
- **Asset resources on soft restart:** the asset runtime is game-side, but asset GPU resources must survive a soft restart. The asset runtime's handle tables must therefore live in host-owned memory.

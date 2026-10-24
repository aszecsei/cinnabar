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

## Packages

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/gpu` | Both | Pure Odin. Handles, descriptions, enums, command packet definitions, `Command_Buffer` recording procedures, the format hash. |
| `lib/core/gpu/d3d12` | Host | The D3D12 backend. The only package that imports `vendor:directx`. |
| `lib/core/gpu/null` | Host | Validates command buffers and executes nothing. Used for headless tests. |
| `lib/engine/render` | Game | Render graph (barriers, pass culling, transient textures), frame setup, render extraction. |

The engine imports `lib/core/gpu` for types and recording only. It never imports a backend package.

**Backend selection:** `lib/core` imports the backend as `gpu_backend:.`. The build points the `gpu_backend` collection at one backend package, for example `-collection:gpu_backend=lib/core/gpu/d3d12`. In the justfile, set `gpu_backend` to choose the backend. Every backend package provides the same procedures: `init`, `shutdown`, `features`, `frame_target`, `begin_frame`, `submit`, `end_frame`, `upload`, and `create_*` and `destroy_*` for buffers, textures, samplers and pipelines. `core` exposes them to the game as `gpu_*` fields of `Platform_API`.

The null backend applies the same rules as the real backends: pass rules, barrier rules and handle validity. It also tracks texture layouts, so it rejects a barrier from the wrong layout. Use it to find code that only D3D12 accepts.

## Binding model

All resource binding is bindless. There is one fixed root signature for all pipelines:

| Slot | Contents |
|---|---|
| Root constants | 128 bytes of push constants. This is the size Vulkan guarantees. |
| Root CBV | Per-pass constants. |
| Descriptor heaps | Every buffer, texture, acceleration structure and sampler view. Shaders use `ResourceDescriptorHeap` and `SamplerDescriptorHeap`. |

- A shader receives resources as `u32` bindless indices, usually in push constants.
- There are no per-pipeline root signatures and no descriptor tables.
- Shaders include `lib/core/gpu/shaders/cinnabar.hlsli`. It declares push constants (`CN_PUSH_CONSTANTS`) at `b0`, pass constants (`CN_PASS_CONSTANTS`) at `b1`, and bindless accessors such as `cn_buffer` and `cn_texture`.

### Bindless indices

A bindless index is a fixed function of the handle's pool index: `gpu.read_index`, `gpu.write_index` and `gpu.sampler_index`. The game computes indices without a call to `core`, and an index never changes while the handle lives.

The resource heap has four ranges, in order: buffer reads, buffer writes, texture reads and texture writes. Each range has the capacity of its pool (`MAX_BUFFERS`, `MAX_TEXTURES`). Samplers use their pool index in the sampler heap. Vulkan descriptor arrays and Metal argument buffers can use the same fixed indices.

- Every buffer has a read view. Buffers with the `Storage` usage also have a write view.
- Textures with the `Sampled` usage have a read view. Textures with the `Storage` usage have a write view.
- Porting: DXC compiles `ResourceDescriptorHeap` to SPIR-V with descriptor indexing. `metal-shaderconverter` compiles DXIL to a metallib and implements the root signature as a top-level argument buffer.

### Vertex pulling

Pipelines have no input layout. Shaders read vertex data from byte-address buffers with `Load<T>`. Buffer views are raw, so structured buffers are not used. Index buffers are still supported.

## Resources

- **Handles:** resources are typed generational handles (`Buffer`, `Texture`, `Pipeline`, `Sampler`, `Accel_Struct`) into pools that `core` owns. A handle to a destroyed resource is detected.
- **Bindless indices:** see [Bindless indices](#bindless-indices).
- **Creation:** `create_*` returns the nil handle and logs an error if the description is invalid. The backend copies the description and the initial data, so neither can point into the DLL image after the call.
- **Initial data:** a buffer or texture created with data gets it through a staging buffer. The copies run before the command lists of the frame, so the resource is ready in the frame that creates it. Texture data is mip 0 with tightly packed rows.
- **Initial layout:** a texture starts in the layout of its first usage in this order: render target, depth stencil, storage, sampled. A texture created with data starts in the sampled layout. `gpu.initial_layout` gives the layout. The [render graph](#render-graph) takes over from there.
- **Deferred destruction:** `destroy` invalidates the handle at once. The backend releases the resource, and reuses the pool slot and its descriptors, when the GPU finishes the frame that destroyed it. Two frames are in flight.
- **Lifetime scopes:** each resource belongs to a scope: `Permanent`, `Level`, `Asset` or `Game`. On a soft restart (see [Hot reload](hot-reload.md#reload-sequence)), `core` destroys all `Game` resources and keeps the others.
- **Memory:** the first version uses committed resources. Suballocation is a later change inside the backend.
- **Upload ring:** `upload(size, align)` allocates CPU-written memory that is valid until the end of the frame. Each frame in flight has a 16 MB ring. An `Upload` holds the bytes, a buffer handle and an offset. Shaders read it through `read_index(upload.buffer)` at the offset, or as pass constants. Pass constants need `PASS_CONSTANTS_ALIGN` (256).

## Pipelines

- A pipeline description contains shader blobs, fixed-function state and attachment formats. D3D12 PSOs and Vulkan dynamic rendering both require the attachment formats.
- Pipeline kinds: graphics (vertex), graphics (mesh), compute and ray tracing.
- Pipelines are compiled on worker jobs. A pipeline handle is valid immediately. A draw with a pipeline that is not ready yet is skipped. Until the job system exists, `create_*_pipeline` compiles on the calling thread.
- Blending uses presets (`Opaque`, `Alpha`, `Premultiplied`, `Additive`), one per color target.

## Command buffers

The engine records commands into `Command_Buffer`s in frame memory.

- **Format:** a stream of packets. Each packet has a `{kind: u16, size: u16}` header and an inline payload. Push constants are part of the payload.
- **Plain data:** packets contain only handles, indices and POD data. Debug label strings are copied into frame memory. Packets never point into the DLL image (see [Hot reload](hot-reload.md#rules), rule 3).
- **Parallel recording:** each job records into its own `Command_Buffer`. A submission is an ordered list of command buffers for one queue.
- **Format hash:** `lib/core/gpu` is compiled into both the host and the game DLL. `Game_API` exports a hash of the packet layouts. If the hash differs from the host's, the host refuses the reload and asks for a restart.

### Pass rules

These rules come from Metal's encoder model. All backends enforce them.

- A pass begins and ends in the same command buffer. Debug markers also begin and end in the same command buffer, and they nest with passes.
- Draws occur only inside a render pass.
- Bindings reset at every pass boundary: the pipeline, pass constants and index buffer. Bind them again in each pass, and bind compute pipelines again after a pass. A render pass begins with the viewport and scissor set to the attachment size.
- A graphics pipeline's attachment formats must match the pass. A compute pipeline is bound only outside a pass.
- Copies, dispatches and acceleration structure builds occur only outside a render pass.
- A render pass declares its attachments with load and store operations. It maps to `BeginRenderPass` (D3D12), dynamic rendering (Vulkan) and a render command encoder (Metal).

### Barriers

- Barriers use the Enhanced Barriers model: sync stages (`Syncs`), access flags (`Accesses`) and texture layouts (`Texture_Layout`). This model maps one-to-one to Vulkan `synchronization2`. On Metal, most barriers become nothing or fences.
- `cmd_barriers` records buffer and texture barriers. Barriers occur only outside a render pass. A barrier covers the whole resource.
- An empty `Syncs` means no synchronization, and an empty `Accesses` means no access. A side with no synchronization has no access.
- `Undefined` as the layout before discards the contents, whatever the texture's layout is.
- The backend does not track resource states to translate barriers. State tracking would serialize parallel recording.
- Validation in debug builds and in the null backend tracks texture layouts. It rejects a barrier whose layout before is wrong, and a render pass whose attachments are not in the render target or depth write layout.
- **Frame boundary:** a frame starts after the GPU completes the work of the previous frame. A resource therefore needs no barrier for work in an earlier frame, only a layout change. The D3D12 backend executes each frame's work in one `ExecuteCommandLists` call. A Vulkan backend adds a full barrier at the start of each frame.
- The render graph in `lib/engine/render` records all barriers.

### Render graph

The game builds a `render.Graph` every frame in frame memory. Passes declare how they use each resource, and the graph computes the barriers.

- **Passes:** `add_render_pass` or `add_compute_pass`, in execution order. Each pass has a `Pass_Proc` that records its commands. The graph records the barriers, a debug marker with the pass name, and for a render pass `Begin_Pass` and `End_Pass`.
- **Uses:** `color` and `depth` declare attachments with load and store operations. `read` and `write` declare shader access to textures and buffers. `index_buffer` declares an index buffer. A pass can read a resource in several ways, but any other second use of the same resource in one pass is an error.
- **Imported resources:** `import_texture` and `import_buffer` add resources that outlive the frame. An imported texture has a resting use, and the graph returns it to that layout at the end of the frame. The frame target rests as `Color`. A texture created with data rests as `Sampled`.
- **Transient textures:** `create_texture` adds a texture that exists for one frame. The graph adds the usages that its uses need. A `Texture_Cache` in `Game_State` keeps the textures between frames, keyed by description and label, and destroys a texture after `CACHE_LIFETIME` frames without use.
- **Barriers:** a use needs a barrier when it changes the layout, when it follows a write, or when it writes after any access. Reads in the same layout merge without a barrier, so a later write waits for all of them. A transient texture starts `Undefined`, and sampling it before a pass writes it is an error.
- **Culling:** the graph walks the passes backward from the imported resources. A pass is live if it writes a resource that a later live pass reads, if it writes an imported resource, or if `keep_pass` marks it. A write that does not read (for example a clear) makes earlier writers of that resource unnecessary.
- **Handles:** graph handles are valid for one graph. In a `Pass_Proc`, `gpu_texture` and `gpu_buffer` return the `gpu` handles, because transient textures exist only after recording starts.
- **Execution:** `execute` records one command buffer and submits it. Phase 3 records passes on jobs.

## GPU-driven rendering

The engine culls and builds draws on the GPU. The interface supports this from the first version.

- **Indirect commands:** `draw_indirect`, `draw_indexed_indirect`, `draw_mesh_indirect` and `dispatch_indirect`. Each takes an argument buffer and an optional count buffer.
- **Draw ID:** each indirect argument record starts with a `u32` draw ID, followed by the standard arguments. Shaders read it with the `CN_DRAW_ID` macro. The D3D12 backend delivers it as a root constant in the command signature. The Vulkan backend delivers it as the `DrawIndex` built-in.
- **Async compute:** a submission targets the graphics, compute or copy queue. Cross-queue dependencies use timeline fences that the render graph declares.

## Mesh shaders

- Mesh and amplification shaders are HLSL and compile with the other shaders. They map to `VK_EXT_mesh_shader` and to Metal object and mesh shaders.
- A mesh pipeline replaces the vertex stage. All other pipeline state is the same.
- Fallback: the engine keeps a vertex-pulling path for devices without mesh shaders.

## Ray tracing

- **Acceleration structures** are a resource type. Builds and refits are commands, outside render passes. Build scratch memory comes from the backend.
- **Inline ray tracing first.** `RayQuery` in any shader stage maps to `VK_KHR_ray_query` and to Metal intersection queries. This is the main ray tracing path.
- **Ray tracing pipelines second.** Shader tables and `dispatch_rays` map to `VK_KHR_ray_tracing_pipeline`. Metal has no native equivalent, so a Metal backend may not report this capability. Effects must have an inline or raster fallback.

## Presentation

- The game renders into a frame target texture that `core` provides. The engine never sees a swapchain.
- The frame target is in the render target layout when the frame starts, and the game must leave it in that layout. Its contents are undefined at the start of each frame.
- `core` reads the window size once at the start of each frame. The frame target has that size, and `window_size` returns it for the whole frame. While the window is minimized, the size is zero and the game renders nothing.
- **Standalone:** `core` copies the frame target to the swapchain and presents with vsync. Vsync paces the frame.
- **Editor:** `core` renders into a shared texture and signals a shared fence instead (see [Editor](editor.md#viewport)).

## Submission

- `submit` translates each `Command_Buffer` into one native command list. Translation runs on worker jobs.
- Native command allocators are pooled per job, not per thread, because a fiber can resume on a different thread (see [Core](core.md#job-system)).

## Shaders

- Shaders are HLSL. `tools/cook` compiles each shader to DXIL with DXC. A Vulkan port adds SPIR-V from DXC. A Metal port adds a metallib from `metal-shaderconverter`.
- The cooker checks that each shader fits the fixed root signature. The runtime never compiles or reflects shaders.
- Until `tools/cook` exists, the build compiles shaders with DXC directly. `just install` downloads the DXC release that the justfile pins. `just shaders` compiles each `<name>.hlsl` in the game's `shaders/` directory: its `vs_main`, `ps_main` and `cs_main` entry points become `<name>.vs.dxil`, `<name>.ps.dxil` and `<name>.cs.dxil`.
- The game embeds the DXIL with `#load`. A hot reload therefore brings new shaders, and the game recreates its pipelines in `on_reload`.

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
| 7 | Editor shared texture. Async copy queue for asset streaming. Cooker-built shaders and pipelines. |

## Open questions

- **Passes across command buffers:** parallel recording (phase 3) will split one pass across jobs. This needs suspended and resumed passes (`SUSPENDING_PASS` and `RESUMING_PASS` in D3D12), or a parallel render encoder in Metal.
- **Asset resources on soft restart:** the asset runtime is game-side, but asset GPU resources must survive a soft restart. The asset runtime's handle tables must therefore live in host-owned memory.

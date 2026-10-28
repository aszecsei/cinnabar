# GPU

The backend-agnostic GPU interface in `lib/core/gpu`, the D3D12 backend, and the render graph that the engine builds on it.

## Documents

Read them in this order the first time.

| Document | What it covers |
|---|---|
| [Interface](interface.md) | The hardware floor, packages, backend selection and the bindless binding model. |
| [Resources and pipelines](resources-and-pipelines.md) | Handles, scopes, upload, and pipelines that compile in the background. |
| [Command buffers](command-buffers.md) | The packet format, pass rules, split passes, barriers, submission and debugging. |
| [Render graph](render-graph.md) | Passes, uses, barriers, transient and history textures, culling and queues. |
| [Queues, streaming and readback](queues-streaming-readback.md) | The graphics and compute queues, the copy queue, and readback. |
| [GPU-driven rendering and mesh shaders](gpu-driven-and-mesh-shaders.md) | Indirect draws with draw IDs, and the mesh shader path. |
| [Ray tracing](ray-tracing.md) | Acceleration structures, ray queries and ray tracing pipelines. |
| [Upscalers](upscalers.md) | Vendors' temporal upscalers, the upscale command, and FSR through the FidelityFX API. |
| [Presentation](presentation.md) | The frame target, output modes and shared mode. |
| [Shaders](shaders.md) | Cooked shaders and pipelines that follow them. |

## Overview

The interface is three layers. The engine sees only the first.

| Layer | Package | Files | What it holds |
|---|---|---|---|
| Interface | `lib/core/gpu` | `gpu.odin` | Handles (`Buffer`, `Texture`, `Pipeline`, `Sampler`, `Accel_Struct`, `Upscaler`), descriptions, enums, `Features`, `Output`, the bindless index functions, format and size helpers. |
| | | `command.odin` | The packet format, `Command_Buffer` and every `cmd_*` recording procedure, `Submission`, and the format hash. |
| | | `pool.odin` | `Pool`: the fixed-capacity generational handle table that every backend stores its resources in. |
| | | `validate.odin` | The command buffer validation and `Layout_Tracker`, which every backend runs in debug builds and the null backend always. |
| | | `shaders/cinnabar.hlsli` | The fixed root signature and the bindless accessors that every shader includes. |
| Backends | `lib/core/gpu/null` | `null.odin` | Validates and executes nothing. The test backend. |
| | `lib/core/gpu/d3d12` | `d3d12.odin` | The device, the queues and fences, `begin_frame`, `submit` and `end_frame`, the swapchain. |
| | | `resources.odin` | Buffers, textures, samplers, the descriptor heaps, deferred destruction, readback buffers. |
| | | `pipelines.odin` | The root signature, pipeline compilation on background jobs and versioning. |
| | | `translate.odin` | One `Command_Buffer` into one command list. |
| | | `uploads.odin` | The upload ring and the initial-data copies. |
| | | `streaming.odin` | The copy queue and transfers. |
| | | `accels.odin` | Acceleration structures and the scratch pool. |
| | | `upscalers.odin`, `ffx.odin` | Upscalers: FSR through the FidelityFX API, which it loads at run time. |
| | | `shared.odin` | Shared textures and fences for the editor's viewport and previews. |
| | | `display.odin` | The display's HDR state, luminances and SDR white. |
| Render graph | `lib/engine/render` | `graph.odin` | `Graph`: passes, uses, transient and history textures, barrier computation, culling, and parallel recording. Game side. |

**The path of a draw.** A pass's `Pass_Proc` records `cmd_*` calls into a `Command_Buffer` in frame memory, on a job. The render graph has already recorded that pass's barriers at the start of the buffer. The graph groups consecutive passes on one queue into a `Submission` and calls `gpu_submit` through `Platform_API`. The backend validates each buffer in debug builds, translates each into a native command list on its own job, and keeps the lists until `end_frame`, which executes the submissions in order with the fence waits between queues, presents the frame target, and marks the frame's upload ring and destroyed resources for release when the GPU passes the frame's fence. Nothing crosses the DLL boundary per draw, and the backend never looks at a resource's state to decide anything: the graph decided every barrier.

## References

- Microsoft, [*Enhanced Barriers*](https://microsoft.github.io/DirectX-Specs/d3d/D3D12EnhancedBarriers.html) (DirectX-Specs): the sync, access and layout model that [Barriers](command-buffers.md#barriers) adopts unchanged.
- Microsoft, [*DirectX 12 Agility SDK*](https://devblogs.microsoft.com/directx/directx12agility/): why the backend ships its own D3D12 runtime ([Hardware floor](interface.md#hardware-floor)).
- Microsoft, [*HLSL Shader Model 6.6 Dynamic Resources*](https://microsoft.github.io/DirectX-Specs/d3d/HLSL_SM_6_6_DynamicResources.html): `ResourceDescriptorHeap` and `SamplerDescriptorHeap`, the basis of the [Binding model](interface.md#binding-model).
- Microsoft, [*Indirect Drawing*](https://learn.microsoft.com/en-us/windows/win32/direct3d12/indirect-drawing) and command signatures: how the draw ID reaches shaders in [GPU-driven rendering](gpu-driven-and-mesh-shaders.md#gpu-driven-rendering).
- Microsoft, [*DirectX Raytracing (DXR) Functional Spec*](https://microsoft.github.io/DirectX-Specs/d3d/Raytracing.html): acceleration structures, `RayQuery`, state objects and shader tables ([Ray tracing](ray-tracing.md#ray-tracing)).
- Microsoft, [*Device Removed Extended Data (DRED)*](https://learn.microsoft.com/en-us/windows/win32/direct3d12/use-dred) and [*PIX on Windows*](https://devblogs.microsoft.com/pix/): the tools that [Debugging](command-buffers.md#debugging) targets.
- Microsoft, [DirectX Shader Compiler](https://github.com/microsoft/DirectXShaderCompiler): DXIL from HLSL ([Shaders](shaders.md#shaders)).
- Khronos, [`VK_KHR_synchronization2`](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_synchronization2.html), [`VK_KHR_dynamic_rendering`](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_dynamic_rendering.html), [`VK_EXT_mesh_shader`](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_mesh_shader.html), [`VK_KHR_ray_query`](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_ray_query.html): the Vulkan side of every mapping noted in these documents.
- Apple, [`MTLRenderCommandEncoder`](https://developer.apple.com/documentation/metal/mtlrendercommandencoder) and [`MTLParallelRenderCommandEncoder`](https://developer.apple.com/documentation/metal/mtlparallelrendercommandencoder): the encoder model behind [Pass rules](command-buffers.md#pass-rules) and [Split passes](command-buffers.md#split-passes).
- Yuriy O'Donnell, [*FrameGraph: Extensible Rendering Architecture in Frostbite*](https://www.gdcvault.com/play/1024612/FrameGraph-Extensible-Rendering-Architecture-in), GDC 2017: the declare-uses, cull, compute-barriers design of the [Render graph](render-graph.md#render-graph).
- Ulrich Haar and Sebastian Aaltonen, [*GPU-Driven Rendering Pipelines*](https://advances.realtimerendering.com/s2015/aaltonenhaar_siggraph2015_combined_final_footer_220dpi.pdf), SIGGRAPH 2015: indirect draws, GPU culling and vertex pulling ([GPU-driven rendering](gpu-driven-and-mesh-shaders.md#gpu-driven-rendering), [Vertex pulling](interface.md#vertex-pulling)).
- Christoph Kubisch, [*Introduction to Turing Mesh Shaders*](https://developer.nvidia.com/blog/introduction-turing-mesh-shaders/), NVIDIA: the amplification and mesh stage model of [Mesh shaders](gpu-driven-and-mesh-shaders.md#mesh-shaders).
- AMD, [*AMD FSR SDK*](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) and its [*FidelityFX API*](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/main/Kits/FidelityFX/docs/getting-started/ffx-api.md) and [*FSR upscaler*](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/main/Kits/FidelityFX/docs/techniques/super-resolution-upscaler.md) guides: the inputs, jitter and depth conventions of [Upscalers](upscalers.md#upscalers).
- SMPTE ST 2084 (PQ) and Rec. 2020: the HDR10 encoding of [Presentation](presentation.md#presentation); see also Microsoft, [*Using DirectX with high dynamic range displays*](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range).

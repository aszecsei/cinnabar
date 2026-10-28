# Interface

The hardware floor that every design rule follows from, the packages and how a backend is selected, and the bindless binding model with its fixed root signature. Read this before any other GPU document.

**In this document:** [Hardware floor](#hardware-floor) · [Adapter](#adapter) · [Packages](#packages) · [Binding model](#binding-model)

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

The engine checks `Features` before it uses a capability. Every capability must have a fallback path in the engine, or the engine must report that the device is not supported. The vendors' upscalers are optional the same way, but depend on the vendor's library as well as the device, so `gpu_upscalers` reports them apart (see [Upscalers](upscalers.md#upscalers)).

To test a fallback path on hardware that has the capability, set `CINNABAR_DISABLE_FEATURES` to a comma-separated list of `Feature` names, for example `CINNABAR_DISABLE_FEATURES=Mesh_Shaders`. `core` then hides those features from `gpu_features`. The null backend reports `Mesh_Shaders`, so it validates mesh pipelines and mesh draws.

## Adapter

`Platform_API.gpu_adapter` gives the device that the backend chose, as a `gpu.Adapter`, so the engine can pick defaults that suit it, such as the renderer's [quality](../rendering/quality.md#hardware-caps). It never decides what the engine can do: `Features` does that.

| Field | What it is |
|---|---|
| `vendor` | A `gpu.Vendor`, from the PCI vendor ID (`vendor_from_id`), or `Unknown` |
| `device_id` | The PCI device ID |
| `video_memory` | The adapter's own memory in bytes, or 0 when it is unknown or shared with the CPU |
| `name` | The adapter's name, UTF-8 with zeros after it; `adapter_name` gives it as a string |

- **D3D12** fills it from `DXGI_ADAPTER_DESC1` when it creates the device. The memory is `DedicatedVideoMemory`. How much of it the process may use now is `gpu.Stats.video_memory_budget`, which only the host reads.
- **The null backend** gives an adapter named `null` with no memory of its own.

## Packages

| Package | Side | Responsibility |
|---|---|---|
| `lib/core/gpu` | Both | Pure Odin. Handles, descriptions, enums, command packet definitions, `Command_Buffer` recording procedures, the format hash. |
| `lib/core/gpu/d3d12` | Host | The D3D12 backend. The only package that imports `vendor:directx`. |
| `lib/core/gpu/null` | Host | Validates command buffers and executes nothing. Used for headless tests. |
| `lib/engine/render` | Game | Render graph (barriers, pass culling, transient textures), frame setup, render extraction. |

The engine imports `lib/core/gpu` for types and recording only. It never imports a backend package.

**Backend selection:** `lib/core` imports the backend as `gpu_backend:.`. The build points the `gpu_backend` collection at one backend package, for example `-collection:gpu_backend=lib/core/gpu/d3d12`. In the justfile, set `gpu_backend` to choose the backend. Every backend package provides the same procedures: `init`, `shutdown`, `features`, `frame_target`, `begin_frame`, `submit`, `end_frame`, `upload`, `create_*` and `destroy_*` for buffers, textures, samplers, pipelines, acceleration structures and upscalers, `update_*_pipeline`, `accel_reference`, `upscalers`, `destroy_scope`, `stream_buffer`, `stream_texture`, `transfer_done`, `read_buffer`, and `stats`, the live resources and the memory for the editor's resource monitor, which only the host calls. `core` exposes them to the game as `gpu_*` fields of `Platform_API`.

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

- Every buffer but a `Readback` buffer has a read view (see [Readback](queues-streaming-readback.md#readback)). Buffers with the `Storage` usage also have a write view.
- Textures with the `Sampled` usage have a read view. Textures with the `Storage` usage have a write view.

### Vertex pulling

Pipelines have no input layout. Shaders read vertex data from byte-address buffers with `Load<T>`. Buffer views are raw, so structured buffers are not used. Index buffers are still supported.

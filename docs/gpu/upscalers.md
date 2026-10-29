# Upscalers

**In this document:** [Upscaling](#upscaling) · [FSR](#fsr)

A vendor's temporal upscaler as a resource type (`Upscaler`), which the backend runs through the vendor's library. Like temporal AA, it takes a jittered frame at a render size, with its depth and motion, and writes it at a larger output size with a history that it keeps itself. The engine uses it in temporal AA's place (see [Anti-aliasing](../rendering/anti-aliasing.md#fsr)).

- **Kinds:** `Upscaler_Kind` lists the vendors' upscalers: `Fsr` is the only one. `gpu_upscalers` gives the kinds that the device runs: the backend found the vendor's library, and the library runs on the device. An upscaler is optional, as a feature is, and the engine's own temporal AA is the fallback on every device.
- **Creation:** `gpu_create_upscaler` takes an `Upscaler_Desc`: the kind, the output size, the largest render size, at most the output's, and flags for the color and the depth (`Hdr`, `Depth_Reversed`, `Depth_Infinite`). The library compiles its pipelines before the call returns, which can take a moment, so the engine makes one only when the output size or the kind changes. The upscaler finds the exposure from the color itself.
- **Destruction:** `gpu_destroy_upscaler` invalidates the handle at once, and releases the library's context once the GPU has finished the frames that use it, as for every resource. Scopes destroy upscalers too.
- **Validation:** `validate_upscaler_desc` checks the sizes, and the null backend makes upscalers of every kind, so the engine's upscaling path runs in the tests as it does on a device.

## Upscaling

`cmd_upscale` records an `Upscale` packet: the upscaler, this frame's color, depth and motion, its masks if it has them, the output, the render size, and the frame's camera.

| Field | What it is |
|---|---|
| `color`, `depth`, `motion` | Sampled textures in the `Shader_Resource` layout, with the render size in their top left. Depth may have a stencil |
| `reactive`, `transparency` | Optional masks, nil or textures as `color` is, from 0 to 1 in their red channels, of what the motion does not follow, such as transparent surfaces and particles. Where `reactive` is high, the new color takes the history's place. `transparency` marks content that the history follows less well, such as reflections, where the upscaler trusts its history less, more gently |
| `output` | A storage texture of the upscaler's output size in the `Unordered_Access` layout |
| `jitter` | The camera's jitter in the render's pixels, y down: the projection moved the image by `2 * jitter / render_size` in x and `-2 * jitter / render_size` in y, in normalized device coordinates |
| `motion_scale` | Scales `motion`'s texels into the render's pixels, from where a pixel's surface is to where it was in the previous frame |
| `delta_time`, `near`, `far`, `fov_y` | Seconds since the previous frame, and the camera's planes and vertical field of view. `far` is unused with `Depth_Infinite` |
| `sharpness` | The upscaler's own sharpening, from 0, none, to 1 |
| `reset` | The history is not this frame's: a cut, the first frame, or a new render size |

- **Rules:** an upscale is compute work on the graphics queue, outside a render pass. Validation checks the textures' usages and sizes against the upscaler, the masks' too when they are given, and with layout tracking, their layouts. The render graph declares it as a compute pass that reads the inputs and the masks and writes the output, so its barriers are a dispatch's.
- **Bindings:** the library binds its own descriptor heaps, root signature and pipelines, so after an upscale no pipeline, push constants or pass constants are bound. The D3D12 backend binds its heaps and root signature again, and validation asks for a pipeline before the next dispatch.

## FSR

AMD FidelityFX Super Resolution through the FidelityFX API of the AMD FSR SDK (`lib/core/gpu/d3d12/upscalers.odin`, with the API's declarations in `ffx.odin`).

- **The library:** `just install` downloads the API's loader, `amd_fidelityfx_loader_dx12.dll`, and the upscalers' library, `amd_fidelityfx_upscaler_dx12.dll`, from the SDK's release that the justfile pins, and the build copies them next to the executables. Both are signed by AMD and MIT-licensed (see `vendor/fidelityfx/README.md`). The backend loads the loader with `LoadLibraryExW` from the default directories, so a missing file means no FSR, and asks it for the versions of FSR that the device runs. The loader picks the newest: FSR 4 on the GPUs that have it, and FSR 3.1 on the others.
- **A context per upscaler,** made with the HDR, depth and auto-exposure flags of the description. Debug builds turn on the API's checks. The API's messages reach the log once each, since it repeats a warning for every dispatch that it applies to.
- **Masks:** `reactive` is the API's reactive mask, and `transparency` its transparency and composition mask. A nil mask is no resource, which the API takes as none.
- **States:** the backend gives the inputs and the masks to the API in the read state that matches `Shader_Resource`, and the output in the unordered access state, which is where the graph's barriers left them. So the API issues no barriers on them, and leaves them as it found them.
- **Pre-exposure is 1:** the API takes it from the CPU, and the engine's exposure is on the GPU, so the color's pre-exposure changes reach FSR as changes in shading (see [Anti-aliasing](../rendering/anti-aliasing.md#fsr)).

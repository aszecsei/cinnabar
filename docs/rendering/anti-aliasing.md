# Anti-aliasing

**In this document:** [Upscaling](#upscaling) · [FSR](#fsr) · [FXAA](#fxaa) · [SMAA](#smaa) · [Future work](#future-work)

The [quality](quality.md#quality) chooses the anti-aliasing's technique (`Quality.aa`, an `Aa_Technique`), and the `Anti_Aliasing` settings on volumes or the editor's `Temporal_Aa` feature can turn it off, whichever technique it is (see [Settings](frame.md#settings) and [Debug views](post-processing.md#debug-views)). A view that is not shaded has none.

| Technique | Passes | Where in the frame | Cost | Looks |
|---|---|---|---|---|
| `Off` | None | | None | Jagged edges, and the ambient occlusion's noise shows: its denoiser takes a second pass |
| `Taa` | `temporal_aa.hlsl`, with the camera's jitter | First of the post passes, in linear HDR (see [Post-processing](post-processing.md#post-processing)) | One compute pass, and a history | The smoothest edges, inside a pixel too, and the noise of the ambient occlusion, GI and fog averaged; softer, and a trail where the history is wrong |
| `Fxaa` | `tone_map.hlsl`, `fxaa.hlsl` | After the lookup table, on the tone-mapped scene | Two compute passes | Smooth long edges from one frame; blurs fine texture a little, and a detail smaller than a pixel still flickers |
| `Smaa` | `tone_map.hlsl`, `smaa_edges.hlsl`, `smaa_weights.hlsl`, `smaa_blend.hlsl` | After the lookup table, on the tone-mapped scene | A compute pass and three full-screen passes | Sharper than FXAA, with corners and diagonals kept; the same flicker |
| `Fsr` | `upscale_motion.hlsl`, then AMD's FSR through the GPU interface, with the camera's jitter | In temporal AA's place | A compute pass, and FSR's own passes and history | Sharper than temporal AA in motion, and upscales from half the size with less loss; trails what has no motion, such as glass |

- **At a render scale below 1** (`Quality.render_scale`), temporal AA and FSR upscale the scene to the frame's size, and with the other techniques the output pass stretches it (see [Upscaling](#upscaling)).
- **The presets** take temporal AA: the frame's ambient occlusion, GI and fog are noisy, and expect temporal AA to average them. FXAA and SMAA suit a game that does not want the blur in motion, or a cheaper frame.
- **No jitter** without temporal AA or FSR, so FXAA and SMAA see the same pixels every frame.
- **FSR needs the device** to run it (`Caps.upscalers`): on others, `clamp_quality` gives temporal AA (see [Quality](quality.md#hardware-caps)).
- **Choosing:** both techniques' pipelines are synced whether or not the frame uses them (`sync_spatial_aa_pipelines`), so the quality can switch from one frame to the next. Until a technique's pipelines are compiled, the frame has no anti-aliasing.

**The tone map pass.** FXAA and SMAA find edges by luma, which they expect perceptual, so they run after tone mapping, where the display's colors are sRGB-encoded. Without them, the output pass tone maps the scene as it draws the frame target, and the frame has no extra pass. With them, the tone map pass (`tone_map.hlsl`) does what the output pass does first (bloom, the lookup table, a debug view's raw colors), into the `DISPLAY_FORMAT` (`RGBA16_Float`) scene, and the technique writes the result into `Frame.display`. The output pass then reads `Frame.display` (`Output_Push.tone_mapped`), and only blends the UI and the debug layer over it and encodes it, so neither is smoothed. Both passes take their tone mapping from `output.hlsli`, so the two paths give the same colors.

- **In HDR output** the display's colors are sRGB-encoded relative to paper white, above 1 for highlights. Both techniques read them as they are: their thresholds are relative to the brightest neighbor, and the extended sRGB curve stays perceptual above 1.

## Upscaling

`Quality.render_scale` is the share of the frame's width and height that the scene renders at, from `MIN_RENDER_SCALE` (0.5) to 1; 0 gives 1, and so does a value that is not a number. The UI stays at the frame's size, so it stays sharp. The presets render at full size.

| Size | What has it |
|---|---|
| `Frame.size`, the scene's: `render_size(Frame_Desc.size, render_scale)`, rounded, at least a pixel | The world's targets (scene color, depth, normals, velocity, IDs), every pass before temporal AA (the ambient occlusion, the GI, the fog's tiles, the clusters, the shadow mask, transparency, the debug views), the projection's aspect, the jitter, and the debug layer |
| `Frame.output_size`, the frame's: `Frame_Desc.size` | The frame target, the UI, and temporal AA's history |
| `Frame.scene_size`, `Frame.scene`'s | `Frame.size` until temporal AA, and `output_size` after it upscales. The exposure's histogram, bloom, the bloom composite, the tone map pass, FXAA and SMAA, and a game's post effects after temporal AA take it |

- **Temporal AA upscales** (TAAU): its history is at the frame's size, and `temporal_aa.hlsl` runs once for each of its pixels. The pixel takes this frame's color from the 3x3 scene pixels around the sample nearest to it, each weighted by `exp(-2.29 d²)`, d being the distance in output pixels from where its sample was taken (the pixel's center less the jitter) to the output pixel's center, Karis's fit of a Blackman-Harris window. It blends in `TEMPORAL_BLEND` times the nearest sample's weight, at least `MIN_BLEND_SHARE` (20%) of it: a pixel that a sample lands on takes more of this frame, and one between samples keeps more of its history. The neighborhood's clipping box, the velocity's dilation and the camera's motion take the same 3x3 pixels. At the frame's size, the pass does as it did before upscaling: the pixel's own sample, and `TEMPORAL_BLEND`.
- **Jitter:** the Halton sequence has `JITTER_SAMPLES` (8) points times the output's pixels for each of the scene's, rounded (32 at half size), so every output pixel gets samples near its center. The jitter is in the scene's pixels.
- **Without temporal AA,** `Frame.scene` stays at the scene's size, and so do the tone map pass and FXAA or SMAA after it. The output pass reads the scene, or `Frame.display`, bilinearly at each frame pixel's center, which at the same size is the pixel itself, and so stretches a smaller one.
- **The debug layer** is at the scene's size, with the depth that its tested lines and the editor's tools test against. The output pass stretches it as well, so at a scale below 1, debug lines and the editor's outline and gizmos are wider and softer.
- **Editor picks** are in the frame's pixels: `editor.add_viewport_passes` takes the scene's size and the frame's in its `Viewport_Frame`, and a pick covers the scene's pixels under its rectangle, at least one (see [Editor](../editor/viewport.md#viewport)).
- **FSR upscales** as temporal AA does, at every scale; its own history is at the frame's size (see [FSR](#fsr)).
- **Changing the scale** reallocates the scene's transient textures, and the histories start again, as on a resize.

## FSR

AMD FidelityFX Super Resolution, in temporal AA's place, through the GPU interface's upscalers (`lib/engine/render/upscalers.odin`; see [GPU: Upscalers](../gpu/upscalers.md#upscalers)). It is FSR 3.1 on most GPUs, and FSR 4 on the AMD GPUs that have it: the FidelityFX API picks the newest that the device runs.

1. **Motion** (`upscale_motion.hlsl`, `MOTION_FORMAT`, the velocity's format): FSR takes a motion for every pixel, and the prepass's velocity has none where it drew nothing, such as the sky and a game's own draws. There, the pass gives the motion of the point at the pixel's depth with the camera, as temporal AA finds it.
2. **Upscale:** `cmd_upscale` reads the scene, the depth and the motion at the scene's size, and writes the upscaled scene at the frame's, which becomes `Frame.scene`. The motion's scale is minus the scene's size, since FSR takes the way back to the previous frame in pixels, and the jitter is temporal AA's, in the scene's pixels with y down.

- **The upscaler** is made the first frame with FSR, for the frame's size, as both its output and its largest render size, so any render scale uses it, with linear HDR color and reversed, infinite depth (`frame_upscaler`). A frame of another size makes a new one, which compiles FSR's pipelines for a moment. If the device cannot make one, the error is logged once, and temporal AA stands in; it does too while the motion pass compiles.
- **The history starts again** (`Upscale.reset`) on the first frame with FSR after a frame without it, and when the render size changes.
- **The jitter** is temporal AA's Halton sequence, as long as FSR asks for: 8 times the output's pixels for each of the scene's.
- **The exposure:** FSR finds its own from the color (auto exposure), for its history's weights only, and gives back the color as it was. The scene is pre-exposed by the engine's exposure, which is on the GPU, so FSR's pre-exposure is 1, and a change in the exposure reaches it as a change in shading. The exposure adapts slowly, so this costs little.
- **The ambient occlusion's noise** changes from frame to frame with FSR, as with temporal AA, which averages it.
- **What has no motion:** glass and other transparent surfaces, and a game's own draws in the world pass, write no velocity, and FSR has no reactive mask for them, so they trail where they move. Temporal AA clips its history to the neighborhood, which hides more of it.
- **Messages:** in debug builds, FSR checks its inputs, and logs each warning once. It warns that a near plane as close as the sample's main scene's, 1 mm, may blur depth's edges.

## FXAA

`fxaa.hlsl` is the engine's own, after Lottes's FXAA 3.11 at its quality preset 39, as one compute pass (`lib/engine/render/spatial_aa.odin`).

1. **Edges:** a pixel is on an edge when the range of luma among it and its four neighbors is above `EDGE_THRESHOLD` (0.125) of the brightest, and above `EDGE_THRESHOLD_MIN` (0.0625), so dark noise stays as it is. Luma is `0.299 r + 0.587 g + 0.114 b` of the sRGB-encoded colors.
2. **Direction:** the edge is horizontal when the luma changes more from row to row than from column to column, with all eight neighbors. Its other side is the neighbor across it with the steeper change.
3. **Ends:** from halfway between the pixel and the other side, two searches step along the edge, 12 steps of 1 to 8 pixels, with bilinear samples that read both sides at once. Each stops where the luma leaves the edge's average by a quarter of the steeper change.
4. **Blend:** the pixel moves its sample across the edge by `0.5 - nearer / length` of a pixel, where the nearer end is, only when the luma there goes the way that the pixel's does. A pixel that differs from all its neighbors, a detail smaller than a pixel, moves at least by `SUBPIXEL` (0.75) times how much it differs, smoothed.

## SMAA

SMAA 1x is the reference implementation (Jimenez et al. 2012) at its High preset, `vendor/smaa/SMAA.hlsl` as it is, in three full-screen passes. `smaa.hlsli` gives it the bindless textures and samplers through `SMAA_CUSTOM_SL`, and a triangle that covers the screen. The cooker finds `SMAA.hlsl` in its include directories (`shader_tools` in the justfile).

1. **Edges** (`smaa_edges.hlsl`, `SMAA_EDGES_FORMAT`, `RG8_Unorm`): luma edges to the left and above, over a threshold of 0.1, which a larger neighboring contrast suppresses. The pass discards the pixels without an edge, over a cleared target.
2. **Weights** (`smaa_weights.hlsl`, `SMAA_WEIGHTS_FORMAT`, `RGBA8_Unorm`): at each edge, searches along it for its ends, up to 16 steps, and diagonally up to 8, with the search table. The ends' crossing edges give the shape, and the area table the share of the pixel on each side of the line that the shape stands for. Corners are rounded off by 25%.
3. **Blend** (`smaa_blend.hlsl`): each pixel blends with its neighbors by its and their weights, with one bilinear sample of the tone-mapped scene, into `Frame.display`.

- **The tables** are the reference's `AreaTex` (160x560, `RG8_Unorm`) and `SearchTex` (64x16, `R8_Unorm`), whose bytes are in `vendor/smaa/area.bin` and `vendor/smaa/search.bin` (see `vendor/smaa/README.md`). `spatial_aa_init` makes them with `#load`.
- **Samplers:** the post-processing's bilinear sampler, and a point sampler of the spatial AA's own.

## Future work

- **SMAA T2x:** SMAA with temporal AA's jitter and a history of two frames, sharper in motion than temporal AA. Needs the velocities that temporal AA reads, and SMAA's subsample indices by frame.
- **Levels for FXAA and SMAA**, with their presets' search steps and thresholds, if their cost shows in a profile. `Quality.aa` has no level now.
- **DLSS and XeSS** as `Aa_Technique`s beside FSR (see [Quality](quality.md#future-work)).
- **FSR's reactive mask** from the transparency pass's alpha, and its transparency mask, so glass and particles do not trail. FSR can make one from the scene with and without the transparency (`ffxDispatchDescUpscaleGenerateReactiveMask`).
- **FSR's exposure** from the engine's, as a 1x1 texture that FSR reads, in place of its auto exposure.
- **FSR's sharpening** (RCAS), which `Upscale.sharpness` already passes, as a setting.
- **A mip bias** for the materials' textures below full size, `log2(render_scale)`, so they keep the frame's detail once temporal AA upscales. Needs a bias in `gpu.Sampler_Desc`, and the material samplers made again when the scale changes.
- **Debug lines at the frame's size,** which needs the scene's depth there to test against.

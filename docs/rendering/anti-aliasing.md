# Anti-aliasing

**In this document:** [FXAA](#fxaa) · [SMAA](#smaa) · [Future work](#future-work)

The [quality](quality.md#quality) chooses the anti-aliasing's technique (`Quality.aa`, an `Aa_Technique`), and the `Anti_Aliasing` settings on volumes or the editor's `Temporal_Aa` feature can turn it off, whichever technique it is (see [Settings](frame.md#settings) and [Debug views](post-processing.md#debug-views)). A view that is not shaded has none.

| Technique | Passes | Where in the frame | Cost | Looks |
|---|---|---|---|---|
| `Off` | None | | None | Jagged edges, and the ambient occlusion's noise shows: its denoiser takes a second pass |
| `Taa` | `temporal_aa.hlsl`, with the camera's jitter | First of the post passes, in linear HDR (see [Post-processing](post-processing.md#post-processing)) | One compute pass, and a history | The smoothest edges, inside a pixel too, and the noise of the ambient occlusion, GI and fog averaged; softer, and a trail where the history is wrong |
| `Fxaa` | `tone_map.hlsl`, `fxaa.hlsl` | After the lookup table, on the tone-mapped scene | Two compute passes | Smooth long edges from one frame; blurs fine texture a little, and a detail smaller than a pixel still flickers |
| `Smaa` | `tone_map.hlsl`, `smaa_edges.hlsl`, `smaa_weights.hlsl`, `smaa_blend.hlsl` | After the lookup table, on the tone-mapped scene | A compute pass and three full-screen passes | Sharper than FXAA, with corners and diagonals kept; the same flicker |

- **The presets** take temporal AA: the frame's ambient occlusion, GI and fog are noisy, and expect temporal AA to average them. FXAA and SMAA suit a game that does not want the blur in motion, or a cheaper frame.
- **No jitter** without temporal AA, so FXAA and SMAA see the same pixels every frame.
- **Choosing:** both techniques' pipelines are synced whether or not the frame uses them (`sync_spatial_aa_pipelines`), so the quality can switch from one frame to the next. Until a technique's pipelines are compiled, the frame has no anti-aliasing.

**The tone map pass.** FXAA and SMAA find edges by luma, which they expect perceptual, so they run after tone mapping, where the display's colors are sRGB-encoded. Without them, the output pass tone maps the scene as it draws the frame target, and the frame has no extra pass. With them, the tone map pass (`tone_map.hlsl`) does what the output pass does first (bloom, the lookup table, a debug view's raw colors), into the `DISPLAY_FORMAT` (`RGBA16_Float`) scene, and the technique writes the result into `Frame.display`. The output pass then reads `Frame.display` (`Output_Push.tone_mapped`), and only blends the UI and the debug layer over it and encodes it, so neither is smoothed. Both passes take their tone mapping from `output.hlsli`, so the two paths give the same colors.

- **In HDR output** the display's colors are sRGB-encoded relative to paper white, above 1 for highlights. Both techniques read them as they are: their thresholds are relative to the brightest neighbor, and the extended sRGB curve stays perceptual above 1.

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
- **Upscalers** in `Aa_Technique`'s place when the scene renders below the frame's resolution (see [Quality](quality.md#future-work)).

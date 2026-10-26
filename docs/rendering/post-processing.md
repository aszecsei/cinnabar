# Post-processing

**In this document:** [Debug views](#debug-views) · [Post effects](#post-effects) · [Future work](README.md#future-work)

The post passes run after the `before_post` hook, in linear HDR at the scene's resolution (`lib/engine/render/post.odin`). The `Anti_Aliasing`, `Exposure`, `Tone_Mapping` and `Bloom` settings set them (see [Settings](frame.md#settings)). A pass whose pipeline is not compiled yet is left out, and the frame goes on without it: no jitter without temporal AA, and a plain roll-off to white until the lookup table is baked.

| Pass | Method | Inputs | Output |
|---|---|---|---|
| Temporal AA | Reprojection by velocity, a Catmull-Rom history, clipping to the neighborhood's colors; an upscaler later | Scene color, velocity, depth, history | Its history texture, which becomes `Frame.scene` |
| Exposure | A luminance histogram, then the exposure that maps its average to middle grey | Scene color, depth | The exposure buffer, which pre-exposes the next frame |
| Bloom | A chain of downsamples with a 13-tap filter, and upsamples with a 3x3 tent | Scene color | `Frame.bloom` |
| Tone mapping | A lookup table that a compute pass bakes when the settings change: the color grading and the curve (AgX by default; Khronos PBR Neutral, ACES); the output pass reads it | Scene color, bloom | sRGB-encoded colors, or PQ-encoded nits in [HDR output](layers-and-output.md#hdr-output) |

- **Jitter.** With temporal AA, the camera's projection moves within the pixel every frame, through the first 8 points of the Halton (2, 3) sequence (`Frame.jitter`, in normalized device coordinates). The camera's and the view model's views draw with it, the velocities leave it out, and `jittered_view_projection` gives it to a game's own draws. The debug layer and the editor's tools draw without it. The ID buffer is jittered with the scene, so the editor's selection outline can move by a pixel at edges from frame to frame.
- **Temporal AA** (`temporal_aa.hlsl`, a compute pass) takes each pixel's motion from the nearest of its 3x3 neighbors, so edges move with the surface in front. Where the prepass drew nothing (`VELOCITY_NONE`), the pixel moves with the camera: its depth gives its position, which moves by the camera's motion (`Frame.camera_motion`) into last frame's projection (`Frame.previous_view_projection`). The history is read with a Catmull-Rom filter in five bilinear taps, scaled by the ratio of this frame's exposure to last frame's, and clipped to the neighborhood's mean ± 1.25 standard deviations in YCoCg. Then 10% of this frame (`TEMPORAL_BLEND`) blends in, after a reversible tone map, so one bright sample does not dominate. Without a valid history, or where last frame's position is off the screen, the pixel is this frame's color.
- **History textures:** `history_texture` in the render graph gives a pair of textures that the `Texture_Cache` keeps and swaps every frame, for temporal AA, the global illumination and the fog now, and later for the denoisers (see [GPU](../gpu/render-graph.md#render-graph)). Last frame's is not valid in the first frame, after a frame that did not use it, or when the view's size changes.
- **Pre-exposure.** The forward pass multiplies its colors by the exposure, so the scene holds `radiance × exposure`, inside the half-float range at any brightness. The exposure is in a buffer of two floats (`Post.exposure`): this frame's, then last frame's. The exposure pass writes the next frame's after the scene is drawn, so the exposure lags a frame, and temporal AA rescales the history by the ratio. A game's own draws in the world pass read it too. The clear color is not pre-exposed.
- **Exposure.** With `Auto`, the histogram (`exposure_histogram.hlsl`) counts each pixel's luminance, without pre-exposure, into 256 bins of log2 luminance from -12 to 8. Pixels where nothing drew hold the clear color, which is not pre-exposed, so they do not count; otherwise the exposure would chase its own scale. The exposure pass (`exposure_adapt.hlsl`) takes the mean log2 luminance between the 10th and the 90th percentiles, clamps it to `exposure_range` (`DEFAULT_EXPOSURE_RANGE`, -8 to 4), and aims at `0.18 / average × 2^exposure_compensation`. It goes `1 - e^(-speed × seconds)` of the way there in a frame (`adaptation_speed`, `DEFAULT_ADAPTATION_SPEED`), and all the way in the first frame. With `Manual`, the exposure is `exposure × 2^exposure_compensation`, at once. Both passes run on the graphics queue: on the compute queue, the next frame's forward pass would need the graph to order the exposure buffer across frames.
- **Bloom** halves the scene at most `BLOOM_LEVELS` (6) times, while each side stays at least `BLOOM_MIN_SIZE` (8) pixels. The first downsample weighs each of the filter's five boxes by `1 / (1 + luminance)`, so a single bright pixel does not flicker as it moves. Then, from the smallest level up, each level adds the level below it, blurred with a 3x3 tent. The output pass adds the largest level: `scene × (1 - intensity) + bloom × intensity / levels`, with `bloom_intensity` 0.04 by default (`DEFAULT_BLOOM_INTENSITY`).
- **The lookup table** (`tone_lut.hlsl`, `tone_lut.hlsli`) has 32 entries on each axis, its blue slices side by side in one 1024x32 `RGBA16_Float` texture, since textures are 2D. The entries cover -12.5 to +8 stops around middle grey on a log2 scale, so a scene color in any range has a place. Each holds the display color of its scene color, sRGB-encoded: the tint, the saturation and the contrast (`tint`, `saturation`, `contrast`), then the tone mapper. A compute pass bakes it in the first frame, and again when the grading or its shader changes. The output pass reads it with two bilinear samples. AgX rolls bright colors off to white with less saturation than Khronos PBR Neutral, and keeps dark colors a little brighter, so `tone_mapper = .Pbr_Neutral` gives the look that the fixed tone mapper had before.
- *Later:* an upscaler in place of temporal AA, the exposure on the compute queue, a sky that counts in the histogram once it is pre-exposed, and velocities for a game's own draws.

## Debug views

The editor shows what makes the frame in its viewport (see [Editor](../editor/viewport.md#viewport)): `Frame_Desc.debug_view` replaces the lit scene, `Frame_Desc.disable` turns features off, and `Frame_Desc.exposure_offset` adds stops to the exposure. A game passes them from the editor while it edits, and leaves them zero otherwise (`lib/engine/render/debug_views.odin`).

| View | Drawn by | Shows | Shaded |
|---|---|---|---|
| `Lit` | The forward pass | The scene | Yes |
| `Lighting_Only` | The forward pass | The lighting on a grey base color, without emission | Yes |
| `Direct_Light`, `Indirect_Light` | The forward pass | Only the lights' light, or only the indirect light | Yes |
| `Fog` | The forward pass | Only the light that the fog scatters toward the camera | Yes |
| `Albedo` | The forward pass | The base color, or an unlit surface's color | No |
| `Light_Complexity` | The forward pass | The lights that shade each pixel, as heat colors up to 16 | No |
| `Shadow_Cascades` | The forward pass | Each directional cascade in its color: red, green, blue, yellow, then grey beyond | No |
| `Normals`, `Depth`, `Velocity` | `debug_view.hlsl` | The prepass's: the world normal, the depth on a log scale to 1 km, the motion with grey where nothing moved | No |
| `Ambient_Occlusion`, `Shadow_Mask` | `debug_view.hlsl` | The occlusion, and each traced light's mask channel in its own color | No |
| `Gi_Diffuse`, `Gi_Specular` | `debug_view.hlsl` | The global illumination's light | Yes |
| `Entity_Ids` | `debug_view.hlsl` | Each entity in a color of its own | No |
| `Luminance` | `debug_view.hlsl` | The scene's EV100 as heat colors, from -4 to 16 | No |
| `Transparent_Overdraw` | `debug_view.hlsl` | The transparent layers at each pixel, which the moments pass counts, as heat colors from 1 to 8 | No |

- **In the forward pass:** `Frame_Constants.debug_view` drives a dynamic branch in the forward template, so the views need no permutations. The cooker defines `SHADING_HAS_BASE_COLOR` for a shading model with a `float3 base_color` input.
- **From the frame's textures:** a compute pass after the `before_post` hook writes the view into a new scene color. A texture that the frame does not have, such as the global illumination's when it is off, gives black.
- **Shaded views** are exposed and tone mapped as the scene is. The others are colors as they are: the output pass only encodes them (`Output_Push.raw`), they have no temporal AA, jitter or fog, and the exposure stays where it was, so the lit scene comes back as it was. Only `Lit` has bloom and the game's [post effects](#post-effects).
- **Features** (`Features`) the viewport can turn off: temporal AA, bloom, the tone mapping (a plain roll-off to white in its place), the fog, the ambient occlusion, the global illumination, the shadows and the game's post effects. They change the settings after `resolve_settings`, so a volume cannot turn them back on.

## Post effects

A game adds its own post effects among the renderer's passes (`lib/engine/render/post_effects.odin`). Each is driven by a settings component on [volumes](../world/volumes.md#volumes), as the renderer's settings are, so the editor shows it on a volume, and a volume turns it on where it reaches.

- **Registering:** `register_post_effect(&renderer, &world, name, point, T, add, order)` after `renderer_init` and again after `renderer_reload`, which clears the effects, because their procedures were in the old code. `T` is a settings component, registered with its defaults (see [Volumes](../world/volumes.md#volumes)), which the volumes blend from. At most `MAX_POST_EFFECTS` (16).
- **Points:** `Before_Temporal_Aa`, after the `before_post` hook; `After_Temporal_Aa`, before the exposure's histogram and bloom, so an effect changes both; and `Before_Tone_Mapping`, in linear HDR just before the output pass. The renderer's own passes keep their order. At a point, effects run by `order`, then in the order that they registered.
- **When an effect runs:** where a volume with its component reaches the camera. Its procedure gets the `Frame` and its settings, blended from the volumes there. It reads `Frame.scene`, and a pass that makes a new scene color sets `Frame.scene` to it. `Frame.data` is the hooks' data. An effect whose pipeline is not ready (`pipeline_ready`) should add nothing, as the renderer's own passes do.
- **Bloom first:** before the effects at `Before_Tone_Mapping`, a composite pass (`bloom.hlsl`'s composite mode) adds bloom into a new scene color, as the output pass would, so the effects see the scene as the display will. The output pass then adds no bloom. Without an effect there, the frame has no composite pass.
- **The sample's lens** (`Lens`, stable ID 1003, and `lens.hlsl`): chromatic aberration and a vignette at `Before_Tone_Mapping`, on the sample scene's Global Volume. Before, the sample did them in its `after_world` pass, before temporal AA. That pass now only multiplies in its triangles' shadows.

## Future work

- **An upscaler** in place of temporal AA, so the scene renders below the frame's resolution and the UI stays sharp. The layers already keep the UI at the frame target's size, and the output pass then reads a separate tone-mapped scene, upscaled to the frame's size.
- **The exposure on the compute queue.** Needs the graph to order the exposure buffer across frames, since the next frame's forward pass reads it.
- **Velocities for a game's own draws**, so temporal AA stops trailing them. Transparent surfaces have the same gap.
- **Depth of field** that leaves the view model's pixels sharp, by their stencil bit.
- **HDR output:** HDR10 metadata for the swapchain, a UI scale for its brightness separate from the scene's paper white, and a calibration screen for the peak and paper white.
- **Debug text** in the debug API, beside the line shapes.

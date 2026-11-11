# Post-processing

**In this document:** [Bloom](#bloom) · [Debug views](#debug-views) · [Post effects](#post-effects)

The post passes run after the `before_post` hook, in linear HDR at the scene's resolution (`lib/engine/render/post.odin`). The `Anti_Aliasing`, `Exposure`, `Tone_Mapping` and `Bloom` settings set them (see [Settings](frame.md#settings)), and the [quality](quality.md#quality) chooses the anti-aliasing: temporal AA or FSR here, or FXAA or SMAA after the lookup table (see [Anti-aliasing](anti-aliasing.md#anti-aliasing)). A pass whose pipeline is not compiled is left out, and the frame goes on without it: no jitter without temporal AA or FSR, and a plain roll-off to white until the lookup table is baked.

| Pass | Method | Inputs | Output |
|---|---|---|---|
| Temporal AA | Reprojection by velocity, a Catmull-Rom history, clipping to the neighborhood's colors; upscales a smaller scene to the frame's size (see [Upscaling](anti-aliasing.md#upscaling)) | Scene color, velocity, depth, history | Its history texture, which becomes `Frame.scene` |
| FSR, in temporal AA's place | The motion pass, then AMD's FSR (see [Anti-aliasing](anti-aliasing.md#fsr)) | Scene color, velocity, depth | The upscaled scene, which becomes `Frame.scene` |
| Exposure | A luminance histogram, then the exposure that maps its average to middle grey | Scene color, depth | The exposure buffer, which pre-exposes the next frame |
| Bloom | A chain of downsamples with a 13-tap filter, and upsamples that blend each level with the one below by a radius (see [Bloom](#bloom)) | Scene color | `Frame.bloom` |
| Tone mapping | A lookup table that a compute pass bakes when the settings change: the color grading and the curve (AgX by default; Khronos PBR Neutral, ACES); the output pass reads it, or with FXAA or SMAA, the tone map pass before them | Scene color, bloom | sRGB-encoded colors, or PQ-encoded nits in [HDR output](layers-and-output.md#hdr-output) |
| FXAA or SMAA | See [Anti-aliasing](anti-aliasing.md#anti-aliasing) | The tone-mapped scene | `Frame.display`, which the output pass reads |

- **Jitter.** With temporal AA or FSR, the camera's projection moves within the pixel every frame, through the first 8 points of the Halton (2, 3) sequence (`Frame.jitter`, in normalized device coordinates). The camera's and the view model's views draw with it, the velocities leave it out, and `jittered_view_projection` gives it to a game's own draws. The debug layer and the editor's tools draw without it. The ID buffer is jittered with the scene, so the editor's selection outline can move by a pixel at edges from frame to frame.
- **Temporal AA** (`temporal_aa.hlsl`, a compute pass) takes each pixel's motion from the nearest of its 3x3 neighbors, so edges move with the surface in front. Where the prepass drew nothing (`VELOCITY_NONE`), the pixel moves with the camera: its depth gives its position, which moves by the camera's motion (`Frame.camera_motion`) into last frame's projection (`Frame.previous_view_projection`). The history is read with a Catmull-Rom filter in five bilinear taps, scaled by the ratio of this frame's exposure to last frame's, and clipped to the neighborhood's mean ± 1.25 standard deviations in YCoCg. Then 10% of this frame (`TEMPORAL_BLEND`) blends in, after a reversible tone map, so one bright sample does not dominate. Without a valid history, or where last frame's position is off the screen, the pixel is this frame's color.
- **History textures:** `history_texture` in the render graph gives a pair of textures that the `Texture_Cache` keeps and swaps every frame, for temporal AA, the global illumination and the fog (see [GPU](../gpu/render-graph.md#render-graph)). Last frame's is not valid in the first frame, after a frame that did not use it, or when the view's size changes.
- **Pre-exposure.** The forward pass multiplies its colors by the exposure, so the scene holds `radiance × exposure`, inside the half-float range at any brightness. The exposure is in a buffer of two floats (`Post.exposure`): this frame's, then last frame's. The exposure pass writes the next frame's after the scene is drawn, so the exposure lags a frame, and temporal AA rescales the history by the ratio. A game's own draws in the world pass read it too. The clear color is not pre-exposed. Each [view](frame.md#views) has an exposure buffer of its own, in its `View_State` (`Post_State.exposure`), with its own adaptation, jitter and upscaler.
- **Exposure.** With `Auto`, the histogram (`exposure_histogram.hlsl`) counts each pixel's luminance, without pre-exposure, into 256 bins of log2 luminance from -12 to 8. Pixels where nothing drew count when the `Atmosphere` or `Texture` sky drew them, pre-exposed (see [Sky](sky.md#modes)). Otherwise they hold the clear color, which is not pre-exposed, so they do not count; the exposure would chase its own scale. The exposure pass (`exposure_adapt.hlsl`) takes the mean log2 luminance between the 10th and the 90th percentiles, clamps it to `exposure_range` (`DEFAULT_EXPOSURE_RANGE`, -8 to 4), and aims at `0.18 / average × 2^exposure_compensation`. It goes `1 - e^(-speed × seconds)` of the way there in a frame (`adaptation_speed`, `DEFAULT_ADAPTATION_SPEED`), and all the way in the first frame. With `Manual`, the exposure is `exposure × 2^exposure_compensation`, at once. Both passes run on the graphics queue: on the compute queue, the next frame's forward pass would need the graph to order the exposure buffer across frames.
- **Bloom** halves the scene up to 8 times and blends the levels back up by `bloom_radius`; the output pass adds the result with `bloom_intensity` (see [Bloom](#bloom)).
- **The lookup table** (`tone_lut.hlsl`, `tone_lut.hlsli`) has 32 entries on each axis, its blue slices side by side in one 1024x32 `RGBA16_Float` texture, since textures are 2D. The entries cover -12.5 to +8 stops around middle grey on a log2 scale, so a scene color in any range has a place. Each holds the display color of its scene color, sRGB-encoded: the tint, the saturation and the contrast (`tint`, `saturation`, `contrast`), then the tone mapper. A compute pass bakes it in the first frame, and again when the grading or its shader changes. The output pass reads it with two bilinear samples. AgX rolls bright colors off to white with less saturation than Khronos PBR Neutral, and keeps dark colors a little brighter, so `tone_mapper = .Pbr_Neutral` gives the look that the fixed tone mapper had before.

## Bloom

Bloom is the glow around bright light (`bloom.hlsl`, compute passes on the graphics queue). The `Bloom` settings give its `intensity`, 0.04 by default (`DEFAULT_BLOOM_INTENSITY`), and its `radius`, 0 to 1, 0.75 by default (`DEFAULT_BLOOM_RADIUS`).

- **Down:** the chain halves the scene while the shorter side is at least `BLOOM_MIN_SIZE` (4) pixels, up to `BLOOM_LEVELS` (8) times (`bloom_chain`): at 1080p from 960x540 to 7x4, at 1440p to 10x5. Each level is a 13-tap filter of the one before, five overlapping boxes of bilinear taps (Jimenez). The first weighs each box by `1 / (1 + luminance)`, so a single bright pixel does not flicker as it moves.
- **Up:** from the smallest level up, each level becomes `lerp(level, upsample(below), radius)`. Level k's share of the result is `(1 - radius) × radius^k`, and the smallest level's `radius^7`, so the shares sum to 1 and the result is as bright as the scene. At 0 the result is the largest level alone, which adds almost no glow; at 1 it is the smallest level alone, a haze across much of the screen.
- **The upsample** reads a level whose shorter side is under `BLOOM_BICUBIC_SIZE` (16) pixels with Catmull-Rom in five bilinear taps (`sample_catmull_rom` in `filter.hlsli`, which temporal AA's history shares), and the others with a 3x3 tent. At 1080p that is the 15x8 and 7x4 levels. A large radius spreads those few texels over the screen; Catmull-Rom keeps their glow around the light where the tent smears it outward. At radius 1, the glow 64 to 128 pixels from mygame's hologram at night is 10.3 codes over the scene with Catmull-Rom against 6.4 with the tent. Neither showed blocks at 1080p.
- **The output pass** adds the largest level: `scene × (1 - intensity) + bloom × intensity`, or the composite does, before a game's [post effects](#post-effects).

**The default radius.** The chain had 6 levels to a side of 8 pixels, and the output divided their sum by the level count, so every level weighed a sixth. No single radius gives equal weights, so 0.75 is the radius whose glow of a single bright pixel at 1080p comes nearest the old one: a simulation of both chains (13-tap down, tent or Catmull-Rom up) put the root mean square difference of their encircled energy, at radii 1 to 256 pixels, at 0.071, against 0.097 at 0.7 and 0.098 at 0.8. Measured in mygame's glass scene at 1920x1080, as the mean luma (0 to 255) that bloom adds in rings around the light against a capture without bloom:

| Rings (pixels) | 4-8 | 8-16 | 16-32 | 32-64 | 64-128 | 128-256 | 256-512 |
|---|---|---|---|---|---|---|---|
| The sun's disc, 6 levels before | 93.2 | 107.5 | 79.9 | 41.3 | 12.9 | 1.5 | 0.0 |
| The sun's disc, radius 0.75 | 93.1 | 104.6 | 67.9 | 27.8 | 8.8 | 3.1 | 0.9 |
| The sun's disc, radius 0 | 61.4 | 1.8 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| The sun's disc, radius 1 | 11.4 | 12.1 | 12.2 | 12.2 | 12.4 | 11.9 | 5.7 |
| The hologram at night, 6 levels before | 0.0 | 0.0 | 0.0 | 2.2 | 9.4 | 6.4 | 0.9 |
| The hologram at night, radius 0.75 | 0.0 | 0.0 | 0.0 | 1.7 | 7.5 | 6.5 | 3.2 |
| The hologram at night, radius 0 | 0.0 | 0.0 | 0.0 | 0.4 | 0.3 | 0.2 | 0.0 |
| The hologram at night, radius 1 | 0.0 | 0.0 | 0.0 | 1.1 | 10.3 | 14.4 | 15.4 |

The core is the same, the middle a little fainter and the edge a little wider; side by side, the two look alike.

**Eight levels against six.** With the blend and 6 levels, the glow at radius 0.75 ends near 256 pixels (1.0 at 256-512 around the hologram, against 3.2 with 8), and at radius 1 it stays around the light (18.8 at 64-128 and 3.1 at 256-512, against 10.3 and 15.4 with 8). Cost on an RTX 5090 with D3D12 at 1920x1080, the median of five 250 ms summaries:

| Chain | Down | Up | Bloom |
|---|---|---|---|
| 6 levels, the sum over the level count (before) | 27.7 us | 23.1 us | 50.8 us |
| 6 levels, the blend | 27.8 us | 23.9 us | 51.7 us |
| 8 levels, the blend | 33.4 us | 30.0 us | 63.4 us |

The two smallest levels are a few hundred pixels each, so their cost is two passes of overhead each way. The radius does not change it.

## Debug views

The editor shows what makes the frame in its viewport (see [Editor](../editor/viewport.md#viewport)): `Frame_Desc.debug_view` replaces the lit scene, `Frame_Desc.disable` turns features off, and `Frame_Desc.exposure_offset` adds stops to the exposure. A game passes them from the editor while it edits, and leaves them zero otherwise (`lib/engine/render/debug_views.odin`).

| View | Drawn by | Shows | Shaded |
|---|---|---|---|
| `Lit` | The forward pass | The scene | Yes |
| `Lighting_Only` | The forward pass | The lighting on a grey base color, without emission | Yes |
| `Direct_Light`, `Indirect_Light` | The forward pass | Only the lights' light, or only the indirect light | Yes |
| `Fog` | The forward pass | Only the light that the fog and the [air](sky.md#aerial-perspective) scatter toward the camera | Yes |
| `Albedo` | The forward pass | The base color, or an unlit surface's color | No |
| `Light_Complexity` | The forward pass | The lights that shade each pixel, as heat colors up to 16 | No |
| `Shadow_Cascades` | The forward pass | Each directional cascade in its color: red, green, blue, yellow, then grey beyond | No |
| `Shadow_Virtual` | The forward pass | The [virtual shadow map](lighting-and-shadows.md#virtual-shadow-maps)'s level at each pixel in a color of its own, half red where it fell back to a coarser level, magenta where it found no page, and grey without a virtual shadow map | No |
| `Reflection_Probes` | The forward pass | The [reflection probe](lighting-and-shadows.md#reflection-probes) that counts the most at each pixel, by its cube, in a color of its own, red where none counts | No |
| `Normals`, `Depth`, `Velocity`, `Roughness` | `debug_view.hlsl` | The prepass's: the world normal, the depth on a log scale to 1 km, the motion with grey where nothing moved, and the roughness from black, smooth, to white, rough, white where nothing drew (see [Prepass](lighting-and-shadows.md#prepass)) | No |
| `Ambient_Occlusion`, `Shadow_Mask` | `debug_view.hlsl` | The occlusion, and each traced light's mask channel in its own color, or in a frame that does not trace, the sun's [contact shadows](lighting-and-shadows.md#shadows) in red | No |
| `Gi_Diffuse`, `Gi_Specular` | `debug_view.hlsl` | The global illumination's light | Yes |
| `Reflections` | `debug_view.hlsl` | The [screen-space reflections](lighting-and-shadows.md#screen-space-reflections)' light times their weight: black where the probes take over, and black without them | Yes |
| `Clouds` | `debug_view.hlsl` | The [clouds](clouds.md#passes)' history over black: their light, a texel for each block of pixels of the cloud buffer, and black without them | Yes |
| `Entity_Ids` | `debug_view.hlsl` | Each entity in a color of its own | No |
| `Luminance` | `debug_view.hlsl` | The scene's EV100 as heat colors, from -4 to 16 | No |
| `Transparent_Overdraw` | `debug_view.hlsl` | The transparent layers at each pixel, sprites included, which the moments passes count, as heat colors from 1 to 8 | No |
| `Meshlets`, `Lod_Depth` | The forward pass | The [mesh shader path](gpu-scene.md#mesh-shader-path)'s meshlets, and the [patch surfaces](surfaces.md#patches)' patches, each in a color of its own, and their levels of detail as heat colors up to 8, which an [impostor](gpu-scene.md#impostors) is | No |
| `Emission` | The forward pass | The shading model's emission alone, of opaque and transparent surfaces (see [Materials](materials.md#shading-models)) | Yes |
| `Quad_Overdraw` | The forward pass's quad counts, then `debug_view.hlsl` | The times that the forward pass shaded each 2x2 quad of the screen, as heat colors from 1 to 4, helper lanes included (see [Quad overdraw](lighting-and-shadows.md#quad-overdraw)) | No |
| `Gi_Probes` | The [split cascades](global-illumination.md#split-cascades)' gather, then `debug_view.hlsl` | The first cascade's probe of each pixel's cell at its nearer level: each in a color of its own, as bright as its confidence, red where the cell has no probe, and grey past the last level or without a surface. Black without the split cascades | No |

- **In the forward pass:** `Frame_Constants.debug_view` drives a dynamic branch in the forward template, so the views need no permutations. The cooker defines `SHADING_HAS_BASE_COLOR` for a shading model with a `float3 base_color` input.
- **From the frame's textures:** a compute pass after the `before_post` hook writes the view into a new scene color. A texture that the frame does not have, such as the global illumination's when it is off, gives black.
- **Shaded views** are exposed and tone mapped as the scene is. The others are colors as they are: the output pass only encodes them (`Output_Push.raw`), they have no anti-aliasing, jitter or fog, and the exposure stays where it was, so the lit scene comes back as it was. Only `Lit` has bloom and the game's [post effects](#post-effects).
- **Features** (`Features`) the viewport can turn off: the anti-aliasing (`Temporal_Aa`, which turns off every technique), bloom, the tone mapping (a plain roll-off to white in its place), the fog, the ambient occlusion, the global illumination, the shadows, the game's post effects, occlusion culling, the meshlet hierarchy, and the [clouds](clouds.md#clouds) with their shadow. They change the settings after `resolve_settings`, so a volume cannot turn them back on.

## Post effects

A game adds its own post effects among the renderer's passes (`lib/engine/render/post_effects.odin`). Each is driven by a settings component on [volumes](../world/volumes.md#volumes), as the renderer's settings are, so the editor shows it on a volume, and a volume turns it on where it reaches.

- **Registering:** `register_post_effect(&renderer, &world, name, point, T, add, order)` after `renderer_init` and again after `renderer_reload`, which clears the effects, because their procedures were in the old code. `T` is a settings component, registered with its defaults (see [Volumes](../world/volumes.md#volumes)), which the volumes blend from. At most `MAX_POST_EFFECTS` (16).
- **Points:** `Before_Temporal_Aa`, after the `before_post` hook; `After_Temporal_Aa`, before the exposure's histogram and bloom, so an effect changes both; and `Before_Tone_Mapping`, in linear HDR just before the output pass. The renderer's own passes keep their order. At a point, effects run by `order`, then in the order that they registered.
- **When an effect runs:** where a volume with its component reaches the camera. Its procedure gets the `Frame` and its settings, blended from the volumes there. It reads `Frame.scene`, whose size is `Frame.scene_size`, the frame's once temporal AA or FSR has upscaled it (see [Upscaling](anti-aliasing.md#upscaling)), and a pass that makes a new scene color sets `Frame.scene` to it, at that size. `Frame.data` is the hooks' data. An effect whose pipeline is not ready (`pipeline_ready`) should add nothing, as the renderer's own passes do.
- **Bloom first:** before the effects at `Before_Tone_Mapping`, a composite pass (`bloom.hlsl`'s composite mode) adds bloom into a new scene color, as the output pass would, so the effects see the scene as the display will. The output pass then adds no bloom. Without an effect there, the frame has no composite pass.
- **The sample's lens** (`Lens`, stable ID 1003, and `lens.hlsl`): chromatic aberration and a vignette at `Before_Tone_Mapping`, on the sample scene's Global Volume. Before, the sample did them in its `after_world` pass, before temporal AA. That pass now only multiplies in its triangles' shadows.

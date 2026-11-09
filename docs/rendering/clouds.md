# Clouds

A ray-marched layer of clouds above the world, between two heights above the fog volume's far end (`CLUSTER_FAR`, 500 m): a low layer whose type runs from stratus through cumulus to cumulonimbus, and a thin cirrus layer above it. The weather is authored, as four scalars or a painted weather map, and the shapes come from noise that the GPU makes once. The sun and the sky's ambient light light the clouds, the frame marches them at a share of its pixels with a history that it reprojects, and composes them over the [sky](sky.md#sky) before the fog over the background. A shadow map on the layer's bottom darkens the sun on everything that the light loop lights. They come from the `Clouds` settings (stable ID 55, see [Settings](frame.md#settings)) on a volume at the camera (`lib/engine/render/settings.odin`, `clouds.odin`; `clouds_*.hlsl`, `clouds_common.hlsli` and `cloud_shadow.hlsli` in `lib/engine/content/shaders`).

**In this document:** [Settings](#settings) · [Weather](#weather) · [Shape](#shape) · [Lighting](#lighting) · [Far clouds](#far-clouds) · [Shadow](#shadow) · [Temporal](#temporal) · [Passes](#passes) · [Levels](#levels) · [Editor](#editor) · [Limits](#limits)

## Settings

Every field is a `volume.Value`, and the defaults are `DEFAULT_CLOUDS`. Heights are meters above the atmosphere's ground, where `Atmosphere.altitude` (in kilometers) puts the world's y of 0 (see [The atmosphere](sky.md#the-atmosphere)).

- **`density`** multiplies the clouds' extinction (0 by default, so a scene without the component has none, as `Fog` has no density). A meter of cloud at a density of 1 takes `CLOUD_EXTINCTION` (0.05) of the light away where the noise is whole.
- **`weather`** is where the weather comes from: `Scalars`, the four fields below everywhere, or `Map`, the [weather map](#weather). A `Map` whose texture is not set or not resident yet takes the scalars for that frame, without a log, as a texture sky that is not resident draws nothing.
- **`coverage`** (0.5), **`precipitation`** (0) and **`cloud_type`** (0.5) are the low layer's weather with `Scalars`; **`cirrus`** (0.2) is how much of the sky the cirrus layer covers in either source.
- **`weather_map`**, **`weather_origin`** and **`weather_size`** (50 km) place the map: it covers `weather_size` meters on a side, centered on `weather_origin`, and repeats beyond it.
- **`wind_speed`** (3 m/s) and **`wind_direction`** (degrees from +z toward +x, as the sun's azimuth) move the weather and the shapes. The renderer keeps how far the wind has carried them in f64 (`Volumetric_Clouds.wind_offset`), advanced by the platform's clock between frames, at most a tenth of a second a frame, so a long pause does not jump the sky.
- **`bottom`** (1500 m) and **`thickness`** (2500 m, at least 100) are the low layer; **`cirrus_height`** (8000 m) is the cirrus layer's. **`base_variation`** (0.3) lifts each cloud's base above the bottom by a slow noise over the sky, up to 0.7 of the thickness at 1, so the clouds do not all sit on one plane; a cumulonimbus lifts less, so its anvil still reaches the top.
- **`far_distance`** (15 km) and **`far_coverage`** (0.5) are the [far clouds](#far-clouds).
- **`ambient_intensity`** (1) multiplies the sky's ambient light on the clouds, and **`shadow_strength`** (1) is how dark their [shadow](#shadow) is on the world.
- **`Cloud_Settings`** is the frame's, as plain values with `top = bottom + thickness`, from `cloud_settings`; `apply_quality` gives it the [level](#levels), and `apply_debug` turns it `off` for the editor's `Clouds` feature toggle and for every debug view that is not shaded.

## Weather

The weather at a point is its coverage, its precipitation and its cloud type.

- **The map** is a texture asset of usage `data` (see [Textures](../content/kinds/textures.md#textures)), read at level 0 with the repeat sampler, so its mips do not matter: R is the coverage, G the precipitation and B the type, each from 0 to 1. The shaders read it at `(p.xz + weather_offset) / weather_size + 0.5`, where `weather_offset` is the camera relative to the map's origin, less the wind's carry, reduced modulo `weather_size` in f64 before it reaches the shaders, so a camera far from the origin keeps its precision.
- **Rain shapes the weather:** the coverage is at least 0.7 of the precipitation, and the type at least the precipitation, so a rainy cell is a thick, tall cloud. A point with a coverage below 0.005 has no cloud and the march samples no noise there.
- **The type** picks the layer's height gradient from three sets of knots: where the cloud starts, where it is whole, where it thins and where it ends, as fractions of the layer. Stratus (0) is `0, 0.1, 0.2, 0.3`, cumulus (0.5) `0, 0.2, 0.4, 0.6`, cumulonimbus (1) `0, 0.1, 0.7, 1`, and a type between two lerps their knots (`cloud_gradient`). A cumulonimbus also spreads into an anvil: from 0.7 of the layer up, its coverage grows toward the top.

## Shape

The noise is three textures that the GPU makes in the first frame with clouds (`clouds_noise.hlsl`), each `RGBA8_Unorm`, and keeps in the `Renderer` (`Volumetric_Clouds.shape`, `detail`, `curl`). `Cloud_Noise_State` says whether they hold noise: `Pending` until a frame that bakes them executes, whose commit marks them `Ready`, so a frame that fails bakes them again (see [Render graph](../gpu/render-graph.md#commits)). A soft restart destroys them with the Game scope and the next frame makes them again. Every texel is sampled at its center and every lattice lookup wraps at the texture's cells, the Worley search's neighbors included, so a repeat sampler reads them without a seam. The wind's carry stays in the `Renderer` and advances once a frame, by the first view with clouds; each [view](frame.md#views) keeps its own frame count, history and shadow map in its `View_State` (`Cloud_State`).

- **The shape** is 128³ and repeats every `CLOUD_SHAPE_PERIOD` (8 km) in the world: R is Perlin-Worley, tiling gradient noise over octaves of 4, 8, 16, 32 and 64 cells remapped into the inverted Worley noise's range, and G, B and A are inverted Worley noise at 4, 8 and 16 cells, whose weighted sum erodes R's low end. The cirrus layer reads R too, at one slice.
- **The detail** is 32³ and repeats every `CLOUD_DETAIL_PERIOD` (600 m): inverted Worley noise at 2, 4 and 8 cells in R, G and B.
- **The curl** is 128² and repeats every `CLOUD_CURL_PERIOD` (4 km): the curl of a tiling 2D gradient noise's potential, so it is divergence-free, in RG around 0.5. It moves the detail noise by up to `CLOUD_CURL_STRENGTH` (150 m) at the base of the layer and not at all at its top, so the base swirls and the top billows.
- **The density at a sample:** the noise position is the point relative to the camera plus the noise offset, which carries the wind and is reduced modulo `CLOUD_NOISE_PERIOD` (24 km), the low layer's periods' least common multiple, in f64 before the shaders see it. The cirrus reads the shape stretched three times along the wind, so its offset (`cirrus_offset`) is reduced in the wind's frame, by the stretched period along it and the period across it, and a wrap moves its lookup by whole periods whatever the wind's direction. The cheap density is the shape's R with `SHAPE_EROSION` (0.75) of its octaves' weighted sum cut from its low end, so a coverage covers about its share of the sky, times the type's height gradient, moved up by the cloud's base lift (`base_lift`: the shape's R at one slice over `CLOUD_LIFT_PERIOD`, 12 km, times `base_variation`, up to `CLOUD_LIFT_MAX`, 0.7 of the thickness), remapped by the coverage. The full density erodes it again by the detail noise, wispy at the bottom of the layer and billowed above, and only where the cheap density is above 0.01 and the far clouds have not taken over. The extinction is the density times `CLOUD_EXTINCTION` times `density`, doubled in rain, and fades out from `CLOUD_FADE_START` (25 km) to `CLOUD_MAX_DISTANCE` (40 km), so the march ends cleanly.
- **The geometry** keeps a point as its height above the ground and the cosine of the ray's angle from the zenith, never a position from the planet's center, as the sky does (`cloud_shell`, `cloud_ground`, `height_at` in `clouds_common.hlsli`, and the same in Odin for the tests). A ray's segment through the layer is the shell between the two spheres, from below, inside or above it, clamped to the ground and to the block's surface.

## Lighting

`clouds_march.hlsl` marches one ray for each texel of the cloud buffer, a block of `divisor` × `divisor` pixels, from the block's center.

- **The segment** ends at the block's farthest surface, the ground, or `CLOUD_MAX_DISTANCE`. The block's depth is the farthest of its pixels', or none when any pixel shows the sky. The step is the segment over the level's `steps`, at least the layer's thickness over 64, and the march starts a blue noise's share of a step in (`stbn_vec2.png`, by the frame's slice; a hash until the noise is resident). After three empty samples in a row it doubles its step, and steps back to the fine step when it finds cloud again. It stops behind 99 % of cloud.
- **The sun:** at a sample with extinction, a light march toward the sun through the cheap density takes `light_steps` samples whose lengths double, out to the top of the layer or `LIGHT_REACH_MAX` (4 km), and sums their optical depth. The sun's light there is three octaves of multiple scattering (Wrenninge): each takes half the light, half the extinction and half the phase's eccentricity of the one before. The phase is a forward Henyey-Greenstein lobe at 0.8 and a back lobe at -0.3, half each. The powder effect darkens the creases of a front-lit cloud: `1 - e^(-2·od)`, by how much the sun is behind the camera. The sun's illuminance is the untinted sun's times the atmosphere's transmittance at the layer's middle (`sky_transmittance`), and at the cirrus layer's height for the cirrus, so the clouds go orange at dusk with the sun. Under a texture sky, it is the light's own color.
- **Which sun:** the `Environment`'s linked light, when it has one; else the atmosphere's own sun, which casts no shadow since no light's record carries it; else, under a texture sky, the first directional light. Without any, the ambient light alone lights the clouds.
- **The ambient light** is the frame's `Ambient`'s average over every direction (see [Ambient light](sky.md#ambient-light)), times `ambient_intensity`, 0.35 of itself at the bottom of the layer and whole from 0.3 of its height, and 0.6 of itself in rain. The albedo is 0.95, and 0.8 in rain.
- **The march** adds each sample's light times the share of the light that the sample takes, and tracks the mean distance of what it hit, which the [temporal](#temporal) pass reprojects. The result is the light scattered toward the camera, not pre-exposed, with the transmittance in a, in `RGBA16_Float`.
- **The cirrus** is a thin sheet at `cirrus_height`: the shape noise's R at one slice, stretched three times along the wind and swirled by the curl, remapped by `cirrus`, with an optical depth of `CIRRUS_OPTICAL_DEPTH` (0.8) at a coverage of 1. It is lit by the sun with a Henyey-Greenstein lobe at 0.7 and by half the ambient light, and it dims what is behind it. A ray that finds no low cloud takes its distance.

## Far clouds

Past `far_distance`, the authored weather blends over as far again to a cumulus at `far_coverage`: the coverage lerps to `far_coverage`, the type to 0.5, and the precipitation to 0, by `saturate((t - far_distance) / far_distance)`, so a painted map 50 km wide hands over to an even sky at its edge, and a sky without a map does the same. Where the blend is whole, the march takes the cheap density alone. The clouds then fade out from 25 to 40 km, so the far sky is the atmosphere's.

## Shadow

- **The map** (`clouds_shadow.hlsl`) is `R8_Unorm`, `shadow_size` texels on a side at the level, over `CLOUD_SHADOW_EXTENT` (8 km) on the layer's bottom. Each texel marches toward the sun through the low layer in `shadow_steps` even steps of the cheap density, with the far blend by its distance from the camera, and writes the transmittance. The map is centered where the sun's rays through the camera meet the layer's bottom, snapped to a texel in the render origin's space (`cloud_shadow_center`), as the cascades snap, so it does not swim as the camera moves. It is the renderer's own texture, made again when the level's size changes, since every view's `Frame_Constants` holds its index.
- **The receiver** (`cloud_shadow` in `cloud_shadow.hlsli`) follows the sun's ray from a point relative to the camera up to the layer's bottom and reads the map there, bilinearly: 1 outside it, without a map, with the sun within 0.05 of the horizon, or at the layer's top and above. The shadow is `lerp(1, T, shadow_strength · fade · (1 - inside))`, where the fade runs from 0 at a sun 0.05 above the horizon to 1 at 0.15, and `inside` is the point's height fraction in the layer, 0 at its bottom and below, so a point in the layer, which has only the cloud above it between it and the sun, takes less of the whole layer's shadow the higher it is. `material_lighting.hlsli` includes it, and `light_falloff` multiplies a directional light's color by it when the light's record has `LIGHT_CLOUD_SHADOW`, which `begin_clouds` sets on the record of the light that lights the clouds. So every pass with the light loop takes it: the forward pass, the transparent and sorted surfaces, the sprites, the fog's injection, where it is the only directional shadow past the shadow maps' reach (see [Volumetric fog](fog.md#volumetric-fog)), the global illumination's hit light and the voxel cones' injection. Each declares the read (`declare_cloud_shadow`). A reflection probe's capture copies the lights without the flag and its faces' constants have no map, so a probe sees no cloud shadow, as it sees no clouds.
- **In `Frame_Constants`:** `cloud_shadow` (0 without), `cloud_shadow_sampler`, `cloud_shadow_strength`, `cloud_shadow_bottom` (the layer's bottom relative to the camera), `cloud_shadow_fade`, `cloud_shadow_center` and `cloud_shadow_inv_extent`, which `cloud_shadow_constants` fills from the frame's clouds.

## Temporal

- **The history** (`history_texture`, "clouds history") is a pair of `RGBA16_Float` textures at the cloud buffer's size that the texture cache swaps every frame (see [Render graph](../gpu/render-graph.md#render-graph)). It holds the clouds' light, not pre-exposed, so a change of exposure needs no rescale.
- **The pass** (`clouds_temporal.hlsl`) finds where this frame's clouds were last frame: the texel's direction times the march's mean distance, through last frame's projection translated by the camera's motion (`Frame.previous_view_projection`, `Frame.camera_motion`), as the screen-space reflections reproject their hits. It reads the history there bilinearly, clamps it to the 3x3 min and max of this frame's march, rgb and a, and blends `1 / history_frames` of this frame in. Without a valid history, off the screen or behind the camera, the texel is this frame's march alone.
- **The jitter** moves the march's start within its step from frame to frame, so the history averages the samples between the steps.

## Passes

`clouds.odin` adds them when the frame has a density, a sky draws (`Atmosphere` or a resident `Texture`; Flat has none), its five pipelines exist and the history could be made. Every read and write is declared, so the graph orders the passes and their barriers.

| Pass | Queue | Reads | Writes | What it does |
|---|---|---|---|---|
| `clouds noise` | Compute | — | The shape, the detail and the curl noise | Only while the noise is `Pending`: three dispatches of `clouds_noise.hlsl`, one for each texture. Its commit marks the noise `Ready`. |
| `clouds shadow` | Compute | The shape noise, the weather map | The shadow map | Only with a light's record: the transmittance toward the sun at each texel of the map, after the prepass, before the passes that light the world. |
| `clouds march` | Compute | The depth, the noise textures, the blue noise | `clouds current` and `clouds distance`, transients | The ray march, after the shadow maps and before the fog. |
| `clouds temporal` | Compute | `clouds current`, `clouds distance`, the history's previous | The history's current | The reprojection and the blend. |
| `clouds composite` | Graphics | The depth, the history's current, `clouds distance`, the exposure | The scene | After the sky and before the fog over the background: a depth-aware upsample of the cloud buffer, then `scene × T + light × exposure`, clamped to `CLOUD_MAX_SCENE` (60000). |

- **The upsample** takes the four cloud texels around the pixel, each weighted bilinearly and by how near its block's depth is to the pixel's: 1 when both show the sky, 0 when one does and the other does not, else `e^(-8·|Δ view depth| / view depth)`. When no texel agrees, the one whose block's depth is the closest stands alone. A pixel whose surface is nearer than 0.9 of the clouds' mean distance keeps its surface, so the clouds stay behind what is in front of them and in front of what is behind. The sky's sun disc, moon and stars are in the scene already, and the transmittance dims them. The fog over the background then dims the clouds with the sky.
- **The order in the frame:** `begin_clouds` runs right after `begin_sky`, whose settings and ambient light it takes, and before the lights are uploaded, since it flags the sun's record, and before the scene's constants, which take the shadow map. `add_cloud_shadow_passes` runs after the `after_prepass` hook, `add_cloud_passes` after the shadow maps and `add_cloud_composite` between the sky's background and the fog's (see [Frame](frame.md#frame)). The temporal pass's constants take last frame's projection once the scene's constants have set it.
- **The debug view** `Clouds` shows the history over black, exposed as the scene is, a texel for each block of pixels (see [Debug views](post-processing.md#debug-views)). The viewport's `Clouds` feature toggle turns the clouds and their shadow off.
- **A frame that fails** leaves the noise `Pending` and the history invalid, so the next frame bakes and starts over, as the rest of the frame does.

## Levels

`CLOUD_PARAMS` at `Quality.clouds` (see [Quality](quality.md#quality)).

| Level | Buffer | Steps | Light steps | Shadow map, steps | History frames | Memory at 2560x1440 |
|---|---|---|---|---|---|---|
| Low | A quarter on each side | 48 | 4 | 256², 6 | 8 | 7.4 MB, and 64 KB |
| Medium | Half on each side | 64 | 5 | 512², 8 | 12 | 29.5 MB, and 256 KB |
| High | Half on each side | 96 | 6 | 512², 10 | 16 | 29.5 MB, and 256 KB |
| Ultra | Half on each side | 128 | 6 | 1024², 12 | 16 | 29.5 MB, and 1 MB |

- **Memory** is the history pair and the two transients at the buffer's size, then the shadow map. The noise textures are 8.6 MB at every level, once.
- **Cost**, in milliseconds on the GPU, in the Intel Sponza sample's editor viewport at 911x481 with the clouds over the upper half of the view, from one capture's profile at each level. The march grows with the buffer's size, so a 1440p viewport costs about nine times these.

| Level | `clouds shadow` | `clouds march` | `clouds temporal` | `clouds composite` |
|---|---|---|---|---|
| Low | 0.006 | 0.081 | 0.005 | 0.009 |
| Medium | 0.010 | 0.105 | 0.006 | 0.009 |
| High | 0.011 | 0.165 | 0.006 | 0.009 |
| Ultra | 0.034 | 0.213 | 0.006 | 0.009 |

## Editor

The Atmosphere tab's Clouds group adds the component to the atmosphere's volume and turns it on and off, applies a weather preset (Clear, Scattered, Overcast, Storm), chooses the weather source, and opens the Weather Map panel, which paints the map's three channels and generates a map from noise into a texture asset that the daemon cooks (see [Editor](../editor/shell-and-panels.md#atmosphere)). The Atmosphere panel has every field, with its unit.

## Limits

- **No aerial perspective on the clouds** beyond the distance fade: a cloud 20 km away is as crisp as one overhead, and the fog's 500 m do not reach it.
- **The sky's cubemap and the ambient light leave the clouds out**, so the reflections and the diffuse light do not darken under an overcast; only the sun's light does, through the shadow map.
- **Flat mode has no clouds**, since nothing draws the sky under them.
- **A texture sky** lights the clouds from the linked light's record, or the first directional light's, not from the image, and the clouds appear once the sky's texture is resident.
- **The shadow map** covers 8 km around the point under the clouds toward the sun, and fades out as the sun nears the horizon. Beyond it, the world is lit.
- **The stars and the discs are dimmed by the clouds' transmittance**, not occluded one by one.
- **The march does not read the shadow map** for its own shadow: the light march gives each sample its own.
- **Reflection probe captures see no clouds and no cloud shadow**, so a probe under an overcast reflects a clear sky.

# Sky

The world's surroundings: the background where nothing draws, the ambient light until global illumination, and the specular light that reflects the sky. Both come from the `Environment` settings (stable ID 49, see [Settings](frame.md#settings)), on a volume at the camera (`lib/engine/render/settings.odin`, `sky.odin`).

**In this document:** [Modes](#modes) · [The atmosphere](#the-atmosphere) · [The sun](#the-sun) · [Night](#night) · [Texture](#texture) · [Ambient light](#ambient-light) · [Specular light](#specular-light) · [Passes](#passes) · [Limits](#limits)

## Modes

- **`mode`** is `Flat` by default, so a scene without one keeps the look that it had before the atmosphere.
- **Flat:** the world pass clears the scene to `background`, which is not pre-exposed. The ambient light is `sky`'s color from above and `ground`'s from below, which blend on the horizon (`DEFAULT_SKY_COLOR` and `DEFAULT_GROUND_COLOR` by default).
- **Atmosphere:** the background is the sky of a planet's air, which the sun and the moon light. It is pre-exposed, as the rest of the scene is. The ambient light comes from the same sky.
- **Texture:** the background is an hdr texture of the light from every direction, such as a captured sky, and the ambient light comes from it (see [Texture](#texture)).
- **`ambient_intensity`** multiplies the ambient light in either mode (1 by default).
- **The auto exposure** counts the sky that `Atmosphere` and `Texture` draw, so it adapts to a bright day sky and a dark night one. It does not count Flat's `background`, or a sky's while it draws the `background` color (see [Post-processing](post-processing.md#post-processing)).
- **Missing shaders:** an `Atmosphere` whose pipelines do not exist yet, because their shaders are not cooked, draws the `background` color. Its ambient light, which the CPU makes, is still the sky's.

## The atmosphere

The model is Hillaire's (see [References](README.md#references)). The air has three parts, each with a density that falls with height:

- **Rayleigh scattering:** molecules, which scatter blue more than red. `rayleigh_scattering` per channel, falling by e every `rayleigh_height`.
- **Mie scattering and absorption:** aerosols, which scatter every color alike and mostly forward (`mie_anisotropy`, Cornette and Shanks's phase), and absorb some. `mie_scattering`, `mie_absorption`, falling by e every `mie_height`.
- **Ozone:** absorbs, in a layer 25 km up that is 30 km thick (`OZONE_CENTER`, `OZONE_HALF_WIDTH`). `ozone_absorption` per channel. It keeps the twilight sky blue.

The settings are in the `atmosphere` struct, as `atmosphere.<field>` in a scene. Coefficients are per megameter and heights in kilometers, as the literature has them, and the defaults are Earth's. `ground_albedo` is the planet's ground, which reflects light into the sky and lights it from below. `planet_radius` and `atmosphere_height` set the planet's size. `altitude` is the height in kilometers of the world's y of 0 above the ground, and the camera's y adds to it.

## The sun

- **A linked sun:** `sun` names a `Directional_Light` entity. The sky's sun is then where the light comes from, its entity's -z, with the light's color times its intensity as its illuminance.
- **The tint:** in `Atmosphere`, the linked light's own light is multiplied by the transmittance of the air between the camera and the sun, which the CPU marches (`sky_transmittance`). At noon it barely changes. Near the horizon it turns orange and dim, and below the horizon it is 0, so the light's shadows and direct light end at sunset. The tint happens after the lights are extracted and before the shadows and the upload (`begin_sky`).
- **The sky's own sun:** without a link, or when the light is hidden or gone, the sun is at `sun_azimuth`, in degrees from +z toward +x, and `sun_elevation`, in degrees above the horizon, with `sun_illuminance`. It lights only the sky and the ambient light.
- **The disc** is `sun_disc_size` degrees across (0.53 by default), with darker edges, and the air in front of it dims and colors it. 0 draws no disc.

## Night

- **The moon** is at `night.moon_azimuth` and `night.moon_elevation`, `night.moon_disc_size` degrees across, with `night.moon_illuminance` times `night.moon_color` when full. It is a sphere that the sun lights, with darker seas from noise, so its phase follows the angle between them: it is full when it is opposite the sun. It lights the sky and the ambient light at that phase, and nothing else. An illuminance of 0 leaves it out.
- **The stars** are procedural: at most one in each cell of a grid on each face of a cube around the camera, in about `night.star_density` of the cells, with random places, brightnesses and colors from blue to orange. `night.star_intensity` is the brightest star's light. The air in front of them dims them, and the day's sky outshines them, so they show only at night. An intensity of 0 leaves them out.
- The night's light is very dim beside the day's. The auto exposure adapts to it, the night sky's light included (see [Post-processing](post-processing.md#post-processing)).

## Texture

`Texture` draws an image of the light from every direction (`sky_texture.odin`, `sky_texture*.hlsl`), as a USD stage's DomeLight makes it (see [Stages](../content/kinds/stages.md#lights)).

- **`texture`** is a texture asset, best of usage `hdr` (an `.hdr` or `.exr` file, see [Textures](../content/kinds/textures.md#textures)). It is equirectangular: across, the azimuth, with the middle column toward +z and +x to its right; down, the angle from straight up. Or it is a [cube map](../content/kinds/textures.md#cube-maps-and-arrays), whose faces take a world direction as it is. Both give the same light from the same image: `layout = cube_equirect` cooks one into the other. An array is not a sky: it logs that once, and the sky is as when the texture is not resident. **`texture_intensity`** scales its light (1 by default), and **`texture_rotation`** turns it about +y, in degrees: at 90 the middle column is toward +x.
- **The background** (`sky texture`): after the world pass, where the depth is 0, the texture's light from the pixel's direction, at the mip whose texels are about as wide as a pixel, pre-exposed. The fog over the background then dims it, as it does the atmosphere's.
- **The ambient light** is the atmosphere's linear function of the direction, from the texture. A compute pass (`sky texture ambient`, one group) sums one mip, the largest at most `SKY_AMBIENT_WIDTH` (128) wide, each texel weighted by its solid angle: the constant is the average light, and each gradient twice the average of the light times its direction. A copy moves it to a readback buffer, with a ticket, and the CPU takes it when it is back, a few frames later, then turns it by the rotation and scales it by the intensity and `ambient_intensity` each frame. It is integrated once for each version of the texture, and again if it has not come back after `SKY_AMBIENT_RETRY_FRAMES` (120).
- **A cube's mips and texels:** the widths above count a texture's texels around the horizon, which is four times a cube's face. So its integral's mip has faces at most 32 wide, its sun's at most 512, and the background's filter takes the same mip as for the same sky in equirectangular form. The integral sums every texel of the six faces, each weighted by its solid angle, `1 / (1 + u² + v²)^(3/2)` at `u` and `v` from -1 to 1 on its face. The sun's window stays on the plane of the face that has the brightest texel, and the points of that plane past the face's edge read the next face, so a sun on an edge is found the same. A `TextureCube` has no `Load`, so these read the middles of texels with `SampleLevel`, which gives the texels as they are.
- **Until it is ready:** while the texture is not resident, nothing draws over the background, which is the `background` color, and the ambient light is Flat's. While its integral is not back, the ambient light is Flat's.
- **The sun** is not the texture's. A directional light lights the scene as in Flat. The editor's Aim Sun at Sky aims it at the image's sun (see [Editor](../editor/shell-and-panels.md#atmosphere)), which the same pass finds: the brightest texel of the integral's mip, then, in a window of five of its texels on a side, of the largest mip at most `SKY_SUN_WIDTH` (2048) wide, the direction of the texels within half of the brightest luminance there, weighted by their light. A coarser mip's light around the sun would move it: in Jungle Ruins' sky, by 16 degrees of elevation at 128 texels wide and 1 degree at 1024. `sky_texture_sun` gives it in the world, turned by the rotation, when the last frame's sky was a texture's whose integral is back, and its brightest luminance is at least `SKY_SUN_RATIO` (10) times the average, so an overcast sky has no sun. Jungle Ruins' is 45 times as bright, about 39 degrees of azimuth and 7 of elevation.

## Ambient light

- **`Ambient`** is a linear function of the direction, per channel: `constant + x·d.x + y·d.y + z·d.z`. It holds the Flat sky's light from above and the ground's from below exactly, so `flat_ambient` gives the same light as before. Shaders evaluate it with `ambient_light` (`ambient.hlsli`), from four float4s in `Frame_Constants.ambient` and the global illumination's constants.
- **In `Atmosphere`**, the CPU integrates the sky in 64 directions spread over the sphere (`sky_ambient`), with the sun's and the moon's light, and the ground's below the horizon. It takes the sky's first spherical harmonics, convolved with the cosine: the constant is the sky's average light, and the gradient twice the average of the light times its direction. Multiple scattering on the CPU is an even share of the light that each point scatters, not the table. The renderer keeps the result until the atmosphere, the camera's height or a light changes.
- **In `Texture`**, the GPU integrates it from the texture (see [Texture](#texture)).
- **Its readers:** the forward pass without global illumination, for the diffuse light along the normal; the global illumination's sky beyond its last cascade, and its gathers' diffuse light past their probes; the fog's injection and the sprites, which take its constant, the light from every direction alike. The specular light along a reflection is the [cubemap](#specular-light)'s, once it is ready.
- **The diffuse light stays linear:** a linear function of the direction is already the right integral of the sky over a cosine lobe, as far as its first harmonics go.

## Specular light

The specular light along a reflection is the sky's cubemap, prefiltered by roughness (`sky_cube.odin`, `sky_cube*.hlsl`, `cube_prefilter.hlsl`, `sky_cube.hlsli`). It runs at every [quality](quality.md#quality), reflections `Off` included: it is a small cubemap that seldom changes.

- **The capture** (`sky cube capture`) draws the sky into a source cube, every mip, each texel the mean of `min(2^mip, 8)²` directions across it, so the coarse mips are box-filtered without a read of the cube. It is not pre-exposed. Its source:
  - **Atmosphere:** the sky view table (`sky_cube_atmosphere.hlsl`), times `ambient_intensity`, once the frame makes the tables.
  - **Texture:** the texture (`sky_cube_capture.hlsl`), turned and scaled as the background is, times `ambient_intensity`, once it is resident, at the texture's mip whose texels are about as wide as a direction.
  - **Ambient:** otherwise the frame's linear `Ambient`: Flat's colors, an atmosphere whose pipelines are not ready, or a texture that is not resident. So the cubemap always matches the diffuse light's fallback.
  - The sun's and the moon's discs and the stars are left out. The directional lights give the specular highlights, so a disc would count them twice, and a star is narrower than a texel.
- **The prefilter** (`sky cube prefilter`, `cube_prefilter.hlsl`) convolves the source with a GGX lobe for each mip: the split sum's first term, whose second is the environment BRDF fit that `shade_indirect` applies (`lit.hlsli`). Mip 0 is a mirror, the source's mip 0 as it is, and mip `m` of `n` is roughness `m / (n − 1)`, so the last is roughness 1. The lobe takes the normal, the view and the reflection as one direction, as Karis does, and is importance sampled at Hammersley points, each weighted by its cosine. Each sample reads the source's mip whose texels cover about the solid angle that the sample stands for, `0.5 · log2(Ωs / Ωp) + 1` (filtered importance sampling, Křivánek and Colbert), so a small bright light, such as the glow around the sun, leaves no fireflies at any roughness. It takes any sampled cube with its mip chain, not only the sky's.
- **Parameters:** `SKY_CUBE_PARAMS` at the reflections' level (see [Quality](quality.md#quality)). The mips go down to faces `SKY_CUBE_MIN_FACE` (4) wide.

| Level | Faces | Mips | Format | Samples per texel |
|---|---|---|---|---|
| Low | 64 | 5 | `RG11B10_Float` | 32 |
| Medium | 128 | 6 | `RG11B10_Float` | 64 |
| High | 128 | 6 | `RGBA16_Float` | 64 |
| Ultra | 256 | 7 | `RGBA16_Float` | 128 |

- **Memory:** the source and three prefiltered cubes with their mips: 0.5 MB at Low, 2.1 MB at Medium, 4.2 MB at High and 16.8 MB at Ultra in all. A level of another size makes them again.
- **The ring and the updates.** The prefiltered cubes are a ring of three: the current one, which the readers sample; the previous one, which it blends in over; and the next one, which a build fills.
  - The first frame, and the first at a new level, makes every mip of the current cube at once. The readers sample it from the next frame, and until then take the ambient light.
  - When the sky's source or its inputs change, a build of the next cube starts. Its first frame captures the source and prefilters mip 0, and each frame after prefilters one more mip, so a build takes as many frames as there are mips. Then the ring turns, and the new cube blends in over the old one in as many frames: each reader takes both at the mip for its roughness and blends them.
  - **Flat** changes when its colors or `ambient_intensity` do, **Texture** when its texture is resident, or its version, rotation or intensities change, and **Atmosphere** when the sun, the moon, the camera's height or the settings do. A time of day that moves every frame starts each build as the last one ends, so the reflections follow it smoothly, a build or two behind, with no pops.
  - A sky that does not change adds no passes.
- **Its readers** (`sky_specular` in `sky_cube.hlsli`) take the cubemap along the reflection at `roughness · (mips − 1)`:
  - **The forward pass without the GI:** in place of the ambient light along the reflection, at the surface's roughness (`shading_roughness`).
  - **The GI's gathers:** where they took the ambient light along the reflection. That is the screen cascades' gather past its probes, the split cascades' gather past its last level and where the world probes have no light, and the voxel cones' reflection cone past what blocks it. Each takes the roughness of its pixel from the prepass (`Frame.roughness`).
  - **The transparent surfaces:** always, along their own normal and at their own roughness, in place of the opaque surface's GI specular light at their pixel.
  - The material previews have none and take the ambient light.

## Passes

`sky.odin` adds them when the frame's `Environment` is `Atmosphere` and its four pipelines exist. Every texture is 2D and `RGBA16_Float`, and every pass is a compute pass.

| Pass | Writes | What it does |
|---|---|---|
| `sky transmittance` | 256×64 | The share of light from the top of the atmosphere that reaches each height along each direction, laid out as Bruneton's |
| `sky multiscatter` | 32×32 | At each height and sun angle, the light scattered twice in 64 directions with an even phase, over one minus the share that the air around scatters back, which sums every further order |
| `sky view` | 256×128 | The light from every direction at the camera: the sun's and the moon's scattering, once from the transmittance and more from the multiple scattering table, and the ground's. Rows are squeezed toward the horizon. |
| `sky` | The scene | Where the depth is 0, after the world pass and before the fog over the background: the sky view table, and above the horizon the sun, the moon and the stars, pre-exposed |

`Texture` has two passes of its own, when its texture is resident and their pipelines exist: `sky texture` draws over the background where `sky` would, and `sky texture ambient`, with its copy to the readback buffer, runs only in a frame that integrates the texture.

Every mode has the [cubemap](#specular-light)'s two passes, in a frame that updates it: `sky cube capture`, which writes every mip of the source cube, and `sky cube prefilter`, which writes one mip of the next cube, or every mip at once when there is no current one. They run after the tables, which the atmosphere's capture reads.

- The tables are made again each frame, since the blended settings can change each frame. They are small.
- The world pass clears the scene to black under the sky. The fog over the background then dims the sky by the whole fog volume, as it did the background color (see [Volumetric fog](fog.md#volumetric-fog)).
- **Precision:** the planet's radius is thousands of kilometers, and a float keeps only about a meter of it, which can be the camera's whole height. The shaders keep a point as its height above the ground and the cosine of a direction from its zenith, and find each height along a ray from a difference that keeps it (`height_along` in `sky_common.hlsli`). The CPU works in f64.

## Limits

- **No aerial perspective:** the air between the camera and the world's surfaces does not dim or color them. The fog does that within its 500 m.
- **No clouds**, and the stars do not turn with the time.
- **A texture sky's light is one image**, which does not change with the time, and its ambient light is as coarse as the atmosphere's. Its reflections are the image's, through the [cubemap](#specular-light).
- **Reflections show no discs and no stars:** the cubemap leaves out the sun's and the moon's discs, whose highlights are the directional lights', and the stars, which are narrower than its texels. A mirror at night shows the air's light but not the stars.
- **The sky's sun lights nothing without a link.** A scene that wants sunlight links a directional light, which the Atmosphere tab does (see [Editor](../editor/shell-and-panels.md#atmosphere)).
- The camera stays inside the atmosphere: its height is clamped between 1 m and 1 m below the top.

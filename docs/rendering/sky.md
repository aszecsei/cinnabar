# Sky

The world's surroundings: the background where nothing draws, and the ambient light until global illumination. Both come from the `Environment` settings (stable ID 49, see [Settings](frame.md#settings)), on a volume at the camera (`lib/engine/render/settings.odin`, `sky.odin`).

**In this document:** [Modes](#modes) · [The atmosphere](#the-atmosphere) · [The sun](#the-sun) · [Night](#night) · [Texture](#texture) · [Ambient light](#ambient-light) · [Passes](#passes) · [Limits](#limits)

## Modes

- **`mode`** is `Flat` by default, so a scene without one keeps the look that it had before the atmosphere.
- **Flat:** the world pass clears the scene to `background`, which is not pre-exposed. The ambient light is `sky`'s color from above and `ground`'s from below, which blend on the horizon (`DEFAULT_SKY_COLOR` and `DEFAULT_GROUND_COLOR` by default).
- **Atmosphere:** the background is the sky of a planet's air, which the sun and the moon light. It is pre-exposed, as the rest of the scene is. The ambient light comes from the same sky.
- **Texture:** the background is an hdr texture of the light from every direction, such as a captured sky, and the ambient light comes from it (see [Texture](#texture)).
- **`ambient_intensity`** multiplies the ambient light in either mode (1 by default).
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
- The night's light is very dim beside the day's. The auto exposure adapts to it (see [Post-processing](post-processing.md#post-processing)).

## Texture

`Texture` draws an image of the light from every direction (`sky_texture.odin`, `sky_texture*.hlsl`), as a USD stage's DomeLight makes it (see [Stages](../content/kinds/stages.md#lights)).

- **`texture`** is a texture asset, best of usage `hdr` (an `.hdr` or `.exr` file, see [Textures](../content/kinds/textures.md#textures)), equirectangular: across, the azimuth, with the middle column toward +z and +x to its right; down, the angle from straight up. **`texture_intensity`** scales its light (1 by default), and **`texture_rotation`** turns it about +y, in degrees: at 90 the middle column is toward +x.
- **The background** (`sky texture`): after the world pass, where the depth is 0, the texture's light from the pixel's direction, at the mip whose texels are about as wide as a pixel, pre-exposed. The fog over the background then dims it, as it does the atmosphere's.
- **The ambient light** is the atmosphere's linear function of the direction, from the texture. A compute pass (`sky texture ambient`, one group) sums one mip, the largest at most `SKY_AMBIENT_WIDTH` (128) wide, each texel weighted by its solid angle: the constant is the average light, and each gradient twice the average of the light times its direction. A copy moves it to a readback buffer, with a ticket, and the CPU takes it when it is back, a few frames later, then turns it by the rotation and scales it by the intensity and `ambient_intensity` each frame. It is integrated once for each version of the texture, and again if it has not come back after `SKY_AMBIENT_RETRY_FRAMES` (120).
- **Until it is ready:** while the texture is not resident, nothing draws over the background, which is the `background` color, and the ambient light is Flat's. While its integral is not back, the ambient light is Flat's.
- **The sun** is not the texture's. A directional light lights the scene as in Flat, and its direction is set to match the bright spot of the image by hand.

## Ambient light

- **`Ambient`** is a linear function of the direction, per channel: `constant + x·d.x + y·d.y + z·d.z`. It holds the Flat sky's light from above and the ground's from below exactly, so `flat_ambient` gives the same light as before. Shaders evaluate it with `ambient_light` (`ambient.hlsli`), from four float4s in `Frame_Constants.ambient` and the global illumination's constants.
- **In `Atmosphere`**, the CPU integrates the sky in 64 directions spread over the sphere (`sky_ambient`), with the sun's and the moon's light, and the ground's below the horizon. It takes the sky's first spherical harmonics, convolved with the cosine: the constant is the sky's average light, and the gradient twice the average of the light times its direction. Multiple scattering on the CPU is an even share of the light that each point scatters, not the table. The renderer keeps the result until the atmosphere, the camera's height or a light changes.
- **In `Texture`**, the GPU integrates it from the texture (see [Texture](#texture)).
- **Its readers:** the forward pass without global illumination, for the diffuse light along the normal and the specular light along the reflection; the global illumination's sky beyond its last cascade; the fog's injection and the sprites, which take its constant, the light from every direction alike.

## Passes

`sky.odin` adds them when the frame's `Environment` is `Atmosphere` and its four pipelines exist. Every texture is 2D and `RGBA16_Float`, and every pass is a compute pass.

| Pass | Writes | What it does |
|---|---|---|
| `sky transmittance` | 256×64 | The share of light from the top of the atmosphere that reaches each height along each direction, laid out as Bruneton's |
| `sky multiscatter` | 32×32 | At each height and sun angle, the light scattered twice in 64 directions with an even phase, over one minus the share that the air around scatters back, which sums every further order |
| `sky view` | 256×128 | The light from every direction at the camera: the sun's and the moon's scattering, once from the transmittance and more from the multiple scattering table, and the ground's. Rows are squeezed toward the horizon. |
| `sky` | The scene | Where the depth is 0, after the world pass and before the fog over the background: the sky view table, and above the horizon the sun, the moon and the stars, pre-exposed |

`Texture` has two passes of its own, when its texture is resident and their pipelines exist: `sky texture` draws over the background where `sky` would, and `sky texture ambient`, with its copy to the readback buffer, runs only in a frame that integrates the texture.

- The tables are made again each frame, since the blended settings can change each frame. They are small.
- The world pass clears the scene to black under the sky. The fog over the background then dims the sky by the whole fog volume, as it did the background color (see [Volumetric fog](fog.md#volumetric-fog)).
- **Precision:** the planet's radius is thousands of kilometers, and a float keeps only about a meter of it, which can be the camera's whole height. The shaders keep a point as its height above the ground and the cosine of a direction from its zenith, and find each height along a ray from a difference that keeps it (`height_along` in `sky_common.hlsli`). The CPU works in f64.

## Limits

- **No aerial perspective:** the air between the camera and the world's surfaces does not dim or color them. The fog does that within its 500 m.
- **No clouds**, and the stars do not turn with the time.
- **A texture sky's light is one image**, which does not change with the time, and its ambient light is as coarse as the atmosphere's: reflections see only its linear function, not the image.
- **The sky's sun lights nothing without a link.** A scene that wants sunlight links a directional light, which the Atmosphere tab does (see [Editor](../editor/shell-and-panels.md#atmosphere)).
- The camera stays inside the atmosphere: its height is clamped between 1 m and 1 m below the top.

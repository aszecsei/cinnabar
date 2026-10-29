# Transparency

Transparent and additive surfaces draw after the world pass, with moment-based order-independent transparency by default and sorted draws on request. Compute sprites draw among the moment-based surfaces. Read [Lighting and shadows](lighting-and-shadows.md) first for the forward template they share.

Transparent and additive surfaces draw after the world pass, the background's fog and the global illumination's lit scene (`lib/engine/render/transparency.odin`). They test the scene's depth and do not write it, and they are in no prepass and no shadow map. Their pipelines have a small depth bias toward the camera (`TRANSPARENT_DEPTH_BIAS`, `TRANSPARENT_SLOPE_BIAS`). A transparent face in the plane of an opaque one, such as the bottom of a glass box on a floor, then always draws, instead of flickering with temporal AA's jitter. A `Transparent` material draws with moment-based order-independent transparency by default. A material with `transparency = sorted`, and every `Additive` material, draws sorted back to front.

| Path | Passes | Order |
|---|---|---|
| Moment-based | Moments, then transparent, then a composite | Correct at each pixel, also where surfaces pass through each other |
| Sorted | One draw for each item, over the scene | By each item's middle, so surfaces that pass through each other show one in front |
| [Sprites](#sprites) | Compute passes that add to the moments and to the transparent pass's sum | As the moment-based surfaces, among which they draw |

**Moment-based transparency** (Münstermann, Krumpen, Klein and Peters, *Moment-Based Order-Independent Transparency*, 2018) uses four power moments:

1. **The moments pass** draws the moment-based items, with additive blending. At each pixel, it adds up the optical depth of every surface, b0 = Σ −ln(1 − α), into an `R32_Float` target (`MOMENTS_ZEROTH_FORMAT`). It also adds up b0 · (z, z², z³, z⁴) into an `RGBA32_Float` target (`MOMENTS_FORMAT`). z is the view depth on a log scale from the near plane to `MOMENTS_FAR` (500 m), mapped to [−1, 1] (`moments.hlsli`).
2. **The transparent pass** draws the same items again. Each surface shades with the forward template, then reconstructs the transmittance T in front of it from the moments (`transmittance_at`). The moments are biased toward an even spread by `MOMENT_BIAS` (5·10⁻⁷), and a surface takes `MOMENT_OVERESTIMATION` (0.25) of its own optical depth. The pass adds `(color · α · T, α · T)` into an `RGBA16_Float` target (`ACCUMULATED_FORMAT`).
3. **The composite** (`transparency_composite.hlsl`) is a compute pass. It writes `scene · e^−b0 + (1 − e^−b0) · accumulated.rgb / accumulated.a` into the scene, where b0 is not about 0.

- **The moments are 32-bit.** With 16 bits, four power moments need the paper's quantization to stay stable.
- **Without the composite's pipeline**, the moment-based items draw nothing.

**Sorted draws:**
- Each sorted item is a bin of its own, after the opaque bins and moment-based transparency's (`Bin_Group`, `sort_bins`). The bins are ordered back to front by the squared distance of each item's bounding sphere's middle from the camera. Each bin is one indirect draw, so the draws keep that order.
- A sorted draw blends premultiplied colors over the scene. An additive one adds its light times its opacity.
- A two-sided sorted material draws its back faces first, then its front faces (`Material_Pipeline.over`).
- Sorted surfaces draw after the composite, so they are always in front of moment-based ones.

**One shader** (`material_transparent.hlsli`): `ps_transparent` gives `(color · α · T, α · T)` for both paths. T is 1 unless `Material_Push.transmittance` is set. Only the pipeline's target and blend differ, so the path is chosen at runtime and needs no permutations of its own. Its color is `forward_color`, the forward template's.

**Lighting.** Transparent surfaces have the light clusters, the shadow maps, the fog volume and the GI. They have no prepass, so they do not read the ambient occlusion or the shadow mask:
- A light with a channel of the mask does not shadow them (see [Shadows](lighting-and-shadows.md#shadows)).
- The GI is read at the pixel, which is the light at the opaque surface behind them.
- The fog dims their color and adds its light in front of them, as for an opaque surface. An additive surface adds no fog light, since the fog's light is already in the scene behind it.

**The editor.**
- When `Frame_Desc.keep_ids` is set, a pass after post-processing draws every transparent item where its opacity is at least `TRANSPARENT_ID_CUTOFF` (1/255), so wherever it shows. It writes their IDs and their depth (`Transparent_Ids`).
- So a click on glass selects the glass, whatever its opacity, as in other editors; an object behind it is selected from the outliner. Only a surface's fully transparent parts, such as a texture's cut-out texels, let a click through.
- So the editor picks glass, and its tools and tested debug lines see it. Temporal AA and the exposure have already run, so the scene looks as the game's does.
- In a game without an editor, tested debug lines draw over transparent surfaces.

**The overdraw view.** The `Transparent_Overdraw` debug view counts the transparent layers at each pixel, sorted ones and sprites included: the moments pass, and the sprites' moments pass, add 1 for each layer in place of its optical depth. It shows them as heat colors from 1 to 8. Additive surfaces have no moments, so the view leaves them out.

**Limits:**
- Transparent surfaces have no velocities, so temporal AA moves their pixels with the camera, and a moving transparent surface leaves a short trail. FSR takes the moments' coverage as its masks, so moment-based surfaces and sprites do not trail under it, but sorted and additive ones do (see [FSR](anti-aliasing.md#fsr)).
- They cast no shadows, and the cooker turns `cast_shadows` off for them.
- The material previews draw a moment-based material as a sorted one, since they have one mesh.

## Sprites

Compute sprites are camera-facing squares that compute passes rasterize into moment-based transparency, by screen tiles, instead of drawing them (`lib/engine/render/sprites.odin`, after Köhler, *Practical Order Independent Transparency*). Dense particles are many overlapping layers, and drawn they would cost a blend into each target for every layer. A sprite pass reads and writes each pixel once, whatever the layers, and the sprites take their place among the moment-based surfaces, so smoke shows behind, in front of and through glass without sorting.

A frame draws at most `MAX_SPRITES` (65536) sprites, from the CPU and from the GPU. A game gives the frame its CPU sprites in `Frame_Desc.sprites`. A `render.Sprite` has:
- Its position, its size (half its side, in meters) and its rotation about the view direction.
- Its linear color and opacity, and its emission.
- Its softness: the distance in front of an opaque surface over which it fades, so it does not cut a hard line into the surface.
- Its texture, whose colors tint it and whose alpha scales its opacity, and the part of the texture that it shows (`uv_rect`), such as a flipbook's frame. Without a texture, or until the texture is resident, a sprite is a soft round puff.

**The records.** The frame's sprites are records in one buffer of `MAX_SPRITES`, in `Renderer.sprites`, with a counter beside it:
- `begin_sprites` writes `Frame_Desc.sprites` into the upload ring each frame, relative to the camera, with their textures' bindless indices. A copy, the first sprite pass, puts them at the start of the buffer and their count in the counter.
- A GPU pass, such as the particles' update (see [Particles](particles.md#simulation)), appends its own after them. It calls `reserve_sprites(f, count)` before the world pass, from the `before_world` or `after_prepass` hooks or the renderer's own passes. That gives it a `Sprite_Target`, the records and the counter, which it declares as written. Its shader calls `append_sprite` (`sprites.hlsli`), which adds one to the counter and writes the record there.
- The frame's capacity is the CPU's sprites plus every reservation, up to `MAX_SPRITES`. It sizes the bins, the screen buffer and the light textures. Sprites that a pass appends past it are left out.
- **Arguments** (`sprite_arguments.hlsl`): one thread turns the count, up to the capacity, into the arguments of the bin and light passes' indirect dispatches. The raster passes walk only the words of the tiles' bits that the count reaches.

The passes run with the camera's constants, after the moments pass and after the transparent pass:

1. **Tiles** (`sprite_tiles.hlsl`): a group for each tile of `SPRITE_TILE` (32) pixels finds the farthest opaque depth in it, and clears the tile's bits, one for each sprite.
2. **Bin** (`sprite_bin.hlsl`): a thread for each sprite places it on the screen with the camera's jittered projection. It writes where the sprite is: its center, its radius and rotation in pixels, its depth and its warped depth for the moments, and the mip level of its texture that matches its size. Then it sets the sprite's bit in each tile that its square covers where it is in front of the tile's farthest opaque surface. A sprite behind the near plane sets none.
3. **Moments** (`sprite_moments.hlsl`): after the moments pass, at each pixel, the sprites whose bits its tile has, and that are in front of its opaque surface, add their optical depth and its moments to the pass's. Every pixel of an 8x8 group is in one tile, so the group walks the same bits, which it loads once for each wave.
4. **Light** (`sprite_light.hlsl`): an 8x8 grid of points on each sprite is lit, as the paper's particle lightmap is, into two `RGBA16_Float` textures with `SPRITE_LIGHT_COLUMNS` (128) sprites a row. Each point takes every directional light and its cluster's punctual lights with their shadow maps, as a Lambert surface does at a cosine of 0.5, since a sprite is lit from whichever side its light comes. Then it takes the global illumination at the opaque surface behind it, or the ambient light, and the fog between it and the camera. So a puff that enters a shadow darkens across itself, and a light behind a wall does not light it.
5. **Shade** (`sprite_shade.hlsl`): after the transparent pass, at each pixel, the same sprites add their light and opacity, each times the transmittance in front of it that the moments give, to the pass's sum, as `ps_transparent` does. A sprite's light is its color times its texture's tint and the light at its point, plus its emission, both dimmed by the fog, plus the fog's own light, pre-exposed.

The composite then draws the sprites with the moment-based surfaces. The moments hold the sprites and the surfaces alike, and need no order, so the sprites need no sort.

- **The bits are in sprite order** in each tile, a word for every 32 sprites of the capacity. A frame with more sprites walks more words at every pixel, empty or not.
- **The shared buffers** (where each sprite is on the screen, each tile's farthest depth and the bits) are in `Renderer.sprites`, and grow with the frames' sprites and sizes. The light textures are transient. Their rows round up to a power of two, so the texture cache keeps them while the count changes.
- **Without the sprite pipelines, or the composite's,** a frame draws no sprites.
- **Sprites draw only in the camera's view**, not the view model's. They cast no shadows and have no velocities or IDs, as other transparent surfaces have none. A light with a channel of the shadow mask has no shadow maps, so it does not shadow them.
- **Only squares that face the camera** are sprites. Shapes that turn away from it draw as meshes, with billboard materials (see [Billboards](gpu-scene.md#billboards)) and moment-based transparency.

The glass scene, which F7 cycles to, has a `Particle_System` beside the moment-based glass, whose smoke drifts through the glass (see [Particles](particles.md#particles)).

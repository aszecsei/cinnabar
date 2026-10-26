# Transparency

Transparent and additive surfaces draw after the world pass, with moment-based order-independent transparency by default and sorted draws on request. Read [Lighting and shadows](lighting-and-shadows.md) first for the forward template they share.

Transparent and additive surfaces draw after the world pass, the background's fog and the global illumination's lit scene (`lib/engine/render/transparency.odin`). They test the scene's depth and do not write it, and they are in no prepass and no shadow map. Their pipelines have a small depth bias toward the camera (`TRANSPARENT_DEPTH_BIAS`, `TRANSPARENT_SLOPE_BIAS`). A transparent face in the plane of an opaque one, such as the bottom of a glass box on a floor, then always draws, instead of flickering with temporal AA's jitter. A `Transparent` material draws with moment-based order-independent transparency by default. A material with `transparency = sorted`, and every `Additive` material, draws sorted back to front.

| Path | Passes | Order |
|---|---|---|
| Moment-based | Moments, then transparent, then a composite | Correct at each pixel, also where surfaces pass through each other |
| Sorted | One draw for each item, over the scene | By each item's middle, so surfaces that pass through each other show one in front |

**Moment-based transparency** (Münstermann, Krumpen, Klein and Peters, *Moment-Based Order-Independent Transparency*, 2018) uses four power moments:

1. **The moments pass** draws the moment-based items, with additive blending. At each pixel, it adds up the optical depth of every surface, b0 = Σ −ln(1 − α), into an `R32_Float` target (`MOMENTS_ZEROTH_FORMAT`). It also adds up b0 · (z, z², z³, z⁴) into an `RGBA32_Float` target (`MOMENTS_FORMAT`). z is the view depth on a log scale from the near plane to `MOMENTS_FAR` (500 m), mapped to [−1, 1] (`moments.hlsli`).
2. **The transparent pass** draws the same items again. Each surface shades with the forward template, then reconstructs the transmittance T in front of it from the moments (`transmittance_at`). The moments are biased toward an even spread by `MOMENT_BIAS` (5·10⁻⁷), and a surface takes `MOMENT_OVERESTIMATION` (0.25) of its own optical depth. The pass adds `(color · α · T, α · T)` into an `RGBA16_Float` target (`ACCUMULATED_FORMAT`).
3. **The composite** (`transparency_composite.hlsl`) is a compute pass. It writes `scene · e^−b0 + (1 − e^−b0) · accumulated.rgb / accumulated.a` into the scene, where b0 is not about 0.

- **The moments are 32-bit.** With 16 bits, four power moments need the paper's quantization to stay stable. The formats and the bias are constants, so 16-bit moments with the quantization can come later.
- **Without the composite's pipeline**, the moment-based items draw nothing.

**Sorted draws:**
- Each sorted item is a bin of its own, after the opaque bins and moment-based transparency's (`Bin_Group`, `sort_bins`). The bins are ordered back to front by the squared distance of each item's bounding sphere's middle from the camera. Each bin is one indirect draw, so the draws keep that order.
- A sorted draw blends premultiplied colors over the scene. An additive one adds its light times its opacity.
- A two-sided sorted material draws its back faces first, then its front faces (`Material_Pipeline.over`).
- Sorted surfaces draw after the composite, so they are always in front of moment-based ones.

**One shader** (`material_transparent.hlsli`): `ps_transparent` gives `(color · α · T, α · T)` for both paths. T is 1 unless `Material_Push.transmittance` is set. Only the pipeline's target and blend differ, so the path is chosen at runtime and needs no permutations of its own. Its color is `forward_color`, the forward template's.

**Lighting.** Transparent surfaces have the light clusters, the shadow maps, the fog volume and the GI. They have no prepass, so they do not read the ambient occlusion or the shadow mask:
- A light with a channel of the mask does not shadow them. *Later,* they trace in the pixel shader (see [Shadows](lighting-and-shadows.md#shadows)).
- The GI is read at the pixel, which is the light at the opaque surface behind them.
- The fog dims their color and adds its light in front of them, as for an opaque surface. An additive surface adds no fog light, since the fog's light is already in the scene behind it.

**The editor.**
- When `Frame_Desc.keep_ids` is set, a pass after post-processing draws every transparent item where its opacity is at least `TRANSPARENT_ID_CUTOFF` (1/255), so wherever it shows. It writes their IDs and their depth (`Transparent_Ids`).
- So a click on glass selects the glass, whatever its opacity, as in other editors; an object behind it is selected from the outliner. Only a surface's fully transparent parts, such as a texture's cut-out texels, let a click through.
- So the editor picks glass, and its tools and tested debug lines see it. Temporal AA and the exposure have already run, so the scene looks as the game's does.
- In a game without an editor, tested debug lines draw over transparent surfaces.

**The overdraw view.** The `Transparent_Overdraw` debug view counts the transparent layers at each pixel, sorted ones included: the moments pass adds 1 for each layer in place of its optical depth. It shows them as heat colors from 1 to 8. Additive surfaces have no moments, so the view leaves them out.

**Limits:**
- Transparent surfaces have no velocities, so temporal AA moves their pixels with the camera, and a moving transparent surface leaves a short trail.
- They cast no shadows, and the cooker turns `cast_shadows` off for them.
- The material previews draw a moment-based material as a sorted one, since they have one mesh.
- *Later:* weighted blended transparency for particles, where its approximation does not show.

## Future work

- **Weighted blended transparency** for particles and effects, where its approximation is not visible and moments cost too much. Do this with particles. Reference: McGuire and Bavoil 2013.
- **16-bit moments** with the paper's quantization, once the 32-bit cost shows. The formats and the bias are constants.
- **Material previews of moment-based materials** draw as sorted, since they have one mesh.

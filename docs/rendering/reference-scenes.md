# Reference scenes

A reference scene is a scene of the sample with a path traced image of the same view: Blender's Cycles, with the same geometry, materials, sun and camera. `tools/refdiff` compares the engine's image with it in linear light, so the global illumination can be tuned toward a known answer instead of toward what looks right (`samples/mygame/reference/`, `tools/refdiff`).

**In this document:** [The reference room](#the-reference-room) · [Comparing](#comparing) · [Measuring a change](#measuring-a-change) · [Making a reference](#making-a-reference) · [What the room shows](#what-the-room-shows)

## The reference room

`scenes/reference_room.scene`, from `samples/mygame/reference/room/reference.blend`: a closed box 4 m square and 21.4 m long, with walls 5.8 cm thick, under a black sky with no ambient light. A level sun of 1 W/m² comes through a window of 2 m × 2 m in the west wall. It lights a patch of the blue end wall and the corner of the east wall, and every other surface takes only its bounced light.

- **Geometry.** `models/reference_room/reference_room.gltf` is Blender's mesh, exported with +Y up. The exporter takes Blender's +z to glTF's +y and its +y to -z, and the cooker mirrors x (see [Meshes](../content/kinds/meshes.md#meshes)), so a point (x, y, z) in Blender is (-x, z, -y) in the scene. Its two slots are `Wall` and `Blue`.
- **Materials.** `reference_wall` and `reference_blue` are instances of the engine's default material, with the Principled BSDFs' base color, roughness and metallic: the walls 0.8 grey, roughness 0.2 and metallic 0.1, and the end wall (0.054, 0.025, 0.8), roughness 0.5. Blender's base colors are linear, as the engine's are.
- **The sun.** Blender's sun strength is its irradiance in W/m², and a `Directional_Light`'s `intensity` is the same: the hits' light is `albedo / π` times it. So the sun is 1, white, with Blender's angle of 0.526°. It travels along (0.926, 0.377, 0) in Blender, (-0.926, 0, -0.377) in the scene.
- **The camera.** At (0, 0, 20), looking down -z. Blender's lens of 80.74 mm on a sensor 36 mm wide gives 25.1° across, so at 16:9 the `Camera`'s `vertical_fov` is 0.2495 radians.
- **The volume.** A black `Environment` with no ambient light, `Manual` exposure of 2 (one stop, as the reference has), and AgX for viewing.

The Blender file's camera is a custom one with depth of field at f/2.8. The reference drops both for a plain perspective camera of the same lens, since the engine's image has neither (see [Making a reference](#making-a-reference)).

## Comparing

With the editor open on the scene (`just edit reference_room`), `just reference` compares the Game view with the reference:

```
just reference                                    # room, at Ultra
just reference room High 20 8 --probe 900,360     # a name, a preset, seconds to settle, screenshots, then refdiff's flags
```

- **The view.** It sets the Game view to the reference's 1280 × 720, at the preset, with the lit view, no exposure offset, `noToneMapping`, `noBloom` and `noPostEffects`, and the sun where the scene has it (`sunYaw` of 0), and waits for the light to settle. Then it takes the screenshots into `build/captures/reference/<name>`, and `refdiff` compares their mean, so the noise between frames does not count as error.
- **Linear light.** The reference is a 16-bit PNG of Blender's Standard view: sRGB-encoded scene-linear light, times its exposure of 2. Without tone mapping, the engine's output rolls off as `h / (1 + h)` before it encodes sRGB (see [Post-processing](post-processing.md#post-processing)), so `refdiff` undoes that with `c / (1 - c)` and divides by the scene's exposure of 2. Both are then radiance in the same units, and neither tone curve enters the comparison.
- **The report.** It gives each image's mean radiance and their difference in stops, by channel and in luminance, and the median, 90th and 99th percentiles of each pixel's difference in stops. A pixel darker than 10⁻⁴ in both images has no ratio. Then it gives the difference over a grid of 8 × 4 regions, top row first, with each region's reference luminance and then its capture's under it, and each `--probe` pixel's radiance in both.
- **The images.** `<preset>.ratio.png` is each pixel's difference: blue where the engine is darker, red where it is brighter and black where they agree, full at 2 stops, and grey where a pixel has no ratio. `<preset>.side.png` is the reference and the engine side by side, at one exposure and one curve.

The comparison needs a GPU and an editor, so `just test` does not run it. `refdiff`'s own tests check its decoding and its report.

## Measuring a change

A change to the global illumination is worth its cost when it brings the image nearer the reference, or keeps it as near with less noise or lag. Each setting needs runs of its own, each in an editor opened fresh, since runs of one setting differ too. The first run after its shaders are cooked again read up to 0.7% brighter in the dark half than the runs after it, so a run after a change is left out. The screenshots are 8 bits, and the room's dark half is near code 14, where a code is 7%, so a difference of under 1% between two settings is clearer with `REFERENCE_STOPS=3 just reference`, which takes the screenshots 3 stops brighter and tells `refdiff`, as the noise of each setting rounds its codes differently.

- **Accuracy:** `refdiff` of the mean of many screenshots, its mean and its pixels' and regions' stops.
- **Noise:** `refdiff` of single screenshots, whose stops grow with the noise, and [`flickerstat`](../editor/capture.md#flicker) over the screenshots of the lit view and of the `Gi_Diffuse` and `Gi_Specular` debug views. `Gi_Specular` is the world probes' radiance along each pixel's reflection, so it shows their noise, which the screen's own light can hide.
- **Lag:** `editorctl viewport --viewport 4 --set sunYaw=0.15` turns the sun, and its patch moves. The mean difference of the screenshots that follow from the view where it settles shows how fast the light follows.

The world probes' guided rays (#675) were measured so, two runs of each, at Ultra. With the guide, the mean luminance was 0.17 and 0.18 stops brighter than Cycles, against 0.19 in both runs without it. The dark half of the room was 0.77 to 1.09 stops brighter, against 0.88 to 1.11. The world probes' `Gi_Specular` view, which was the same in every screenshot without the guide (a median spread of 0 codes), flickered with it (0.23 and 0.29 codes, and a p99 step of 6.0 against 4.6 and 5.2). The lit view 1.65 s after a turn of the sun was 1.44 codes from where it settled, against 1.49. The change was not merged.

ReSTIR GI's brightness with and without the ray guide (#674) was measured so, with the mean of the dark half's regions, and without the spatial pass, the resolve's clamp or the filter, one at a time, to find which pass moved it (see [Ray guiding](global-illumination.md#ray-guiding)).

## Making a reference

`reference/<name>/render_reference.py` renders the reference from the `.blend` with Blender in the background, and exports the mesh:

```
blender --background reference.blend --python render_reference.py -- <out_dir> [samples]
```

It changes the scene in memory only, and does not save the `.blend`.

- **The camera** becomes a perspective camera of the same lens and sensor, with no depth of field.
- **The render** is 1280 × 720, 4096 samples without adaptive sampling, OpenImageDenoise, and on the GPU where Cycles has one. Cycles' clamps are off: they cut the indirect light's fireflies, which is a bias the engine does not have.
- **The images** are `reference.png`, 16-bit RGB in the Standard view at an exposure of one stop, which `refdiff` reads, and `reference_agx.png`, 8-bit in AgX at no exposure, to look at.
- **The mesh** is `reference_room.gltf` and its `.bin`, the room's object (`Cube.001`) alone, with +Y up. The room's copy in `models/` then had its mesh and materials renamed `Room`, `Wall` and `Blue` by hand, which name its slots.

A new reference is a folder of its own with these files, a model, materials and a scene made as the room's are, and `just reference <name>`.

## What the room shows

At first, on an RTX 5090, with 8 screenshots after 20 s:

| | Ultra (ReSTIR GI) | High (split cascades) |
|---|---|---|
| Mean luminance | +0.18 stops | +0.15 stops |
| Pixels' \|stops\|, p50 / p90 / p99 | 0.43 / 1.02 / 1.39 | 0.39 / 0.90 / 1.30 |
| The dark west half (2nd and 3rd columns) | +0.8 to +1.0 | +0.7 to +0.9 |
| The sunlit patch (centre right) | +0.05 to +0.1 | +0.03 to +0.08 |
| The east wall's sunlit corner (pixel 1155,360) | 0.197 against 0.155 | |

- **The indirect light is too bright.** Every surface that takes only bounced light is 0.7 to 1 stop brighter than Cycles, with both techniques, so the cause is likely what they share: the world probes, the hits' light, or the bounces past the first.
- **The direct light is right.** The sunlit blue patch is within a tenth of a stop. The east wall's sunlit corner is 0.35 stops brighter, which is the material model, not the global illumination: Cycles' Principled BSDF takes the diffuse's share from what the specular reflects, which at the camera's grazing angle there is most of it, and the engine's diffuse does not.
- **The corner is missing light.** Next to the east wall, the blue wall is darker than in Cycles (blue in the ratio map): the light that bounces between the sunlit corner and the end wall, a few centimeters apart, is lost.

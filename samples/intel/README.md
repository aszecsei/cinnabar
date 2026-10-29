# Intel sample

Scenes built from USD stages of Intel's [Graphics Research Samples Library](https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-research/samples.html): Sponza with its curtains, and Jungle Ruins (see [Jungle Ruins](#jungle-ruins)). The scenes are not in the repository, because they are several gigabytes. This sample holds only small wrapper stages that point at the downloads, and the `.meta` files that give everything that the stages make a stable GUID (see [Stages](../../docs/content/kinds/stages.md)).

## Getting the scenes

1. From the Samples Library page, download:
   - **Sponza Base Scene**, `main_sponza.zip`, about 4 GB.
   - **Sponza Curtains** add-on, `pkg_a_curtains.zip`, about 0.8 GB.
   - **Jungle Ruins**, `JungleRuins_1_0_1b.zip`, about 4.3 GB: <https://cdrdv2.intel.com/v1/dl/getContent/844047>.
2. Put the zips, as they are, in `samples/intel/downloads/`. Git ignores this folder.
3. Run `just intel-unpack`. It unpacks the USD files and the textures into `samples/intel/content/.unpacked/`, which Git and the cooker's scan both skip, and leaves out the 3ds Max, FBX, Blender and glTF versions.
4. Run `just game=intel dev`, or `just game=intel edit` to open the sample in the editor. The first cook takes several minutes, because each texture is block-compressed. Later cooks reuse the blobs.

Without the downloads, the stages warn that they are not cooked, the build still passes, and the game logs which stage is missing.

## Content

| Path | What it is |
|---|---|
| `content/sponza/sponza_main.usda` | Sublayers `main_sponza/NewSponza_Main_USD_Yup_003.usda`: 117 meshes, 3.7 million triangles, 28 materials, 98 textures. |
| `content/sponza/sponza_curtains.usda` | Sublayers `pkg_a_curtains/NewSponza_Curtains_USD_YUp.usda`. It is a stage of its own, because it defines the same material prims as the main stage, and one stage would merge them. |
| `content/scenes/main.scene` | Places both Sponza prefabs, with a camera, a sun and a global volume. |
| `content/jungle/jungle_ruins.usda` | Sublayers `JungleRuins/USD/JungleRuins_Karma.usda`: 197 meshes of 18.6 million triangles, 53 of them the prototypes that its 778 point instancers share, 198 textures, 87 materials, and an instance set of each instancer, 8.7 million instances in all. Its `.meta` file turns on impostors. |
| `content/scenes/jungle.scene` | Places the Jungle Ruins prefab, with a camera where the stage's default camera is, a sun and a global volume. Open it in the editor. |

`just intel-report` prints what each stage makes against the renderer's limits: the prims, meshes, triangles, materials, textures and instances.

Sponza's dirt decals (`decals_1st_floor`, `decals_2nd_floor` and `decals_3rd_floor`) are quads on the walls, which flicker where they z-fight with them, until the engine has decals (see [Stages: Limits](../../docs/content/kinds/stages.md#limits)).

### Jungle Ruins

`just intel-unpack` unpacks Jungle Ruins too. Its first cook takes about 8 minutes and 18 GB of memory. Its foliage is point instancers, which draw as one `Instanced_Mesh_Renderer` each (see [GPU scene](../../docs/rendering/gpu-scene.md#instanced-meshes)). How it draws:

- **Speed.** A frame of the editor's view of it takes about 38 ms on an RTX 5090, 25 ms of it on the CPU. Without mesh shaders, the instances draw at their meshes' finest level until their impostors take over, about 800 ms.
- **Textures.** Its plants' textures are TIFF, which the cooker reads. The palm trunks' normal and roughness maps are OpenEXR in DWAA compression, which TinyEXR does not decode, so the stage warns, and the trunks take their materials' values.
- **Sky.** The stage's DomeLight is its sky, `kloppenheim_06_puresky_8k.hdr`, as a texture sky and its ambient light. The scene's sun is placed by hand, and is not yet aimed at the image's sun.

## Credits and licenses

The scenes are Intel's, distributed by Intel and not by this repository. Each download has a `credits_license.txt`, which `just intel-unpack` copies beside the stage's files. Read it before you use the scenes.

**Sponza**, from its `credits_license.txt`:

> Sponza 2022 Scene commissioned by Frank Meinl, sponsored by Anton Kaplanyan.
>
> For personal use and educational use. Limited commercial use for marketing and print purposes.

The file then gives the text of the Creative Commons Attribution 4.0 International Public License. It asks a publication to cite:

```bibtex
@misc{sponza22,
Author = {Frank Meinl and Anton Kaplanyan},
Year = {2022},
Note = {https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-processing-research/samples.html},
Title = {Intel Sample Library}
}
```

The curtains are an add-on, by the Sponza Addon Package Crew: Katica Putica, Cristiano Siqueira, Timothy Heath, Justin Prazen, Sebastian Herholz, Bruce Cherniak and Anton Kaplanyan.

**Jungle Ruins**, from its `credits_license.txt`: created by Cristiano Siqueira, with artistic support from Charlene Teets, under the Creative Commons Attribution 4.0 International Public License. It asks a publication to cite:

```bibtex
@misc{jungleruins,
Author = {Cristiano Siqueira and Charlene Teets and Sebastian Herholz and Anton Sochenov and Anton Kaplanyan},
Year = {2024},
Note = {https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-processing-research/samples.html},
Title = {Intel Sample Library}
}
```

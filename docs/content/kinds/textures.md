# Textures

Textures are `.png`, `.jpg`, `.tga` and `.hdr` files, read with `vendor:stb/image`. `just textures` runs `cook textures --cache build/<target>/content --config dev|release` with the roots.

| Setting | Values | Default | Effect |
|---|---|---|---|
| `usage` | `color`, `normal`, `mask`, `hdr`, `data` | From the name, see below | Selects the format and the mip filter |
| `mips` | `true`, `false` | `true` | Make the full mip chain |
| `max_size` | `256` to `16384` | `16384` | Halve the texture until its larger side fits |
| `wrap` | `repeat`, `clamp` | `repeat` | The edge mode of the mip filter. The sampler is the material's choice. |
| `filter` | `kaiser`, `box` | `kaiser` | The mip filter: the Kaiser-windowed sinc below, or the plain average of the covered texels, whose weights are never negative, so a mask's mips are the share of its texels that are set, which a [surface's hole mask](../../rendering/surfaces.md#holes) needs |

| Usage | Format | Mips |
|---|---|---|
| `color` | BC7, sRGB. Alpha is kept. | Filtered in linear light |
| `normal` | BC5 (x and y; shaders compute z) | Filtered, then normalized again |
| `mask` | BC4 (one channel: roughness, occlusion, height, a parallax height map) | Filtered |
| `hdr` | BC6H, unsigned | Filtered |
| `data` | `RGBA8_Unorm`, not compressed | Filtered |

- **The default usage** comes from the file when the cooker writes its `.meta` file: `.hdr` is `hdr`, a name ending in `_n` or `_normal` is `normal`, a name ending in `_r`, `_rough`, `_ao`, `_m`, `_metal`, `_mask`, `_height` or `_hole` is `mask`, and everything else is `color`. The setting is then written in the `.meta` file, so a rename does not change it.
- **Size:** a texture larger than `max_size` halves until it fits. Mip 0 of a block-compressed texture is whole 4×4 blocks on the GPU (see [GPU](../../gpu/README.md)), so a texture whose sides are not multiples of 4 is resized up to the next ones.
- **Mips** use a Kaiser-windowed sinc filter, which widens with the scale when it shrinks, in floating point. Each mip filters from the one before it, and normal maps are normalized again after each step.
- **BC6H** interpolates its endpoints' half-float bits, which are close to logarithmic, so a 4×4 block that holds both 0 and bright values has coarse steps between them.
- **Quality:** development compresses at Compressonator's quality 0.05, and release at 0.5. The configuration is in the key, so release textures cook again in a release cook.
- **The cache key** covers the cooker version, the Compressonator version, the configuration, the source and the `.meta` file.

# Textures

Textures are `.png`, `.jpg`, `.tga`, `.hdr`, `.tif` and `.exr` files, and `.texture_set` files that name such images as the layers of a cube map or an array (see [Cube maps and arrays](#cube-maps-and-arrays)). `just textures` runs `cook textures --cache build/<target>/content --config dev|release` with the roots.

- **Decoders,** picked by a file's first bytes: OpenEXR by `vendor:OpenEXRCore`, which only the cooker links (`tools/cook/exr.odin`); TIFF by the cooker's own baseline reader (`tools/cook/tiff.odin`); and the rest by `vendor:stb/image`.
- **TIFF:** the first image of the file, in strips, uncompressed, PackBits, LZW or Deflate, with or without the horizontal predictor, of 8- or 16-bit unsigned or 32-bit float samples, gray or RGB, with or without alpha. A tiled TIFF, one with separate planes, another compression or another kind of sample is an error that says which.
- **OpenEXR:** the data window of the first part, as RGBA floats, in scanlines or tiles, in any compression, DWAA and DWAB included. A tiled image with mips gives its largest level, and the cooker makes its own mips. Its channels are half or float: `R`, `G` and `B`, and `A` if it has it, or else opaque. Other channels, such as `Z` or another layer's, are ignored. One channel of any name is gray and opaque. Deep data, no plain `R`, `G` and `B`, and a read channel that is `uint` or subsampled are each an error that says which.
- **Linear images.** An `.exr`, an `.hdr` and a TIFF of floats hold linear values, so a `color` texture takes them as they are, where it decodes an 8- or 16-bit image from sRGB. A `normal` and a `mask` texture treat them as they treat any image's values.

| Setting | Values | Default | Effect |
|---|---|---|---|
| `usage` | `color`, `normal`, `mask`, `hdr`, `data` | From the name, see below | Selects the format and the mip filter |
| `mips` | `true`, `false` | `true` | Make the full mip chain |
| `max_size` | `256` to `16384` | `16384` | Halve the texture until its larger side fits |
| `wrap` | `repeat`, `clamp` | `repeat` | The edge mode of the mip filter. The sampler is the material's choice. |
| `filter` | `kaiser`, `box` | `kaiser` | The mip filter: the Kaiser-windowed sinc below, or the plain average of the covered texels, whose weights are never negative, so a mask's mips are the share of its texels that are set, which a [surface's hole mask](../../rendering/surfaces.md#holes) needs |
| `alpha_coverage` | `true`, `false` | `false` | For a `color` texture, keep each mip's alpha coverage at `alpha_cutoff`, see below |
| `alpha_cutoff` | `0.05` to `0.95`, in steps of `0.05` | `0.5` | The cutoff that `alpha_coverage` keeps the coverage at |
| `layout` | `2d`, `cube_cross`, `cube_equirect`, `array_strip` | `2d` | How one image holds its layers, see [Cube maps and arrays](#cube-maps-and-arrays) |
| `standalone` | `true`, `false` | `true` | Cook the image as a texture of its own. Turn it off for an image that only a `.texture_set` or a [sprite sheet](sprite-sheets.md#packed-images) reads. |

| Usage | Format | Mips |
|---|---|---|
| `color` | BC7, sRGB. Alpha is kept. | Filtered in linear light |
| `normal` | BC5 (x and y; shaders compute z) | Filtered, then normalized again |
| `mask` | BC4 (one channel: roughness, occlusion, height, a parallax height map) | Filtered |
| `hdr` | BC6H, unsigned | Filtered |
| `data` | `RGBA8_Unorm`, not compressed | Filtered |

- **The default usage** comes from the file when the cooker writes its `.meta` file: `.hdr` and `.exr` are `hdr`, a name ending in `_n` or `_normal` is `normal`, a name ending in `_r`, `_rough`, `_ao`, `_m`, `_metal`, `_mask`, `_height` or `_hole` is `mask`, a name ending in `_weather` is `data`, and everything else is `color`. The setting is then written in the `.meta` file, so a rename does not change it.
- **Weather maps** are `data` textures whose R, G and B are the clouds' coverage, precipitation and type (see [Clouds](../../rendering/clouds.md#weather)). The clouds read the map at level 0, so its mips do not matter, and the samples' maps are cooked with `mips = false`. `just sample-weather` writes them (`tools/weather_map.py`): `samples/intel/content/textures/sponza_weather.png` and `samples/mygame/content/textures/glass_weather.png`, 512 texels square and tileable, from seeded noise.
- **Size:** a texture larger than `max_size` halves until it fits. Mip 0 of a block-compressed texture is whole 4×4 blocks on the GPU (see [GPU](../../gpu/README.md)), so a texture whose sides are not multiples of 4 is resized up to the next ones.
- **Mips** use a Kaiser-windowed sinc filter, which widens with the scale when it shrinks, in floating point. Each mip filters from the one before it, and normal maps are normalized again after each step.
- **Alpha coverage:** filtering pulls a [masked material's](materials.md) thin cut-outs below its cutoff, so foliage thins out in the distance. With `alpha_coverage`, the cooker measures the share of mip 0's texels at or above `alpha_cutoff`, and scales the alpha of each smaller mip so that the same share is. It finds each scale by bisection, as NVIDIA Texture Tools does, from 0 to 16 in 16 steps. Mip 0 stays as it is, and each mip still filters from the one before it unscaled, so no scale feeds down the chain. The cooker cooks a texture without its material, so `alpha_cutoff` should be the `cutoff` of the material that reads it, or the nearest step. Other usages ignore both settings, and so do a [stage's](stages.md) textures, which have no settings of their own. The sample's `scenes/billboards.scene` compares a texture with and without it.
- **BC6H** interpolates its endpoints' half-float bits, which are close to logarithmic, so a 4×4 block that holds both 0 and bright values has coarse steps between them.
- **Quality:** development compresses at Compressonator's quality 0.05, and release at 0.5. The configuration is in the key, so release textures cook again in a release cook.
- **The cache key** covers the cooker version, the Compressonator and OpenEXRCore versions, the configuration, the source and the `.meta` file. A `.texture_set`'s also covers the bytes of the images that it names.

## Cube maps and arrays

A texture is 2D, a cube map or an array. A cube map has six square layers, its faces, in the order +x, -x, +y, -y, +z, -z. An array has 1 to 2048 layers of one size. Each layer has its own mip chain and block compression, with the same format and settings. The sample's `textures/cube` has one of each source, and its `scenes/cube_sky.scene` draws a cube map as its sky.

- **A face's orientation** is what a `TextureCube` reads, so a direction in the world reads its own light with no conversion. Looking along +z with +y up, +x is to the right. The side faces go on from there with +y up: +x has -z to its right, -z has -x, and -x has +z. +y has +z at its bottom edge, and -y has +z at its top edge, each with +x to its right.
- **Mips:** a cube's faces filter with clamped edges, whatever `wrap` says, since a face's edge meets another face and not its own far edge.

**One image** holds its layers by its `layout` setting. The usage and the other settings are the image's.

| `layout` | The image | Makes |
|---|---|---|
| `cube_cross` | A cross of square faces. Across, 4 faces by 3: +y above +z, -y below it, and in the middle row -x, +z, +x and -z. Or down, 3 faces by 4: the same with -z below -y, turned by half a turn. | A cube map |
| `cube_equirect` | An equirectangular image, twice as wide as it is tall, in the [Texture sky's mapping](../../rendering/sky.md#texture). Each face is a quarter of its width, sampled bilinearly. | A cube map |
| `array_strip` | Square layers, one above the other, layer 0 at the top | An array |

An image of another shape is an error that says what it needs.

### Texture sets

A `.texture_set` is a text file that names the images of a cube map or an array by GUID, as content always refers to content (see [Identity](../identity-and-cooking.md#identity)). It is a texture asset itself, and its blob is what readers use. Blank lines and lines that start with `#` are ignored.

```
# A cube map: all six faces.
px = $c0be0000000000000000000000000000
nx = $c0be0000000000000000000000000001
py = $c0be0000000000000000000000000002
ny = $c0be0000000000000000000000000003
pz = $c0be0000000000000000000000000004
nz = $c0be0000000000000000000000000005
```

```
# An array: its layers in order.
layer = $c0be0000000000000000000000000020
layer = $c0be0000000000000000000000000021
```

- **Settings:** the set's `.meta` file holds `usage`, `mips`, `max_size`, `filter` and the alpha settings, for every layer. An image's own settings do not apply, and changing them does not cook the set again. An image whose `usage` is not the set's is a warning, so that HDR faces do not clamp in a set that is left at `color`. A new set's `usage` is `color`.
- **Errors**, each naming the file and, where it has one, the line: a key other than the faces' and `layer`, a face named twice or missing, faces with layers, no images, more than 2048 layers, a GUID that no asset has, a name that is not an image or is an image with its own `layout`, images of different sizes, and a cube's faces that are not square. A set with a `layout` other than `2d`, or with `standalone = false`, is also an error.
- **`standalone`:** an image in a set is still an asset, with a GUID and its own blob, so it compresses twice unless its `.meta` file says `standalone = false`. Then it has no blob, and a blob that it has from before is deleted, so that it cannot keep drawing. Its set reads its source all the same. An image with `standalone = false` that no set names is a warning, since nothing cooks it, and a reader that names it draws its default and logs that it is not cooked.
- **Dependencies:** a set depends on its images, which the editor's Depends On and Used By show. The editor has no panel for a set's contents: edit its text.

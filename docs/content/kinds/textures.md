# Textures

Textures are `.png`, `.jpg`, `.tga`, `.hdr`, `.tif` and `.exr` files, and `.texture_set` files that name such images as the layers of a cube map or an array (see [Cube maps and arrays](#cube-maps-and-arrays)). `just textures` runs `cook textures --cache build/<target>/content --config dev|release` with the roots.

- **Decoders,** picked by a file's first bytes: OpenEXR by `vendor:OpenEXRCore`, which only the cooker links (`tools/cook/exr.odin`); TIFF by the cooker's own baseline reader (`tools/cook/tiff.odin`); and the rest by `vendor:stb/image`, which keeps the 16 bits of a 16-bit PNG.
- **TIFF:** the first image of the file, in strips, uncompressed, PackBits, LZW or Deflate, with or without the horizontal predictor, of 8- or 16-bit unsigned or 32-bit float samples, gray or RGB, with or without alpha. A tiled TIFF, one with separate planes, another compression or another kind of sample is an error that says which.
- **OpenEXR:** the data window of the first part, as RGBA floats, in scanlines or tiles, in any compression, DWAA and DWAB included. A tiled image with mips gives its largest level, and the cooker makes its own mips. Its channels are half or float: `R`, `G` and `B`, and `A` if it has it, or else opaque. Other channels, such as `Z` or another layer's, are ignored. One channel of any name is gray and opaque. Deep data, no plain `R`, `G` and `B`, and a read channel that is `uint` or subsampled are each an error that says which.
- **Linear images.** An `.exr`, an `.hdr` and a TIFF of floats hold linear values, so a `color` texture takes them as they are, where it decodes an 8- or 16-bit image from sRGB. A `normal` and a `mask` texture treat them as they treat any image's values.

The settings are in four groups: those at the top of the `.meta` file, then those under `[mip_map]`, `[sampler]` and `[streaming]` (see [Identity](../identity-and-cooking.md#identity)). A section lasts to the next one or to the end of the file. For example:

```
guid = 1d5f7a9c3e2b4d6f8a0c2e4f6b8d0a2c
usage = mask

[mip_map]
kernel = box

[sampler]
wrap = clamp
```

| Setting | Values | Default | Effect |
|---|---|---|---|
| `usage` | `color`, `normal`, `mask`, `hdr`, `data`, `height` | From the name, see below | Selects the format and the mip filter |
| `max_size` | `256` to `16384` | `16384` | Halve the texture until its larger side fits |
| `alpha_coverage` | `true`, `false` | `false` | For a `color` texture, keep each mip's alpha coverage at `alpha_cutoff`, see below |
| `alpha_cutoff` | `0.05` to `0.95`, in steps of `0.05` | `0.5` | The cutoff that `alpha_coverage` keeps the coverage at |
| `layout` | `2d`, `cube_cross`, `cube_equirect`, `array_strip` | `2d` | How one image holds its layers, see [Cube maps and arrays](#cube-maps-and-arrays) |
| `standalone` | `true`, `false` | `true` | Cook the image as a texture of its own. Turn it off for an image that only a `.texture_set` or a [sprite sheet](sprite-sheets.md#packed-images) reads. |

| `[mip_map]` | Values | Default | Effect |
|---|---|---|---|
| `enabled` | `true`, `false` | `true` | Make the full mip chain |
| `kernel` | `kaiser`, `box` | `kaiser` | The filter that makes each mip: the Kaiser-windowed sinc below, or the plain average of the covered texels, whose weights are never negative, so a mask's mips are the share of its texels that are set, which a [surface's hole mask](../../rendering/surfaces.md#holes) needs |
| `linear` | `true`, `false` | `true` | For a `color` texture, filter in linear light. `false` filters the stored sRGB values, which keeps dark detail darker in the distance. Other usages ignore it, with a warning. |
| `border` | `true`, `false` | `false` | Keep each mip's outermost texels the color of mip 0's edge, see below |
| `fadeout` | `true`, `false` | `false` | Fade the mips from `fade_start` to `fade_end` toward a neutral value, see below |
| `fade_start` | `1` to `13` | `1` | The last mip that `fadeout` leaves as it is |
| `fade_end` | `1` to `13` | `3` | The first mip that `fadeout` makes wholly neutral. It must be after `fade_start`. |

| `[sampler]` | Values | Default | Effect |
|---|---|---|---|
| `wrap` | `repeat`, `clamp`, `mirror` | `repeat` | What sampling reads past the edges, and what the mip filter reads across them |
| `filter` | `linear`, `nearest` | `linear` | How sampling blends texels when the texture is magnified or minified |
| `mip_filter` | `linear`, `nearest` | `linear` | How sampling blends mips |
| `anisotropy` | `1`, `2`, `4`, `8`, `16` | `8` | The most texels that sampling takes along a surface seen at a slant. `1` is none. It needs `filter = linear`, or it is a warning. |

| `[streaming]` | Values | Default | Effect |
|---|---|---|---|
| `virtual` | `true`, `false` | `true` | Cook a large 2D `color`, `normal` or `mask` texture as pages that stream, see [Virtual textures](#virtual-textures). `false` cooks it whole. |

**Moved settings.** `mips`, `filter` and `wrap` at the top of a `.meta` file are errors that say where each went: `[mip_map] enabled`, `[mip_map] kernel` and `[sampler] wrap`.

| Usage | Format | Mips |
|---|---|---|
| `color` | BC7, sRGB. Alpha is kept. | Filtered in linear light |
| `normal` | BC5 (x and y; shaders compute z) | Filtered, then normalized again |
| `mask` | BC4 (one channel: roughness, occlusion, height, a parallax height map) | Filtered |
| `hdr` | BC6H, unsigned | Filtered |
| `data` | `RGBA8_Unorm`, not compressed | Filtered |
| `height` | `R16_Unorm`, not compressed (one channel of 16 bits: a [surface's](../../rendering/surfaces.md#limits) height map, which 8 bits would terrace) | Filtered |

- **The default usage** comes from the file when the cooker writes its `.meta` file: `.hdr` and `.exr` are `hdr`, a name ending in `_n` or `_normal` is `normal`, a name ending in `_r`, `_rough`, `_ao`, `_m`, `_metal`, `_mask`, `_height` or `_hole` is `mask`, a name ending in `_weather` is `data`, and everything else is `color`. The setting is then written in the `.meta` file, so a rename does not change it. No name gives `height`: set it on a height map whose steps show, such as the sample's `terrain_height.png`, a 16-bit PNG.
- **Weather maps** are `data` textures whose R, G and B are the clouds' coverage, precipitation and type (see [Clouds](../../rendering/clouds.md#weather)). The clouds read the map at level 0, so its mips do not matter, and the samples' maps are cooked with `[mip_map] enabled = false`. `just sample-weather` writes them (`tools/weather_map.py`): `samples/intel/content/textures/sponza_weather.png` and `samples/mygame/content/textures/glass_weather.png`, 512 texels square and tileable, from seeded noise.
- **Size:** a texture larger than `max_size` halves until it fits. Mip 0 of a block-compressed texture is whole 4×4 blocks on the GPU (see [GPU](../../gpu/README.md)), so a texture whose sides are not multiples of 4 is resized up to the next ones. A `data` or `height` texture is not compressed, so it keeps its size.
- **Mips** use a Kaiser-windowed sinc filter, which widens with the scale when it shrinks, in floating point. Each mip filters from the one before it, and normal maps are normalized again after each step. The filter reads past the edges as `[sampler] wrap` says.
- **Border:** with `border`, each mip's outermost ring of texels is set from mip 0's edge on the same side, each texel the average of the edge texels that it covers. The ring feeds down the chain, so a clamped texture, such as a light's cookie or a decal, keeps its edge's color in the distance instead of the inside's. A cube cannot keep a border, since its faces' edges would show as seams.
- **Fadeout:** with `fadeout`, mip `m` is `(m - fade_start) / (fade_end - fade_start)` of the way to a neutral value, up to all of it: mid gray (sRGB 0.5) for `color`, a flat normal for `normal`, and 0.5 for `mask`, `data` and `height`. Alpha stays. Only what each mip stores fades, so the next mip still filters from the unfaded one. `hdr` has no neutral value, so `fadeout` on it is an error.
- **Alpha coverage:** filtering pulls a [masked material's](materials.md) thin cut-outs below its cutoff, so foliage thins out in the distance. With `alpha_coverage`, the cooker measures the share of mip 0's texels at or above `alpha_cutoff`, and scales the alpha of each smaller mip so that the same share is. It finds each scale by bisection, as NVIDIA Texture Tools does, from 0 to 16 in 16 steps. Mip 0 stays as it is, and each mip still filters from the one before it unscaled, so no scale feeds down the chain. The cooker cooks a texture without its material, so `alpha_cutoff` should be the `cutoff` of the material that reads it, or the nearest step. Other usages ignore both settings, and so do a [stage's](stages.md) textures, which have no settings of their own. The sample's `scenes/billboards.scene` compares a texture with and without it.
- **BC6H** interpolates its endpoints' half-float bits, which are close to logarithmic, so a 4×4 block that holds both 0 and bright values has coarse steps between them.
- **Quality:** development compresses at Compressonator's quality 0.05, and release at 0.5. The configuration is in the key, so release textures cook again in a release cook.
- **Stage textures** take the `[sampler]` defaults, but for their USD `wrapS` and `wrapT`: both `repeat` repeat, both `mirror` mirror, and anything else clamps.
- **The cache key** covers the cooker version, the Compressonator and OpenEXRCore versions, the configuration, the source and the `.meta` file. A `.texture_set`'s also covers the bytes of the images that it names.

## Virtual textures

A texture is **virtual** when it is 2D, its usage is `color`, `normal` or `mask`, it has mips, a side of its mip 0 is over 128 texels, and `[streaming] virtual` is not `false`. Any other texture, a cube, an array, `hdr`, `data` and `height` included, cooks whole, as above. The blob has `Texture_Flag.Virtual`, no `mips`, and these instead (`format/texture.odin`). It follows a [paged mesh](meshes.md#pages).

- **Pages.** Each mip from 0 up to `tail_mip` is cut into tiles of 128 by 128 texels. A `Texture_Level` holds its mip's `size`, its `grid` of pages across and down, and its `first_page`. The pages of the `pages` table are level by level, and row by row in a level.
- **Tail:** `tail_mip` is the first mip whose sides are both at most 64. Its mips on, down to 1 by 1, are `tail`, packed as `mips` is and not compressed. The last paged mip has both sides at most 128, so it is one page: the **root**, flagged `Root`.
- **A page** is a tile of 136 by 136 texels, its 128 and a border of 4 on each side, block-compressed in the texture's format, with its rows of blocks tightly packed, and then LZ4 compressed. A `Texture_Page` holds its block's `offset`, `compressed_size` and decompressed `size`, an `fnv32a` `checksum` of the compressed bytes, and its `mip`, `x` and `y`, which the table's order gives and the view checks.
- **Borders** are real texels: the cooker cuts each tile from the mip's texels before it encodes them, so a texel past the mip's edge is what `[sampler] wrap` reads there (`edge` in `textures.odin`), and an inner border is the neighbouring page's texels. A mip that is smaller than its tile fills the rest of the tile the same way. The encoder takes each 4 by 4 block from its own texels, so a tile's inner blocks are the blocks of the whole mip, which the tests compare.
- **Blob order:** the header, `levels`, `pages`, `tail` and the source path, then the root's block, which ends the **head** (`head_size`), then every other page's block, each at `BLOB_ALIGN`. `file_size` is the whole blob. A reader that holds only the head views it with `texture_view`, which checks the levels, the page table and the tail. `texture_head_size` gives the head's size, and `asset.read_head` reads only that, as it does for a paged mesh. A texture that is not virtual has `head_size` and `file_size` of its whole size.
- **Helpers:** `texture_page_payload_size(format)`, `texture_page_level(levels, page)`, and `texture_page_strip(format, payload, level, page_x, page_y, dst_mip)`, which copies a page's own 128 by 128 texels' blocks, clipped to the mip, into a whole mip.
- **Whole mips:** a reader that needs a texture's texels, not samples, assembles them from the pages with `asset.texture_page_place`, which checks a block's checksum, decompresses it and strips it into a mip. The renderer does so for the readers that cannot sample pages (see [Assets](../../rendering/assets.md#virtual-textures)), and `asset.texture_mip0` reads mip 0 from the blob's file at once, which a [height field's](../../physics/design.md#shapes) hole mask needs.
- **Cook:** the cooker's version is `textures 3`, so every texture cooks again.
- **Thumbnails** of a virtual texture are from its tail's largest mip.

## Cube maps and arrays

A texture is 2D, a cube map or an array. A cube map has six square layers, its faces, in the order +x, -x, +y, -y, +z, -z. An array has 1 to 2048 layers of one size. Each layer has its own mip chain and block compression, with the same format and settings. The sample's `textures/cube` has one of each source, and its `scenes/cube_sky.scene` draws a cube map as its sky.

- **A face's orientation** is what a `TextureCube` reads, so a direction in the world reads its own light with no conversion. Looking along +z with +y up, +x is to the right. The side faces go on from there with +y up: +x has -z to its right, -z has -x, and -x has +z. +y has +z at its bottom edge, and -y has +z at its top edge, each with +x to its right.
- **Mips:** a cube's faces filter with clamped edges, whatever `[sampler] wrap` says, since a face's edge meets another face and not its own far edge.

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

- **Settings:** the set's `.meta` file holds `usage`, `max_size`, the alpha settings, `[mip_map]` and `[sampler]`, for every layer. An image's own settings do not apply, and changing them does not cook the set again. An image whose `usage` is not the set's is a warning, so that HDR faces do not clamp in a set that is left at `color`. A new set's `usage` is `color`.
- **Errors**, each naming the file and, where it has one, the line: a key other than the faces' and `layer`, a face named twice or missing, faces with layers, no images, more than 2048 layers, a GUID that no asset has, a name that is not an image or is an image with its own `layout`, images of different sizes, and a cube's faces that are not square. A set with a `layout` other than `2d`, or with `standalone = false`, is also an error.
- **`standalone`:** an image in a set is still an asset, with a GUID and its own blob, so it compresses twice unless its `.meta` file says `standalone = false`. Then it has no blob, and a blob that it has from before is deleted, so that it cannot keep drawing. Its set reads its source all the same. An image with `standalone = false` that no set names is a warning, since nothing cooks it, and a reader that names it draws its default and logs that it is not cooked.
- **Dependencies:** a set depends on its images, which the editor's Depends On and Used By show. The editor has no panel for a set's contents: edit its text.

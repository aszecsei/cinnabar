# Sprite sheets

A sprite sheet is a `.sprite_sheet` text file in the content roots: the frames of a texture, and the animations that play them. A `Sprite_Renderer` draws a frame of one (see [Rendering](../../rendering/README.md)). `just sprite_sheets` runs `cook sprite_sheets --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`, and the daemon cooks them like any other kind (`tools/cook/sprite_sheets.odin`).

**In this document:** [The text](#the-text) · [Packed images](#packed-images) · [A texture's frames](#a-textures-frames) · [Imported descriptions](#imported-descriptions) · [Animations](#animations) · [The cook](#the-cook) · [The blob](#the-blob)

## The text

A sheet is lines of `key = value`, and `#` comments. It names its frames in one of three ways, and never two of them: [images that the cooker packs](#packed-images), [a texture with a grid or rectangles](#a-textures-frames), or [a texture with an exported description](#imported-descriptions).

```
pixels_per_unit = 16
filter = nearest
pivot = 0.5 0
frame idle_0 = $6f1c2a9e4b7d4c0e9a3f5d8b1e2c7a40
frame idle_1 = $6f1c2a9e4b7d4c0e9a3f5d8b1e2c7a41
animation idle = idle_0 idle_1 rate=4
```

| Key | Value | Default |
|---|---|---|
| `pixels_per_unit` | The texture's texels to a meter, so a frame of 16 texels at 16 is 1 m wide | `DEFAULT_PIXELS_PER_UNIT` (100) |
| `filter` | `linear`, or `nearest`, which keeps pixel art's texels sharp | `linear` |
| `pivot` | The point of a frame that is at its entity's position: a share of the frame's width and of its height, from its bottom left | `0.5 0.5`, the middle |
| `frame <name>` | `$guid` of an image, which the cooker packs | |
| `texture` | `$guid` of the texture that holds the frames | |
| `grid` | `columns rows`, then a margin and a spacing in texels if the texture has them | |
| `rect <name>` | `x y width height` in texels from the texture's top left | |
| `import` | The path of a JSON description, from the sheet's directory | |
| `animation <name>` | Frames, then `rate=` and `loop=` (see [Animations](#animations)) | |

A new sheet from the editor's New Sprite Sheet command is comments that show the three ways (`SPRITE_SHEET_TEMPLATE`).

## Packed images

`frame <name> = $guid` names an image, a texture asset of one 2D image. The cooker decodes each image and packs them all into an atlas with `vendor:stb/rect_pack` (`pack_rects`, which the [fonts](fonts.md#the-atlas) use too).

- **The atlas** is the smallest of sides that are powers of two that holds every frame, at most `MAX_SPRITE_ATLAS` (4096) on a side, with its height cut to the last row and rounded up to whole blocks of 4 texels. It is the sheet's Texture sub-asset named `atlas`, and the sheet's `.meta` file holds its GUID as `texture.atlas = <guid>`. It cooks as a color texture without mips.
- **Each frame** has `SPRITE_ATLAS_BORDER` (1) texel of its own edge again around it, so a filtered lookup at its edge reads no neighbour.
- **The images** are textures of their own too. An image that only sheets use sets `standalone = false` in its `.meta` file, so it has no blob of its own (see [Textures](textures.md#texture-sets)): a sheet that names it counts as a texture set does.

## A texture's frames

`texture = $guid` names a texture asset that already holds the frames.

- **`grid = columns rows [margin spacing]`** cuts it into equal cells, which must divide the texture evenly. The frames are named by their index, `0`, `1` and on, by rows from the top left.
- **`rect <name> = x y width height`** names one frame. A sheet can have both a grid and rects; the rects come after the grid's frames.
- The rectangles are in the texels of the texture's source image. The texture cooks by its own import settings, and a frame is a share of it, so a texture that cooks smaller draws the same frames. A source whose sides are not multiples of 4 is resampled to whole blocks when it cooks, which blurs pixel art: give such a texture sides that are multiples of 4.

## Imported descriptions

`import = <file>.json`, with `texture = $guid`, reads the JSON that Aseprite exports beside a sheet's image (File, Export Sprite Sheet, JSON Data), with its frames as a hash or as an array, or TexturePacker's JSON, which has the same shape (`sprite_sheet_import`).

- **A frame's name** is its key in the hash, or its `filename` in the array, as it is in the file. The frames are in the file's order.
- **`frame`** is the rectangle. **`duration`**, in milliseconds, is how long an animation shows the frame. **`pivot`**, which TexturePacker writes, is the frame's own, from its top left; a frame without one takes the sheet's.
- **`meta.frameTags`** are animations: the frames from `from` to `to`, in the direction `forward`, `reverse` or `pingpong`.
- A rotated frame fails: export without rotation. Trimming is not undone: a trimmed frame draws as its trimmed rectangle.
- The JSON file is not an asset and has no `.meta` file. It is an input of the sheet, so a change to it cooks the sheet again.

A sheet with an import can add `animation` lines of its own, and cannot have a grid or rects.

## Animations

`animation <name> = <frames> [rate=<frames a second>] [loop=true|false]`.

- **A frame** is a frame's name, an index from 0 in the sheet's order, or a range of indices `a..b`, which runs either way.
- **`rate`** is `DEFAULT_SPRITE_RATE` (10) by default. A frame with a duration of its own, from an import, shows for that long whatever the rate.
- **`loop`** is true by default. An animation that does not loop stays on its last frame.
- A `Sprite_Renderer` plays an animation by its index, and a script plays it by name.

## The cook

- **The cache key** covers the cooker's sprite sheet and texture versions, the configuration, the source path, the layouts of both blobs, the sheet's text, its GUID and its atlas's, the sources of the images or of the texture that it names, and the imported JSON. A packed sheet is up to date when both of its blobs have the key.
- **Dependencies:** the images or the texture are the sheet's dependencies, so the daemon looks at the sheet again when one changes.
- **A sheet with errors** keeps its old blob, so the running game keeps the last good version. Each error names its line: an unknown key, a frame or an animation named twice, a GUID that no image has, a grid that does not divide the texture, a frame outside the texture, or an animation's frame that the sheet does not have.

## The blob

A sprite sheet blob (`lib/engine/asset/format/sprite_sheet.odin`) holds the atlas's GUID, the size that the frames' rectangles are in, `pixels_per_unit`, the filter, the frames (`Sprite_Frame`: rectangle, pivot, duration and name), the animations (`Sprite_Animation`: name, its range of the frame indices, rate and loop), the frame indices as `u16`, and the source path. A sheet has at most `MAX_SPRITE_FRAMES` (65535) frames and `MAX_SPRITE_ANIMATIONS` (65534) animations. `sprite_sheet_view` checks a blob, `sprite_sheet_find_frame` and `sprite_sheet_find_animation` look one up by name, and `sprite_sheet_frame_at` gives the frame that an animation shows at a time.

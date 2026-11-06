# Fonts

Fonts are `.ttf`, `.otf` and `.ttc` files in the content roots, which UI text is shaped and drawn with. `just fonts` runs `cook fonts --cache build/<target>/content --config dev|release --root game=<content root> --root engine=lib/engine/content`, and the daemon cooks them like any other kind (`tools/cook/fonts.odin`).

**In this document:** [The cook](#the-cook) · [Glyphs](#glyphs) · [The atlas](#the-atlas) · [The blob](#the-blob) · [Import settings](#import-settings)

## The cook

A font cooks to two blobs: a Font blob, and its atlas, a Texture sub-asset named `atlas`. The font's `.meta` file holds the atlas's GUID as `texture.atlas = <guid>`, as a stage's holds its textures' (see [Identity](../identity-and-cooking.md#identity)).

1. `vendor:stb/truetype` reads the font's outlines, TrueType or CFF. The cooker reads the table directory itself (`tools/cook/opentype.odin`). A variable font, which has an `fvar` or a `CFF2` table, fails: export a static instance of it.
2. The cooker chooses the [glyphs](#glyphs) that the atlas holds.
3. Each glyph gets a cell of whole texels around its outline, and `vendor:stb/rect_pack` packs the cells into the [atlas](#the-atlas).
4. msdfgen draws each glyph's distance field into its cell, on every core (`parallel_for`).
5. The atlas cooks as a texture of `usage = data`, and the cooker writes the atlas's blob and then the font's.

**msdfgen** is a submodule at `vendor/msdfgen`, pinned to a release. `tools/cook/msdfgen` builds only its core, which has no dependencies, with its own CMake project; msdfgen's extensions read fonts with FreeType and write PNGs, which the cooker does neither of. `cn_msdf.cpp` gives the cooker a C API: the bounds of an outline, and the field of one glyph from its outline commands, as stb_truetype gives them. A call shares nothing with any other. `just msdfgen` builds it, and `just update-msdfgen <tag>` moves the pin.

**A field per glyph.** The shim builds msdfgen's shape from the commands, normalizes it, and reverses its contours if a point far outside the outline is inside, as msdf-atlas-gen does, since fonts disagree about which winding fills. It colors the edges with `edgeColoringInkTrap` at msdfgen's angle threshold of 3 radians, and generates a multi-channel and true signed distance field (MTSDF) with overlap support and msdfgen's default error correction.

**The cache key** covers the cooker's font and texture versions, the msdfgen version, the source path, both blobs' layouts, the import settings' values, the source, and the font's and the atlas's GUIDs. A font is up to date when both of its blobs have the key. A font that fails keeps its old blobs, so the running game keeps the last good version.

## Glyphs

The atlas holds glyphs by their glyph ids, not by characters, because shaping gives glyph ids: a ligature such as fi is a glyph that no character maps to.

- Glyph 0, which a font draws for a character that it lacks.
- The glyph of each of the charset's characters that the font has (see [Import settings](#import-settings)). A character that the font lacks is left out without a warning.
- **The closure:** each glyph that the GSUB table can substitute for those, until no more come. The cooker walks the lookups of the features that the runtime's shaper, kb_text_shape, applies by default, of every script: `rvrn ccmp locl rlig liga clig calt rclt ltra ltrm frac numr dnom` (`OPENTYPE_DEFAULT_FEATURES`). A single, multiple or alternate substitution adds its output when its input is in the set, a ligature when all of its components are, and a reverse chaining substitution its substitute. A contextual or chained contextual lookup's nested lookups count as active whatever their context. So the closure may keep a glyph that no text makes, but never misses one that shaping can give from the charset. Other features, such as `dlig`, `smcp` or `ss01`, are left out, as text never uses them.

`glyphs = all` keeps every glyph of the font instead.

A test font, `tools/cook/testdata/fonts/FiraSans-Subset.ttf`, is Fira Sans cut down to U+0020 to U+007E with its `ccmp`, `locl`, `liga`, `calt` and `kern` features, under the SIL Open Font License beside it. Its 108 glyphs include fi and fl, which only `liga` reaches, and its closure finds them.

## The atlas

**A cell** holds its glyph's outline at `em_size` texels to an em, with `range / 2` texels and one more around it, rounded out to whole texels from the pen, so the field reaches 0 at the cell's edges. Its `plane` is where the cell's edges are from the pen in em, so a quad from the plane to the cell draws the glyph. A glyph with no outline, such as a space's, has a cell of no size.

**The atlas** is the smallest of sides that are powers of two that holds every cell, at most `MAX_FONT_ATLAS` (4096) on a side, and then its height is cut to its last row of cells. A font that does not fit fails; a smaller `em_size` or charset makes it fit. Fira Sans Regular with the `latin` charset is 1024×345 at the default `em_size` of 48.

**A texel** holds the multi-channel field in red, green and blue, and the true distance in alpha. Each is the distance from the outline mapped by the range: 0.5 is the outline, greater is inside, and 0 and 1 are `range / 2` texels outside and inside it. The median of red, green and blue is the distance with sharp corners. The texture is RGBA8 without sRGB and without mips: block compression and filtered mips both blur a distance field.

## The blob

`Font_Blob` holds the atlas's GUID and size, the font's units per em, `em_size` and `range`, the ascender, descender and line gap in em with y up, which font of a collection it is, its `Font_Glyph` records sorted by id, the font's file, its family name from its `name` table, and the source path. A `Font_Glyph` is its id, its cell in the atlas in texels from the top left, and its plane. The font's file starts at 16 bytes. The runtime shapes text with it, as shaping needs the font's tables, and the atlas only has the glyphs.

## Import settings

In the font's `.meta` file:

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `em_size` | `32`, `48`, `64`, `96` | `48` | The atlas's texels to an em. Text stays sharp at any size; a larger em keeps the thin parts of small glyphs, at four times the texels each time it doubles. |
| `range` | `4`, `6`, `8`, `12`, `16` | `8` | The width of the distances around each outline, in texels. Text drawn smaller than `em_size / range` texels to an em blurs, and outlines and shadows reach up to half the range. |
| `charset` | `ascii`, `latin`, `latin_ext` | `latin` | The characters whose glyphs the atlas holds. `ascii` is U+0020 to U+007E. `latin` adds U+00A0 to U+00FF, U+2010 to U+2027, U+2030 to U+203A, the euro sign and the trademark sign. `latin_ext` adds U+0100 to U+024F and U+1E00 to U+1EFF. |
| `glyphs` | `closure`, `all` | `closure` | Which glyphs the atlas holds (see [Glyphs](#glyphs)). |
| `index` | `0` to `7` | `0` | Which font of a collection to cook. |

**Referring to a font.** A component's field is a tagged GUID, `asset:"font"`, and a behaviour's field is `Field.asset("font")`.

package asset_format

import "core:mem"

import "cinnabar:core/layout"

// The fonts that the cooker reads: TrueType and OpenType outlines, one font of a collection.
FONT_EXTENSIONS :: []string{".ttf", ".otf", ".ttc"}

// The name of a font's atlas, its Texture sub-asset, in its .meta file: texture.atlas.
FONT_ATLAS_NAME :: "atlas"

// A font has at most this many glyphs in its atlas.
MAX_FONT_GLYPHS :: 65535

// Font_Glyph is a glyph in a font's atlas, by its glyph id, which shaping gives.
Font_Glyph :: struct {
	id:    u32,
	// The glyph's cell in the atlas, in texels from the top left: x, y, width and height. A glyph with no outline, such as
	// a space's, has a cell of no size.
	rect:  [4]u16,
	// Where the cell's edges are from the pen, in em, with y up: left, bottom, right and top. A quad from these to rect
	// draws the glyph with its distance field's border.
	plane: [4]f32,
}

// Font_Blob is the start of a font blob (see docs/content/kinds/fonts.md#fonts).
Font_Blob :: struct {
	header:       Blob_Header,
	// The Texture sub-asset that holds the glyphs' distance fields: multi-channel in red, green and blue, and true in
	// alpha, as RGBA8 without sRGB.
	atlas:        Guid,
	atlas_size:   [2]u32,
	units_per_em: u32,
	// The atlas's texels to an em.
	em_size:      f32,
	// The width of the distances that the atlas holds, in its texels: a value of 0.5 is the outline, and 0 and 1 are
	// range / 2 texels outside and inside it.
	range:        f32,
	// The font's line metrics in em, with y up: the ascender is above the baseline and the descender below it, so it is
	// negative. A line is ascender - descender + line_gap high.
	ascender:     f32,
	descender:    f32,
	line_gap:     f32,
	// Which font of a collection font_data holds this one is, 0 for a file of one font.
	index:        u32,
	// Font_Glyph records, sorted by id.
	glyphs:       Slice,
	// The font's file, which the runtime shapes text with. It starts at BLOB_ALIGN.
	font_data:    Slice,
	family:       Slice,
	// The path relative to the content root, prefixed with the root's name, such as "game/fonts/sans.ttf".
	source_path:  Slice,
}

font_layout :: proc() -> u64 {
	return layout.hash(Font_Blob) ~ layout.hash(Font_Glyph) * 31
}

// font_view checks a font blob: its header, its layout, that its slices are inside it, that its glyphs are sorted, and
// that each glyph's cell is inside the atlas.
font_view :: proc(data: []byte) -> (blob: ^Font_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Font || header.layout != font_layout() || len(data) < size_of(Font_Blob) {
		return
	}
	blob = (^Font_Blob)(raw_data(data))
	inside :: proc(data: []byte, s: Slice, size, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.size) % size == 0 && int(s.offset) % align == 0
	}
	if !inside(data, blob.glyphs, size_of(Font_Glyph), align_of(Font_Glyph)) ||
	   !inside(data, blob.font_data, 1, BLOB_ALIGN) ||
	   !inside(data, blob.family, 1, 1) ||
	   !inside(data, blob.source_path, 1, 1) {
		return nil, false
	}
	if blob.units_per_em == 0 || blob.em_size <= 0 || blob.range <= 0 {
		return nil, false
	}
	previous := -1
	for g in font_glyphs(data, blob) {
		if int(g.id) <= previous || u32(g.rect.x) + u32(g.rect.z) > blob.atlas_size.x || u32(g.rect.y) + u32(g.rect.w) > blob.atlas_size.y {
			return nil, false
		}
		previous = int(g.id)
	}
	return blob, true
}

font_glyphs :: proc "contextless" (data: []byte, blob: ^Font_Blob) -> []Font_Glyph {
	bytes := blob_bytes(data, blob.glyphs)
	return ([^]Font_Glyph)(raw_data(bytes))[:len(bytes) / size_of(Font_Glyph)]
}

// font_find_glyph is the glyph of an id in the atlas, if the atlas has it.
font_find_glyph :: proc "contextless" (data: []byte, blob: ^Font_Blob, id: u32) -> (glyph: Font_Glyph, ok: bool) {
	glyphs := font_glyphs(data, blob)
	low, high := 0, len(glyphs)
	for low < high {
		mid := (low + high) / 2
		switch g := glyphs[mid]; {
		case g.id == id:
			return g, true
		case g.id < id:
			low = mid + 1
		case:
			high = mid
		}
	}
	return
}

Font_Contents :: struct {
	guid:         Guid,
	key:          u64,
	atlas:        Guid,
	atlas_size:   [2]u32,
	units_per_em: u32,
	em_size:      f32,
	range:        f32,
	ascender:     f32,
	descender:    f32,
	line_gap:     f32,
	index:        u32,
	// Sorted by id.
	glyphs:       []Font_Glyph,
	font_data:    []byte,
	family:       string,
	source_path:  string,
}

// font_write builds a font blob.
font_write :: proc(contents: Font_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Font_Blob), allocator)
	glyphs := reserve_bytes(&buffer, len(contents.glyphs) * size_of(Font_Glyph), align_of(Font_Glyph))
	if len(contents.glyphs) > 0 {
		mem.copy(&buffer[glyphs.offset], raw_data(contents.glyphs), len(contents.glyphs) * size_of(Font_Glyph))
	}
	font_data := reserve_bytes(&buffer, len(contents.font_data), BLOB_ALIGN)
	copy(buffer[font_data.offset:], contents.font_data)
	family := append_bytes(&buffer, transmute([]byte)contents.family)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	blob := Font_Blob {
		header = {magic = BLOB_MAGIC, kind = .Font, layout = font_layout(), key = contents.key, guid = contents.guid},
		atlas = contents.atlas,
		atlas_size = contents.atlas_size,
		units_per_em = contents.units_per_em,
		em_size = contents.em_size,
		range = contents.range,
		ascender = contents.ascender,
		descender = contents.descender,
		line_gap = contents.line_gap,
		index = contents.index,
		glyphs = glyphs,
		font_data = font_data,
		family = family,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

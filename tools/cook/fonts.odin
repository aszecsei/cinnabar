package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf16"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

import format "cinnabar:engine/asset/format"

// Fonts are TrueType and OpenType files. The cooker makes each one's atlas of multi-channel signed distance fields with
// msdfgen, as a Texture sub-asset, and writes a Font blob of its metrics, its glyphs' cells in the atlas, and the file
// itself, which the runtime shapes text with (see docs/content/kinds/fonts.md#fonts).
FONT_COOK_VERSION :: "fonts 1"

// An atlas is at most this many texels on a side. A font whose glyphs do not fit fails, and a smaller em_size or
// charset makes it fit.
MAX_FONT_ATLAS :: 4096

FONT_SETTINGS := []Setting_Info {
	{
		key = "em_size",
		values = {"32", "48", "64", "96"},
		default = "48",
		description = "The atlas's texels to an em. Text stays sharp at any size; a larger em keeps the thin parts of small glyphs, at four times the texels each time it doubles.",
	},
	{
		key = "range",
		values = {"4", "6", "8", "12", "16"},
		default = "8",
		description = "The width of the distances around each outline, in texels. Text drawn smaller than em_size / range texels to an em blurs, and outlines and shadows reach up to half the range.",
	},
	{
		key = "charset",
		values = {"ascii", "latin", "latin_ext"},
		default = "latin",
		description = "The characters whose glyphs the atlas holds. Ascii is U+0020 to U+007E; latin adds Latin-1, general punctuation and the euro sign; latin_ext adds Latin Extended-A and -B and Latin Extended Additional.",
	},
	{
		key = "glyphs",
		values = {"closure", "all"},
		default = "closure",
		description = "Closure keeps the charset's glyphs and those that the default features' substitutions make of them, such as ligatures. All keeps every glyph of the font.",
	},
	{
		key = "index",
		values = {"0", "1", "2", "3", "4", "5", "6", "7"},
		default = "0",
		description = "Which font of a collection (.ttc) to cook.",
	},
}

// The code points of each charset, as ranges.
@(private = "file")
CHARSET_ASCII :: [][2]rune{{0x20, 0x7e}}
@(private = "file")
CHARSET_LATIN :: [][2]rune{{0x20, 0x7e}, {0xa0, 0xff}, {0x2010, 0x2027}, {0x2030, 0x203a}, {0x20ac, 0x20ac}, {0x2122, 0x2122}}
@(private = "file")
CHARSET_LATIN_EXT :: [][2]rune {
	{0x20, 0x7e},
	{0xa0, 0x24f},
	{0x1e00, 0x1eff},
	{0x2010, 0x2027},
	{0x2030, 0x203a},
	{0x20ac, 0x20ac},
	{0x2122, 0x2122},
}

@(private = "file")
font_setting :: proc(a: Asset_Source, key: string) -> string {
	if value, found := format.meta_value(a.meta, key); found {
		return value
	}
	info, _ := find_setting(FONT_SETTINGS, key)
	return info.default
}

cook_fonts :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	out_dir := config_dir(options)
	fonts := assets_of(assets, .Font)
	if len(fonts) > 0 && !make_output_dir(pass, out_dir, {.Font}) {
		return false
	}
	ok := true
	step_begin(pass, .Font, "", len(fonts))
	for i in fonts {
		defer step_advance(pass)
		result := cook_font(options, &assets[i], out_dir, pass)
		settle(pass, i, result)
		ok &&= !asset_failed(result)
	}
	return ok
}

// Font_Cell is a glyph's cell in the atlas, and its outline.
@(private = "file")
Font_Cell :: struct {
	glyph:    format.Font_Glyph,
	commands: []Msdf_Command,
	// The cell's bottom left from the pen, in texels.
	origin:   [2]int,
	size:     [2]int,
}

@(private = "file")
cook_font :: proc(options: Cook_Options, a: ^Asset_Source, out_dir: string, pass: ^Pass) -> Asset_Result {
	problems := &pass.problems
	if !check_settings(a^, problems) {
		return .Failed
	}
	guid := a.meta.guid
	if !assign_subassets(a, {{kind = .Texture, name = format.FONT_ATLAS_NAME}}, pass.force[guid], problems) {
		return .Failed
	}
	atlas_guid: format.Guid
	for s in a.subassets {
		if s.kind == .Texture && s.name == format.FONT_ATLAS_NAME {
			atlas_guid = s.guid
		}
	}

	em_size := strconv.parse_int(font_setting(a^, "em_size")) or_else 48
	range := strconv.parse_int(font_setting(a^, "range")) or_else 8
	charset := font_setting(a^, "charset")
	all_glyphs := font_setting(a^, "glyphs") == "all"
	index := strconv.parse_int(font_setting(a^, "index")) or_else 0

	// The settings are part of the key as their values, so a .meta file that only gains the atlas's line keeps it.
	key := hash.fnv64a(
		transmute([]byte)fmt.tprintf(
			"%s\x00%s\x00%s\x00%s\x00%x\x00%x\x00%d\x00%d\x00%s\x00%v\x00%d\x00",
			FONT_COOK_VERSION,
			TEXTURE_COOK_VERSION,
			MSDFGEN_VERSION,
			a.name,
			format.font_layout(),
			format.texture_layout(),
			em_size,
			range,
			charset,
			all_glyphs,
			index,
		),
	)
	key = hash.fnv64a(a.source, key)
	key = hash.fnv64a(guid[:], key)
	key = hash.fnv64a(atlas_guid[:], key)
	output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(guid))
	atlas_output := fmt.tprintf("%s/%s.blob", out_dir, guid_text(atlas_guid))
	if cooked_key(output, .Font, format.font_layout()) == key && cooked_key(atlas_output, .Texture, format.texture_layout()) == key && !pass.force[guid] {
		return .Current
	}

	data := a.source
	offset := int(stbtt.GetFontOffsetForIndex(raw_data(data), i32(index))) if len(data) >= 12 else -1
	if offset < 0 {
		report_error(problems, a.path, 0, 0, "has no font %d", index)
		return .Failed
	}
	tables, tables_ok := font_tables(data, offset)
	if !tables_ok {
		report_error(problems, a.path, 0, 0, "is not a TrueType or OpenType font, or is truncated")
		return .Failed
	}
	if "fvar" in tables.tables || "CFF2" in tables.tables {
		report_error(problems, a.path, 0, 0, "is a variable font, which the cooker does not read. Export a static instance of it.")
		return .Failed
	}
	if !("glyf" in tables.tables) && !("CFF " in tables.tables) {
		report_error(problems, a.path, 0, 0, "has no outlines: neither a glyf nor a CFF table")
		return .Failed
	}
	info: stbtt.fontinfo
	if !stbtt.InitFont(&info, raw_data(data), i32(offset)) || info.numGlyphs <= 0 {
		report_error(problems, a.path, 0, 0, "is not a font that stb_truetype reads")
		return .Failed
	}
	head := tables.tables["head"]
	units_per_em := len(head) >= 20 ? int(head[18]) << 8 | int(head[19]) : 0
	if units_per_em == 0 {
		report_error(problems, a.path, 0, 0, "has no units per em in its head table")
		return .Failed
	}

	wanted := make([dynamic]bool, info.numGlyphs, context.temp_allocator)
	wanted[0] = true
	if all_glyphs {
		slice.fill(wanted[:], true)
	} else {
		ranges := CHARSET_LATIN
		switch charset {
		case "ascii":
			ranges = CHARSET_ASCII
		case "latin_ext":
			ranges = CHARSET_LATIN_EXT
		}
		for r in ranges {
			for cp in r[0] ..= r[1] {
				if g := stbtt.FindGlyphIndex(&info, cp); g > 0 && int(g) < len(wanted) {
					wanted[g] = true
				}
			}
		}
		gsub_closure(tables.tables["GSUB"], &wanted)
	}

	cells := font_cells(&info, wanted[:], f64(em_size) / f64(units_per_em), f64(em_size), range, a.path, problems)
	if len(cells) > format.MAX_FONT_GLYPHS {
		report_error(problems, a.path, 0, 0, "has %d glyphs, more than the atlas holds (%d)", len(cells), format.MAX_FONT_GLYPHS)
		return .Failed
	}
	atlas_size, packed := pack_font_cells(cells)
	if !packed {
		report_error(problems, a.path, 0, 0, "has %d glyphs, which do not fit in a %d texel atlas at em_size %d. Choose a smaller em_size or charset.", len(cells), MAX_FONT_ATLAS, em_size)
		return .Failed
	}
	atlas := Image{int(atlas_size.x), int(atlas_size.y), make([][4]f32, int(atlas_size.x * atlas_size.y), context.temp_allocator)}
	if !draw_font_cells(cells, f64(em_size) / f64(units_per_em), f64(range), atlas) {
		report_error(problems, a.path, 0, 0, "has a glyph whose outline msdfgen cannot use")
		return .Failed
	}

	texture := Texture_Cook{usage = .Data, mips = false, max_size = 16384}
	atlas_blob, atlas_ok := cook_texture_image(options, atlas, texture, atlas_guid, key, fmt.tprintf("%s#%s", a.name, format.FONT_ATLAS_NAME), a.path, problems)
	if !atlas_ok {
		return .Failed
	}
	glyphs := make([]format.Font_Glyph, len(cells), context.temp_allocator)
	for c, i in cells {
		glyphs[i] = c.glyph
	}
	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
	em := f32(units_per_em)
	blob := format.font_write(
		{
			guid = guid,
			key = key,
			atlas = atlas_guid,
			atlas_size = atlas_size,
			units_per_em = u32(units_per_em),
			em_size = f32(em_size),
			range = f32(range),
			ascender = f32(ascent) / em,
			descender = f32(descent) / em,
			line_gap = f32(line_gap) / em,
			index = u32(index),
			glyphs = glyphs,
			font_data = data,
			family = font_family(tables.tables["name"]),
			source_path = a.name,
		},
		context.temp_allocator,
	)
	// The atlas goes first, so a font blob never names an atlas that its cook did not write.
	if !write_blob(atlas_output, atlas_blob) || !write_blob(output, blob) {
		return .Failed
	}
	a.size = atlas_size
	count_subassets(pass, .Texture, .Cooked)
	return .Cooked
}

// font_cells is the atlas's cells for the wanted glyphs, in order of their ids, with their outlines in font units.
// scale is texels to a font unit, and em_size texels to an em. Each cell holds the glyph's outline with range / 2 texels and one more around it, on
// whole texels from the pen, so the field reaches 0 at its edges. A glyph with no outline has a cell of no size.
@(private = "file")
font_cells :: proc(info: ^stbtt.fontinfo, wanted: []bool, scale, em_size: f64, range: int, path: string, problems: ^Problems) -> []Font_Cell {
	cells := make([dynamic]Font_Cell, context.temp_allocator)
	border := (range + 1) / 2 + 1
	for want, id in wanted {
		if !want {
			continue
		}
		cell := Font_Cell {
			glyph = {id = u32(id)},
		}
		vertices: [^]stbtt.vertex
		count := int(stbtt.GetGlyphShape(info, i32(id), &vertices))
		if count > 0 {
			commands := make([]Msdf_Command, count, context.temp_allocator)
			for v, i in vertices[:count] {
				op: Msdf_Op
				switch v.type {
				case u8(stbtt.vmove.vmove):
					op = .Move
				case u8(stbtt.vmove.vline):
					op = .Line
				case u8(stbtt.vmove.vcurve):
					op = .Quad
				case u8(stbtt.vmove.vcubic):
					op = .Cubic
				}
				commands[i] = {op, {f32(v.x), f32(v.y)}, {{f32(v.cx), f32(v.cy)}, {f32(v.cx1), f32(v.cy1)}}}
			}
			stbtt.FreeShape(info, vertices)
			bounds, has_edges, ok := msdf_bounds(commands)
			if !ok {
				report_warning(problems, path, 0, 0, "glyph %d's outline is broken, so it draws nothing", id)
			} else if has_edges {
				x0 := int(math.floor(bounds[0] * scale)) - border
				y0 := int(math.floor(bounds[1] * scale)) - border
				x1 := int(math.ceil(bounds[2] * scale)) + border
				y1 := int(math.ceil(bounds[3] * scale)) + border
				cell.commands = commands
				cell.origin = {x0, y0}
				cell.size = {x1 - x0, y1 - y0}
				cell.glyph.plane = {f32(f64(x0) / em_size), f32(f64(y0) / em_size), f32(f64(x1) / em_size), f32(f64(y1) / em_size)}
			}
		}
		append(&cells, cell)
	}
	return cells[:]
}

// pack_font_cells places the cells in the smallest atlas that holds them, of sides that are powers of two up to
// MAX_FONT_ATLAS, and gives its size. Its height is then cut to the last cell's row.
@(private = "file")
pack_font_cells :: proc(cells: []Font_Cell) -> (size: [2]u32, ok: bool) {
	rects := make([]stbrp.Rect, len(cells), context.temp_allocator)
	area := 0
	for c, i in cells {
		rects[i] = {id = i32(i), w = stbrp.Coord(c.size.x), h = stbrp.Coord(c.size.y)}
		area += c.size.x * c.size.y
	}
	width, height := 64, 64
	for width * height < area {
		if width <= height {
			width *= 2
		} else {
			height *= 2
		}
	}
	for width <= MAX_FONT_ATLAS && height <= MAX_FONT_ATLAS {
		nodes := make([]stbrp.Node, width, context.temp_allocator)
		ctx: stbrp.Context
		stbrp.init_target(&ctx, i32(width), i32(height), raw_data(nodes), i32(width))
		if stbrp.pack_rects(&ctx, raw_data(rects), i32(len(rects))) == 1 {
			used := 1
			for r in rects {
				used = max(used, int(r.y + r.h))
			}
			for r, i in rects {
				cells[i].glyph.rect = {u16(r.x), u16(r.y), u16(r.w), u16(r.h)}
			}
			return {u32(width), u32(used)}, true
		}
		if width <= height {
			width *= 2
		} else {
			height *= 2
		}
	}
	return
}

// Font_Draw is the cells that draw_font_cells's threads draw into the atlas, each its own part of it.
@(private = "file")
Font_Draw :: struct {
	cells:  []Font_Cell,
	// The cells' indices, largest first, as the largest take longest.
	order:  []int,
	scale:  f64,
	range:  f64,
	atlas:  Image,
	failed: bool,
}

// draw_font_cells draws each cell's distance field into the atlas, and fills in its plane. It returns false if msdfgen
// could not use a glyph's outline.
@(private = "file")
draw_font_cells :: proc(cells: []Font_Cell, scale, range: f64, atlas: Image) -> bool {
	by_area := make([][2]int, len(cells), context.temp_allocator)
	for c, i in cells {
		by_area[i] = {c.size.x * c.size.y, i}
	}
	slice.sort_by(by_area, proc(a, b: [2]int) -> bool {return a[0] > b[0]})
	order := make([]int, len(cells), context.temp_allocator)
	for entry, i in by_area {
		order[i] = entry[1]
	}
	work := Font_Draw{cells, order, scale, range, atlas, false}
	parallel_for(len(cells), &work, proc(data: rawptr, index: int) {
		w := (^Font_Draw)(data)
		c := &w.cells[w.order[index]]
		if c.size.x == 0 {
			return
		}
		params := Msdf_Params {
			width           = i32(c.size.x),
			height          = i32(c.size.y),
			scale           = w.scale,
			translate       = {-f64(c.origin.x) / w.scale, -f64(c.origin.y) / w.scale},
			range           = w.range,
			angle_threshold = MSDF_ANGLE_THRESHOLD,
		}
		pixels := make([][4]f32, c.size.x * c.size.y, context.temp_allocator)
		if !msdf_mtsdf(c.commands, params, pixels) {
			w.failed = true
			return
		}
		rect := c.glyph.rect
		for y in 0 ..< c.size.y {
			row := (int(rect.y) + y) * w.atlas.width + int(rect.x)
			copy(w.atlas.pixels[row:][:c.size.x], pixels[y * c.size.x:][:c.size.x])
		}
	})
	return !work.failed
}

// font_family is the font's family name from its name table: the Windows English name, or else the Macintosh one.
@(private = "file")
font_family :: proc(name: []byte) -> string {
	u16be :: proc(data: []byte, at: int) -> int {
		return at + 2 <= len(data) ? int(data[at]) << 8 | int(data[at + 1]) : 0
	}
	count, storage := u16be(name, 2), u16be(name, 4)
	mac := ""
	for i in 0 ..< count {
		record := 6 + i * 12
		platform, encoding, language, id := u16be(name, record), u16be(name, record + 2), u16be(name, record + 4), u16be(name, record + 6)
		length, offset := u16be(name, record + 8), u16be(name, record + 10)
		if id != 1 || storage + offset + length > len(name) {
			continue
		}
		bytes := name[storage + offset:][:length]
		if platform == 3 && (encoding == 1 || encoding == 10) && language == 0x409 {
			units := make([]u16, length / 2, context.temp_allocator)
			for &u, j in units {
				u = u16(bytes[j * 2]) << 8 | u16(bytes[j * 2 + 1])
			}
			text := make([]byte, len(units) * 4, context.temp_allocator)
			return string(text[:utf16.decode_to_utf8(text, units)])
		}
		if platform == 1 && encoding == 0 && mac == "" {
			mac = strings.clone(string(bytes), context.temp_allocator)
		}
	}
	return mac
}

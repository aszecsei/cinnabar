package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import stbtt "vendor:stb/truetype"

import format "cinnabar:engine/asset/format"

// A subset of Fira Sans of U+0020 to U+007E, with its ccmp, locl, liga, calt and kern features: 108 glyphs, of which
// fi (58) and fl (59) are only reached through liga. See testdata/fonts/OFL.txt.
@(private)
TEST_FONT :: #load("testdata/fonts/FiraSans-Subset.ttf", string)
@(private = "file")
TEST_FONT_GLYPHS :: 108
@(private = "file")
TEST_FONT_FI :: 58
@(private = "file")
TEST_FONT_FL :: 59

// font_glyph_of is the test font's glyph id of a character.
@(private = "file")
font_glyph_of :: proc(r: rune) -> u32 {
	info: stbtt.fontinfo
	stbtt.InitFont(&info, raw_data(TEST_FONT), 0)
	return u32(stbtt.FindGlyphIndex(&info, r))
}

@(test)
fonts_cook_to_font_blobs_and_atlases_of_distance_fields :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/fonts/sans.ttf", TEST_FONT}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Font}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Font], 1)
	testing.expect_value(t, pass.cooked[.Texture], 1)

	meta_text, _ := os.read_entire_file(fmt.tprintf("%s/content/fonts/sans.ttf.meta", tree.dir), context.temp_allocator)
	meta, _ := format.meta_parse(string(meta_text), context.temp_allocator)
	atlas_guid, has_atlas := format.meta_subasset(meta, format.TEXTURE_KIND, format.FONT_ATLAS_NAME)
	testing.expect(t, has_atlas, "the .meta file names the atlas")

	data := tree_blob(t, tree, meta.guid)
	blob, ok := format.font_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.atlas, atlas_guid)
	testing.expect_value(t, blob.units_per_em, 1000)
	testing.expect_value(t, blob.em_size, 48)
	testing.expect_value(t, blob.range, 8)
	testing.expect(t, blob.ascender > 0 && blob.descender < 0)
	testing.expect_value(t, format.blob_string(data, blob.family), "Fira Sans")
	testing.expect_value(t, len(format.blob_bytes(data, blob.font_data)), len(TEST_FONT))
	// The charset's glyphs, and the ligatures that liga makes of them.
	for id in ([]u32{0, font_glyph_of('A'), font_glyph_of('I'), TEST_FONT_FI, TEST_FONT_FL}) {
		_, found := format.font_find_glyph(data, blob, id)
		testing.expectf(t, found, "glyph %d is in the atlas", id)
	}
	space, _ := format.font_find_glyph(data, blob, font_glyph_of(' '))
	testing.expect_value(t, space.rect.zw, [2]u16{0, 0})

	atlas_data := tree_blob(t, tree, atlas_guid)
	atlas, atlas_ok := format.texture_view(atlas_data)
	testing.expect(t, atlas_ok)
	if !atlas_ok {
		return
	}
	testing.expect_value(t, atlas.format, format.Texture_Format.RGBA8_Unorm)
	testing.expect_value(t, atlas.mip_count, 1)
	testing.expect_value(t, atlas.size, blob.atlas_size)
	testing.expect(t, strings.has_suffix(format.blob_string(atlas_data, atlas.source_path), "#atlas"))
	texels := ([^][4]u8)(raw_data(format.blob_bytes(atlas_data, atlas.mips)))
	at :: proc(texels: [^][4]u8, width: u32, x, y: int) -> u8 {
		p := texels[y * int(width) + x]
		return max(min(p.r, p.g), min(max(p.r, p.g), p.b))
	}
	// An I is one stem: its cell's middle is inside the outline, and its cell's corner outside it.
	i, _ := format.font_find_glyph(data, blob, font_glyph_of('I'))
	middle := at(texels, atlas.size.x, int(i.rect.x + i.rect.z / 2), int(i.rect.y + i.rect.w / 2))
	testing.expectf(t, middle > 160, "the middle of I is %d", middle)
	corner := at(texels, atlas.size.x, int(i.rect.x), int(i.rect.y))
	testing.expectf(t, corner < 32, "the corner of I's cell is %d", corner)
	// The plane of I reaches from just below the baseline, by its border, to above the cap height.
	testing.expect(t, i.plane[1] < 0 && i.plane[1] > -0.2 && i.plane[3] > 0.6 && i.plane[0] < i.plane[2])

	// A second cook finds both blobs up to date.
	pass = cook(options, {.Font}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.current[.Font], 1)
	testing.expect_value(t, pass.cooked[.Font], 0)
}

@(test)
fonts_keep_every_glyph_when_asked :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/fonts/sans.ttf", TEST_FONT},
			{"content/fonts/sans.ttf.meta", "guid = 0123456789abcdef0123456789abcdef\nglyphs = all\nem_size = 32\n"},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Font}, log_problems = false)
	testing.expect(t, pass.ok)
	data := tree_blob(t, tree, tree_guid(t, tree, "fonts/sans.ttf"))
	blob, ok := format.font_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, len(format.font_glyphs(data, blob)), TEST_FONT_GLYPHS)
		testing.expect_value(t, blob.em_size, 32)
	}
}

@(test)
fonts_that_cannot_cook_report_why :: proc(t: ^testing.T) {
	// A variable font, as a renamed table makes the test font look.
	variable := transmute([]byte)strings.clone(TEST_FONT, context.temp_allocator)
	directory := string(variable[:12 + 16 * 32])
	post := strings.index(directory, "post")
	testing.expect(t, post > 0)
	copy(variable[post:], "fvar")
	cases := []struct {
		files:    []struct {
			path, text: string,
		},
		fragment: string,
	} {
		{{{"content/a.ttf", string(variable)}}, "variable font"},
		{{{"content/a.ttf", TEST_FONT[:40]}}, "truncated"},
		{{{"content/a.ttf", TEST_FONT}, {"content/a.ttf.meta", "guid = 0123456789abcdef0123456789abcdef\nem_size = 50\n"}}, "em_size must be"},
		{{{"content/a.ttf", TEST_FONT}, {"content/a.ttf.meta", "guid = 0123456789abcdef0123456789abcdef\nindex = 1\n"}}, "has no font 1"},
	}
	for c in cases {
		tree := make_tree(t, c.files)
		defer remove_tree(tree)
		pass := cook(tree_options(tree), {.Font}, log_problems = false)
		testing.expectf(t, !pass.ok, "%s: the cook fails", c.fragment)
		found := false
		for p in pass.problems.list {
			found ||= p.error && strings.contains(p.text, c.fragment)
		}
		testing.expectf(t, found, "an error says %q: %v", c.fragment, pass.problems.list)
	}
}

package asset_format

import "core:testing"

// test_font is a font blob of glyphs, at the runtime's alignment.
@(private = "file")
test_font :: proc(glyphs: []Font_Glyph) -> []byte {
	return aligned(font_write(
		{
			guid = {0 = 1, 1 = 2, 2 = 3},
			key = 42,
			atlas = {0 = 4, 1 = 5, 2 = 6},
			atlas_size = {64, 32},
			units_per_em = 1000,
			em_size = 48,
			range = 8,
			ascender = 0.9,
			descender = -0.25,
			line_gap = 0.1,
			glyphs = glyphs,
			font_data = {0, 1, 0, 0, 7},
			family = "Test Sans",
			source_path = "game/fonts/test.ttf",
		},
		context.temp_allocator,
	))
}

@(test)
font_blob_round_trips_and_finds_glyphs_by_id :: proc(t: ^testing.T) {
	glyphs := []Font_Glyph{{id = 0, rect = {0, 0, 10, 12}, plane = {-0.1, -0.1, 0.5, 0.7}}, {id = 3}, {id = 36, rect = {10, 0, 20, 30}}}
	data := test_font(glyphs)
	blob, ok := font_view(data)
	testing.expect(t, ok)
	testing.expect_value(t, blob.atlas, Guid{0 = 4, 1 = 5, 2 = 6})
	testing.expect_value(t, blob.atlas_size, [2]u32{64, 32})
	testing.expect_value(t, blob.ascender, 0.9)
	testing.expect_value(t, len(font_glyphs(data, blob)), 3)
	testing.expect_value(t, blob.font_data.offset % BLOB_ALIGN, 0)
	testing.expect_value(t, blob_string(data, blob.font_data), "\x00\x01\x00\x00\x07")
	testing.expect_value(t, blob_string(data, blob.family), "Test Sans")

	g, found := font_find_glyph(data, blob, 36)
	testing.expect(t, found)
	testing.expect_value(t, g.rect, [4]u16{10, 0, 20, 30})
	_, found = font_find_glyph(data, blob, 4)
	testing.expect(t, !found)
}

@(test)
font_view_rejects_unsorted_glyphs_and_cells_outside_the_atlas :: proc(t: ^testing.T) {
	_, ok := font_view(test_font({{id = 5}, {id = 2}}))
	testing.expect(t, !ok, "unsorted")
	_, ok = font_view(test_font({{id = 5}, {id = 5}}))
	testing.expect(t, !ok, "a glyph twice")
	_, ok = font_view(test_font({{id = 1, rect = {60, 0, 5, 1}}}))
	testing.expect(t, !ok, "a cell past the atlas's right")
	_, ok = font_view(test_font({{id = 1, rect = {0, 20, 1, 13}}}))
	testing.expect(t, !ok, "a cell past the atlas's bottom")

	data := test_font(nil)
	blob, _ := font_view(data)
	blob.glyphs.size = 7
	_, ok = font_view(data)
	testing.expect(t, !ok, "a slice that is not whole glyphs")
}

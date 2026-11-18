package cook

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:testing"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

@(private = "file")
VIRTUAL_META :: "guid = 00112233445566778899aabbccddee20\nusage = color\n"

// decompress_page is a page's tile, uncompressed, or nil for a page whose block is not as its record says.
@(private = "file")
decompress_page :: proc(
	t: ^testing.T,
	data: []byte,
	blob: ^format.Texture_Blob,
	page: format.Texture_Page,
) -> []byte {
	block := data[page.offset:][:page.compressed_size]
	testing.expect_value(t, hash.fnv32a(block), page.checksum)
	out := make([]byte, page.size, context.temp_allocator)
	if !lz4.decompress(block, out) {
		testing.expect(t, false, "a page does not decompress")
		return nil
	}
	return out
}

// A 512 by 384 color texture is virtual: three paged mips of 12, 4 and 1 pages, a tail from its 64 by 48 mip, and every
// page a block that decompresses to a tile.
@(test)
large_textures_cook_as_pages :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/big.png.meta", VIRTUAL_META}})
	defer remove_tree(tree)
	write_test_image(t, tree, "big.png", 512, 384)
	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)

	data, blob, ok := texture_blob(t, tree, "big.png")
	if !ok {
		return
	}
	testing.expect_value(t, blob.flags, format.Texture_Flags{.Virtual})
	testing.expect_value(t, blob.format, format.Texture_Format.BC7_Unorm_Srgb)
	testing.expect_value(t, blob.mip_count, 10)
	testing.expect_value(t, blob.tail_mip, 3)
	testing.expect_value(t, blob.mips.size, 0)
	testing.expect_value(t, len(format.texture_levels(data, blob)), 3)
	pages := format.texture_pages(data, blob)
	testing.expect_value(t, len(pages), 17)
	testing.expect_value(
		t,
		int(blob.tail.size),
		format.texture_chain_size(.BC7_Unorm_Srgb, {64, 48}, 7),
	)
	testing.expect(t, blob.head_size < blob.file_size)
	for page in pages {
		testing.expect_value(t, page.size, u32(34 * 34 * 16))
		decompress_page(t, data, blob, page)
	}
	head, _ := mem.alloc_bytes(int(blob.head_size), format.BLOB_ALIGN, context.temp_allocator)
	copy(head, data[:blob.head_size])
	_, head_ok := format.texture_view(head)
	testing.expect(t, head_ok, "the head of the cooked blob checks alone")
}

@(test)
only_large_textures_with_mips_cook_as_pages :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/small.png.meta", VIRTUAL_META},
			{
				"content/plain.png.meta",
				"guid = 00112233445566778899aabbccddee21\nusage = color\n[streaming]\nvirtual = false\n",
			},
			{
				"content/flat.png.meta",
				"guid = 00112233445566778899aabbccddee22\nusage = color\n[mip_map]\nenabled = false\n",
			},
			{"content/sky.hdr.meta", "guid = 00112233445566778899aabbccddee23\nusage = hdr\n"},
			{"content/raw.png.meta", "guid = 00112233445566778899aabbccddee24\nusage = data\n"},
			{"content/edge.png.meta", "guid = 00112233445566778899aabbccddee25\nusage = mask\n"},
		},
	)
	defer remove_tree(tree)
	write_test_image(t, tree, "small.png", 128, 128)
	write_test_image(t, tree, "plain.png", 512, 384)
	write_test_image(t, tree, "flat.png", 256, 256)
	write_test_image(t, tree, "sky.hdr", 256, 256)
	write_test_image(t, tree, "raw.png", 256, 256)
	// One texel past a page is enough, and a mask pages as a color does.
	write_test_image(t, tree, "edge.png", 132, 8)
	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)

	for name in ([]string{"small.png", "plain.png", "flat.png", "sky.hdr", "raw.png"}) {
		data, blob, ok := texture_blob(t, tree, name)
		if !ok {
			continue
		}
		testing.expectf(t, blob.flags == {}, "%s is virtual", name)
		testing.expectf(t, blob.mips.size > 0, "%s has no mips", name)
		testing.expect_value(t, blob.head_size, u64(len(data)))
	}
	if data, blob, ok := texture_blob(t, tree, "edge.png"); ok {
		testing.expect_value(t, blob.flags, format.Texture_Flags{.Virtual})
		testing.expect_value(t, blob.format, format.Texture_Format.BC4_Unorm)
		// 132 by 8, 66 by 4 and then 33 by 2, which starts the tail: the second page level is the root.
		testing.expect_value(t, blob.tail_mip, 2)
		levels := format.texture_levels(data, blob)
		testing.expect_value(t, len(levels), 2)
		testing.expect_value(t, levels[0].grid, [2]u32{2, 1})
		testing.expect_value(t, levels[1].grid, [2]u32{1, 1})
	}
}

// image_of_coordinates is an image whose texel (x, y) holds x in red and y in green, so that a test reads a tile's
// source texels off it.
@(private = "file")
image_of_coordinates :: proc(width, height: int) -> Image {
	image := Image{width, height, make([][4]f32, width * height, context.temp_allocator)}
	for y in 0 ..< height {
		for x in 0 ..< width {
			image.pixels[y * width + x] = {f32(x), f32(y), 0, 1}
		}
	}
	return image
}

@(test)
tiles_hold_the_texels_around_their_page :: proc(t: ^testing.T) {
	image := image_of_coordinates(300, 140)
	// Page (1, 0) holds x from 128, with 4 more texels on each side: 124 to 263. Above the image, it is wrapped.
	tile := virtual_tile(image, 1, 0, .Clamp)
	testing.expect_value(t, tile.width, 136)
	testing.expect_value(t, tile.height, 136)
	testing.expect_value(t, tile.pixels[4 * 136 + 0].r, 124)
	testing.expect_value(t, tile.pixels[4 * 136 + 4].r, 128)
	testing.expect_value(t, tile.pixels[4 * 136 + 135].r, 259)
	testing.expect_value(t, tile.pixels[(4 + 100) * 136 + 20].g, 100)
	// Row 0 is y = -4, which clamps to the first row.
	testing.expect_value(t, tile.pixels[0 * 136 + 20].g, 0)
	// Page (0, 1)'s rows are y from 124 to 259: past the image's 140 rows, it clamps to the last.
	below := virtual_tile(image, 0, 1, .Clamp)
	testing.expect_value(t, below.pixels[0 * 136 + 4].g, 124)
	testing.expect_value(t, below.pixels[16 * 136 + 4].g, 139)
	testing.expect_value(t, below.pixels[135 * 136 + 4].g, 139)
}

@(test)
tiles_past_an_edge_take_the_wrap_mode :: proc(t: ^testing.T) {
	image := image_of_coordinates(6, 5)
	// The tile starts at (-4, -4): texel i of its first row is x = i - 4.
	Case :: struct {
		wrap:    format.Texture_Wrap,
		// x of tile column 0 to 3 (-4 to -1), then 10 and 11 (6 and 7, past the right edge), and y of tile row 3 and 9
		// (-1, and 5 past the bottom edge).
		left:    [4]f32,
		right:   [2]f32,
		up_down: [2]f32,
	}
	cases := []Case {
		{.Repeat, {2, 3, 4, 5}, {0, 1}, {4, 0}},
		{.Clamp, {0, 0, 0, 0}, {5, 5}, {0, 4}},
		{.Mirror, {3, 2, 1, 0}, {5, 4}, {0, 4}},
	}
	for c in cases {
		tile := virtual_tile(image, 0, 0, c.wrap)
		for x in 0 ..< 4 {
			testing.expectf(
				t,
				tile.pixels[8 * 136 + x].r == c.left[x],
				"%v: column %d is x %v",
				c.wrap,
				x,
				tile.pixels[8 * 136 + x].r,
			)
		}
		for x in 0 ..< 2 {
			testing.expect_value(t, tile.pixels[8 * 136 + 10 + x].r, c.right[x])
		}
		testing.expect_value(t, tile.pixels[3 * 136 + 8].g, c.up_down[0])
		testing.expect_value(t, tile.pixels[9 * 136 + 8].g, c.up_down[1])
		// The mip's own texels are where they are, and the border is not shifted into them.
		testing.expect_value(t, tile.pixels[4 * 136 + 4].r, 0)
		testing.expect_value(t, tile.pixels[8 * 136 + 9].r, 5)
		testing.expect_value(t, tile.pixels[8 * 136 + 9].g, 4)
	}
}

// mip_bytes is the blocks of a mip of a non-virtual blob, in rows of blocks.
@(private = "file")
mip_bytes :: proc(data: []byte, blob: ^format.Texture_Blob, mip: u32) -> []byte {
	offset: int
	for m in 0 ..< mip {
		offset += format.texture_mip_size(
			blob.format,
			max(blob.size.x >> m, 1),
			max(blob.size.y >> m, 1),
		)
	}
	size := format.texture_mip_size(
		blob.format,
		max(blob.size.x >> mip, 1),
		max(blob.size.y >> mip, 1),
	)
	return format.blob_bytes(data, blob.mips)[offset:][:size]
}

// The pages of a virtual cook, decompressed and stripped of their borders, are the blocks of each paged mip of the same
// image cooked without pages: Compressonator encodes a block from its own 16 texels, so a block inside a tile is the
// block that the whole mip has there. The tail is the whole cook's tail.
@(test)
stripped_pages_are_the_mips_of_a_plain_cook :: proc(t: ^testing.T) {
	for usage in ([]string{"color", "normal", "mask"}) {
		tree := make_tree(
			t,
			{
				{
					"content/paged.png.meta",
					fmt.tprintf("guid = 00112233445566778899aabbccddee30\nusage = %s\n", usage),
				},
				{
					"content/whole.png.meta",
					fmt.tprintf(
						"guid = 00112233445566778899aabbccddee31\nusage = %s\n[streaming]\nvirtual = false\n",
						usage,
					),
				},
			},
		)
		defer remove_tree(tree)
		write_test_image(t, tree, "paged.png", 512, 384)
		write_test_image(t, tree, "whole.png", 512, 384)
		testing.expect(t, cook(tree_options(tree), {.Texture}).ok)

		paged_data, paged, paged_ok := texture_blob(t, tree, "paged.png")
		whole_data, whole, whole_ok := texture_blob(t, tree, "whole.png")
		if !paged_ok || !whole_ok {
			return
		}
		testing.expect_value(t, paged.flags, format.Texture_Flags{.Virtual})
		levels := format.texture_levels(paged_data, paged)
		pages := format.texture_pages(paged_data, paged)
		for level, mip in levels {
			expected := mip_bytes(whole_data, whole, u32(mip))
			assembled := make([]byte, len(expected), context.temp_allocator)
			for y in 0 ..< level.grid.y {
				for x in 0 ..< level.grid.x {
					page := pages[level.first_page + y * level.grid.x + x]
					payload := decompress_page(t, paged_data, paged, page)
					format.texture_page_strip(paged.format, payload, level, x, y, assembled)
				}
			}
			same := true
			for b in 0 ..< len(expected) {
				same &&= expected[b] == assembled[b]
			}
			testing.expectf(t, same, "%s: mip %d is not the blocks of the plain cook", usage, mip)
		}
		tail := format.texture_tail(paged_data, paged)
		whole_mips := format.blob_bytes(whole_data, whole.mips)
		expected_tail := whole_mips[len(whole_mips) - len(tail):]
		same := len(tail) > 0
		for b in 0 ..< len(tail) {
			same &&= expected_tail[b] == tail[b]
		}
		testing.expectf(t, same, "%s: the tail is not the plain cook's last mips", usage)
	}
}

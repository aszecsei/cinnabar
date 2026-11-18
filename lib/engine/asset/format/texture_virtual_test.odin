package asset_format

import "core:testing"

// virtual_texture_blob writes a size texture of format as a virtual blob with a block of 20 bytes for each page. A page's
// payload is not in it: format does not decompress.
@(private = "file")
virtual_texture_blob :: proc(format: Texture_Format, size: [2]u32) -> []byte {
	mip_count: u32 = 1
	for max(size.x >> mip_count, size.y >> mip_count) > 0 {
		mip_count += 1
	}
	tail_mip := texture_tail_mip(size, mip_count)
	pages := make([dynamic]Texture_Page_Contents, context.temp_allocator)
	for mip in 0 ..< tail_mip {
		w, h := max(size.x >> mip, 1), max(size.y >> mip, 1)
		count := (w + 127) / 128 * ((h + 127) / 128)
		for _ in 0 ..< count {
			append(
				&pages,
				Texture_Page_Contents {
					record = {size = u32(texture_page_payload_size(format)), checksum = 7},
					compressed = make([]byte, 20, context.temp_allocator),
				},
			)
		}
	}
	pages[len(pages) - 1].record.flags = {.Root}
	for &p, i in pages {
		for &b in p.compressed {
			b = u8(i + 1)
		}
	}
	tail := make(
		[]byte,
		texture_tail_size(format, size, tail_mip, mip_count),
		context.temp_allocator,
	)
	return aligned(
		texture_write(
			{
				guid = guid_parse(TEST_GUID) or_else {},
				format = format,
				usage = .Color,
				size = size,
				mip_count = mip_count,
				mips = tail,
				flags = {.Virtual},
				pages = pages[:],
				source_path = "game/big.png",
			},
			context.temp_allocator,
		),
	)
}

// A 512 by 384 texture has three paged mips, of 4 by 3, 2 by 2 and 1 by 1 pages, and a tail from its 64 by 48 mip on.
// Its head, which is all that a reader holds, checks as well as the whole blob.
@(test)
virtual_textures_have_levels_and_pages :: proc(t: ^testing.T) {
	data := virtual_texture_blob(.BC7_Unorm_Srgb, {512, 384})
	blob, ok := texture_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.mip_count, 10)
	testing.expect_value(t, blob.tail_mip, 3)
	testing.expect_value(t, blob.mips.size, 0)
	levels := texture_levels(data, blob)
	pages := texture_pages(data, blob)
	testing.expect_value(t, len(levels), 3)
	testing.expect_value(t, len(pages), 17)
	testing.expect_value(t, levels[0], Texture_Level{{512, 384}, {4, 3}, 0})
	testing.expect_value(t, levels[1], Texture_Level{{256, 192}, {2, 2}, 12})
	testing.expect_value(t, levels[2], Texture_Level{{128, 96}, {1, 1}, 16})
	testing.expect_value(
		t,
		len(texture_tail(data, blob)),
		texture_chain_size(.BC7_Unorm_Srgb, {64, 48}, 7),
	)
	testing.expect_value(t, blob.file_size, u64(len(data)))
	testing.expect(t, blob.head_size < blob.file_size)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/big.png")
	testing.expect_value(t, pages[16].flags, Texture_Page_Flags{.Root})
	testing.expect(t, pages[16].offset + u64(pages[16].compressed_size) == blob.head_size)
	testing.expect_value(t, pages[5].mip, 0)
	testing.expect_value(t, pages[5].x, 1)
	testing.expect_value(t, pages[5].y, 1)
	testing.expect_value(t, pages[15].x, 1)
	testing.expect_value(t, pages[15].y, 1)
	for p, i in pages[:16] {
		testing.expect(t, p.offset >= blob.head_size)
		mip, found := texture_page_level(levels, u32(i))
		testing.expect(t, found)
		testing.expect_value(t, mip, u32(p.mip))
	}
	_, found := texture_page_level(levels, 17)
	testing.expect(t, !found)

	size, is_virtual := texture_head_size(data)
	testing.expect(t, is_virtual)
	testing.expect_value(t, size, blob.head_size)
	head := aligned(data[:size])
	head_blob, head_ok := texture_view(head)
	testing.expect(t, head_ok, "the head alone checks")
	if head_ok {
		testing.expect_value(t, head_blob.file_size, u64(len(data)))
	}
	short := aligned(data[:size - 1])
	_, short_ok := texture_view(short)
	testing.expect(t, !short_ok, "a head without its root does not")
}

@(test)
a_texture_that_is_not_virtual_has_no_head_of_its_own :: proc(t: ^testing.T) {
	mips := make([]byte, texture_chain_size(.BC7_Unorm_Srgb, {8, 4}, 3), context.temp_allocator)
	data := aligned(
		texture_write(
			{format = .BC7_Unorm_Srgb, size = {8, 4}, mip_count = 3, mips = mips},
			context.temp_allocator,
		),
	)
	blob, ok := texture_view(data)
	testing.expect(t, ok)
	testing.expect_value(t, blob.head_size, u64(len(data)))
	testing.expect_value(t, blob.file_size, u64(len(data)))
	_, is_virtual := texture_head_size(data)
	testing.expect(t, !is_virtual)
}

@(test)
virtual_texture_views_refuse_inconsistent_tables :: proc(t: ^testing.T) {
	good := virtual_texture_blob(.BC5_Unorm, {512, 384})
	Case :: struct {
		name:   string,
		change: proc(data: []byte, blob: ^Texture_Blob),
	}
	cases := []Case {
		{"tail mip", proc(data: []byte, blob: ^Texture_Blob) {blob.tail_mip = 2}},
		{"mips", proc(data: []byte, blob: ^Texture_Blob) {blob.mips = blob.tail}},
		{"tail size", proc(data: []byte, blob: ^Texture_Blob) {blob.tail.size -= 16}},
		{
			"head size",
			proc(data: []byte, blob: ^Texture_Blob) {blob.head_size = size_of(Texture_Blob)},
		},
		{"cube", proc(data: []byte, blob: ^Texture_Blob) {blob.dimension = .Cube}},
		{"format", proc(data: []byte, blob: ^Texture_Blob) {blob.format = .RGBA8_Unorm}},
		{
			"level size",
			proc(data: []byte, blob: ^Texture_Blob) {texture_levels(data, blob)[1].size.x = 252},
		},
		{
			"level grid",
			proc(data: []byte, blob: ^Texture_Blob) {texture_levels(data, blob)[0].grid.y = 4},
		},
		{
			"first page",
			proc(data: []byte, blob: ^Texture_Blob) {texture_levels(data, blob)[2].first_page = 15},
		},
		{"page mip", proc(data: []byte, blob: ^Texture_Blob) {texture_pages(data, blob)[4].mip = 1}},
		{"page x", proc(data: []byte, blob: ^Texture_Blob) {texture_pages(data, blob)[1].x = 2}},
		{"page y", proc(data: []byte, blob: ^Texture_Blob) {texture_pages(data, blob)[1].y = 1}},
		{
			"page size",
			proc(data: []byte, blob: ^Texture_Blob) {texture_pages(data, blob)[1].size -= 4},
		},
		{
			"page flags",
			proc(data: []byte, blob: ^Texture_Blob) {texture_pages(data, blob)[3].flags = {.Root}},
		},
		{
			"root flag",
			proc(data: []byte, blob: ^Texture_Blob) {texture_pages(data, blob)[16].flags = {}},
		},
		{
			"root past the head",
			proc(data: []byte, blob: ^Texture_Blob) {
				texture_pages(data, blob)[16].compressed_size += 64
			},
		},
		{
			"page in the head",
			proc(data: []byte, blob: ^Texture_Blob) {
				texture_pages(data, blob)[0].offset = blob.head_size - 16
			},
		},
		{
			"page past the file",
			proc(data: []byte, blob: ^Texture_Blob) {
				texture_pages(data, blob)[2].offset = blob.file_size
			},
		},
		{
			"empty page",
			proc(data: []byte, blob: ^Texture_Blob) {
				texture_pages(data, blob)[2].compressed_size = 0
			},
		},
		{
			"page count",
			proc(data: []byte, blob: ^Texture_Blob) {blob.pages.size -= size_of(Texture_Page)},
		},
	}
	for c in cases {
		data := aligned(good)
		c.change(data, (^Texture_Blob)(raw_data(data)))
		_, ok := texture_view(data)
		testing.expectf(t, !ok, "a blob with a bad %s checks", c.name)
	}
}

// Stripping every page of a level puts each page's interior blocks where they are in the whole mip, and a page that
// hangs past the mip's edge gives only the blocks that the mip has.
@(test)
page_strips_assemble_a_mip :: proc(t: ^testing.T) {
	format := Texture_Format.BC7_Unorm_Srgb
	// 520 by 260 has a 5 by 3 grid: its last column and row hold 8 and 4 texels.
	level := Texture_Level {
		size = {520, 260},
		grid = {5, 3},
	}
	mip_blocks := [2]int{130, 65}
	whole := make(
		[]byte,
		texture_mip_size(format, level.size.x, level.size.y),
		context.temp_allocator,
	)
	testing.expect_value(t, len(whole), 130 * 65 * 16)
	for page_y in 0 ..< u32(3) {
		for page_x in 0 ..< u32(5) {
			payload := make([]byte, texture_page_payload_size(format), context.temp_allocator)
			for by in 0 ..< 34 {
				for bx in 0 ..< 34 {
					block := payload[(by * 34 + bx) * 16:][:16]
					block[0], block[1] = u8(page_x), u8(page_y)
					block[2], block[3] = u8(bx), u8(by)
				}
			}
			texture_page_strip(format, payload, level, page_x, page_y, whole)
		}
	}
	for y in 0 ..< mip_blocks.y {
		for x in 0 ..< mip_blocks.x {
			block := whole[(y * mip_blocks.x + x) * 16:]
			from_its_page :=
				block[0] == u8(x / 32) &&
				block[1] == u8(y / 32) &&
				block[2] == u8(x % 32 + 1) &&
				block[3] == u8(y % 32 + 1)
			if !from_its_page {
				testing.expectf(t, false, "block %d, %d is not from the page that holds it", x, y)
				return
			}
		}
	}
}

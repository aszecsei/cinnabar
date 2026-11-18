package asset_format

import "core:mem"

import "cinnabar:core/layout"

// Texture_Format is a texture blob's format. The format package imports nothing from lib/core/gpu, so the runtime maps
// these to gpu.Format.
Texture_Format :: enum u32 {
	RGBA8_Unorm,
	BC1_Unorm,
	BC1_Unorm_Srgb,
	BC4_Unorm,
	BC5_Unorm,
	BC6H_Ufloat,
	BC7_Unorm,
	BC7_Unorm_Srgb,
	R16_Unorm,
}

// Texture_Usage is how a texture is used, which its import setting `usage` names. It selects the format and the mip
// filter (see docs/content/kinds/textures.md#textures).
Texture_Usage :: enum u32 {
	Color,
	Normal,
	Mask,
	HDR,
	Data,
	Height,
}

// Texture_Dimension is what a texture blob's layers are. A cube's six layers are its faces, in the order +x, -x, +y, -y,
// +z, -z.
Texture_Dimension :: enum u32 {
	D2,
	Cube,
	D2_Array,
}

// Texture_Wrap is what a texture's sampler does past its edges, and what its mips filter across them: its import
// setting `[sampler] wrap`.
Texture_Wrap :: enum u8 {
	Repeat,
	Clamp,
	Mirror,
}

// Texture_Filter is how a texture's sampler blends texels, or mips: the nearest one, or the nearest ones weighted.
Texture_Filter :: enum u8 {
	Linear,
	Nearest,
}

// MAX_TEXTURE_ANISOTROPY is the most anisotropy that a texture's sampler asks for, which is what D3D12 allows.
MAX_TEXTURE_ANISOTROPY :: 16

// Texture_Sampler is how a texture asks to be sampled: its import settings in `[sampler]` (see
// docs/content/kinds/textures.md#textures). The zero value repeats and filters linearly, without anisotropy.
Texture_Sampler :: struct {
	wrap:       Texture_Wrap,
	// Between texels, when the texture is magnified or minified.
	filter:     Texture_Filter,
	// Between mips.
	mip_filter: Texture_Filter,
	// 0 or 1 is none. The renderer's quality caps it.
	anisotropy: u8,
}

// TEXTURE_SET_EXTENSION is the text source of a cube or an array that names its layers' images by GUID (see
// docs/content/kinds/textures.md#texture-sets).
TEXTURE_SET_EXTENSION :: ".texture_set"
// MAX_TEXTURE_LAYERS is the most layers that an array has, which is what D3D12 allows.
MAX_TEXTURE_LAYERS :: 2048

// TEXTURE_PAGE_SIZE is the texels per side that a virtual texture's page holds of its mip.
TEXTURE_PAGE_SIZE :: 128
// TEXTURE_PAGE_BORDER is the texels around a page's payload that are its neighbours', so that filtering inside the page
// reads real texels.
TEXTURE_PAGE_BORDER :: 4
// TEXTURE_PAGE_TEXELS is a page's tile: its payload and a border on each side.
TEXTURE_PAGE_TEXELS :: TEXTURE_PAGE_SIZE + 2 * TEXTURE_PAGE_BORDER
// TEXTURE_TAIL_SIZE is the largest side of the first mip that a virtual texture keeps whole, in its head.
TEXTURE_TAIL_SIZE :: 64

Texture_Flag :: enum u32 {
	// The texture's mips 0 up to tail_mip are LZ4 pages that stream (see docs/content/kinds/textures.md#virtual-textures).
	Virtual,
}

Texture_Flags :: bit_set[Texture_Flag;u32]

// Texture_Level is a paged mip of a virtual texture.
Texture_Level :: struct {
	// The mip's texels.
	size:       [2]u32,
	// Its pages across and down: size over TEXTURE_PAGE_SIZE, rounded up.
	grid:       [2]u32,
	// Its first page in the table, which has its pages row by row.
	first_page: u32,
}

Texture_Page_Flag :: enum u32 {
	// The page is the last level's only one. It is in the blob's head, and always resident.
	Root,
}

Texture_Page_Flags :: bit_set[Texture_Page_Flag;u32]

// Texture_Page is one page in a virtual texture's table: where its LZ4 block is in the blob, and which texels it holds.
// Uncompressed it is a TEXTURE_PAGE_TEXELS square of the mip's texels from (x * TEXTURE_PAGE_SIZE - TEXTURE_PAGE_BORDER,
// y * TEXTURE_PAGE_SIZE - TEXTURE_PAGE_BORDER), block-compressed in the texture's format, with rows of blocks tightly
// packed. Texels past the mip's edges are what the sampler's wrap gives.
Texture_Page :: struct {
	// From the blob's start.
	offset:          u64,
	compressed_size: u32,
	// Before compression: texture_page_payload_size.
	size:            u32,
	// fnv32a of the compressed bytes, which tells a page of this blob from bytes of a blob cooked over it.
	checksum:        u32,
	flags:           Texture_Page_Flags,
	// Which mip, and which page of its grid. They follow from the page's place in the table: a reader checks them.
	mip:             u16,
	x:               u16,
	y:               u16,
}

// Texture_Blob is the start of a texture blob (see docs/content/blobs-and-loading.md#blob-format).
Texture_Blob :: struct {
	header:      Blob_Header,
	format:      Texture_Format,
	usage:       Texture_Usage,
	dimension:   Texture_Dimension,
	layer_count: u32,
	// Of each layer.
	size:        [2]u32,
	mip_count:   u32,
	sampler:     Texture_Sampler,
	// Each layer's whole mip chain, layer 0 first, each mip tightly packed, mip 0 first, as gpu_stream_texture takes it.
	// It starts at BLOB_ALIGN. Empty for a virtual texture, whose mips are in its pages and its tail.
	mips:        Slice,
	source_path: Slice,
	flags:       Texture_Flags,
	// A virtual texture's first mip of the tail: the first whose sides are both at most TEXTURE_TAIL_SIZE. Its mips 0 up
	// to it are paged, one Texture_Level each, and the last of them is one page, the root.
	tail_mip:    u32,
	// A virtual texture's Texture_Level of each paged mip, its Texture_Page table, level by level and row by row, and
	// its mips tail_mip on, tightly packed as mips is, uncompressed. All empty for any other texture. The tail starts
	// at BLOB_ALIGN.
	levels:      Slice,
	pages:       Slice,
	tail:        Slice,
	// The blob's first head_size bytes are all that a reader needs to start: everything but the pages that stream, and
	// the root page's block ends it. file_size is the whole blob. Both are its size for a texture that is not virtual.
	head_size:   u64,
	file_size:   u64,
}

texture_layout :: proc() -> u64 {
	return(
		layout.hash(Texture_Blob) ~
		layout.hash(Texture_Level) * 31 ~
		layout.hash(Texture_Page) * 961 \
	)
}

// texture_format_block is the size of a format's 4x4 block in bytes, or 0 for a format that is not block-compressed.
texture_format_block :: proc "contextless" (format: Texture_Format) -> int {
	switch format {
	case .RGBA8_Unorm, .R16_Unorm:
		return 0
	case .BC1_Unorm, .BC1_Unorm_Srgb, .BC4_Unorm:
		return 8
	case .BC5_Unorm, .BC6H_Ufloat, .BC7_Unorm, .BC7_Unorm_Srgb:
		return 16
	}
	return 0
}

// texture_mip_size is the size of one mip, tightly packed: rows of texels, or rows of 4x4 blocks.
texture_mip_size :: proc "contextless" (format: Texture_Format, width, height: u32) -> int {
	if block := texture_format_block(format); block != 0 {
		return int((width + 3) / 4) * int((height + 3) / 4) * block
	}
	return int(width) * int(height) * texture_format_texel(format)
}

// texture_format_texel is the size of one texel in bytes of a format that is not block-compressed, or 0 for one that is.
texture_format_texel :: proc "contextless" (format: Texture_Format) -> int {
	switch format {
	case .RGBA8_Unorm:
		return 4
	case .R16_Unorm:
		return 2
	case .BC1_Unorm,
	     .BC1_Unorm_Srgb,
	     .BC4_Unorm,
	     .BC5_Unorm,
	     .BC6H_Ufloat,
	     .BC7_Unorm,
	     .BC7_Unorm_Srgb:
		return 0
	}
	return 0
}

// texture_chain_size is the size of one layer's mip chain.
texture_chain_size :: proc "contextless" (
	format: Texture_Format,
	size: [2]u32,
	mip_count: u32,
) -> (
	total: int,
) {
	for mip in 0 ..< mip_count {
		total += texture_mip_size(format, max(size.x >> mip, 1), max(size.y >> mip, 1))
	}
	return
}

// texture_box_chain_r16 is the mip chain of size R16_Unorm texels, row-major, as Texture_Blob.mips holds it, down to 1
// by 1: each texel of a mip is the mean of the 2 by 2 texels of the one before it, rounded up, clamped at an odd edge.
// So a mip reads 0 only where every texel under it does, as a mask's box mips do (see
// docs/rendering/surfaces.md#holes).
texture_box_chain_r16 :: proc(
	size: [2]u32,
	texels: []u16,
	allocator := context.allocator,
) -> (
	mips: []byte,
	mip_count: u32,
) {
	mip_count = 1
	for max(size.x >> mip_count, size.y >> mip_count) > 0 {
		mip_count += 1
	}
	mips = make([]byte, texture_chain_size(.R16_Unorm, size, mip_count), allocator)
	level := ([^]u16)(raw_data(mips))[:int(size.x) * int(size.y)]
	copy(level, texels)
	offset := len(level)
	from := size
	for mip in 1 ..< mip_count {
		to := [2]u32{max(size.x >> mip, 1), max(size.y >> mip, 1)}
		next := ([^]u16)(raw_data(mips))[offset:][:int(to.x) * int(to.y)]
		for y in 0 ..< to.y {
			y0, y1 := min(2 * y, from.y - 1), min(2 * y + 1, from.y - 1)
			for x in 0 ..< to.x {
				x0, x1 := min(2 * x, from.x - 1), min(2 * x + 1, from.x - 1)
				sum :=
					u32(level[y0 * from.x + x0]) +
					u32(level[y0 * from.x + x1]) +
					u32(level[y1 * from.x + x0]) +
					u32(level[y1 * from.x + x1])
				next[y * to.x + x] = u16((sum + 3) / 4)
			}
		}
		level, offset, from = next, offset + len(next), to
	}
	return
}

// texture_box_chain_rgba8 is the mip chain of size RGBA8_Unorm texels, four bytes each, row-major, as Texture_Blob.mips
// holds it, down to 1 by 1: each channel of a mip's texel is the mean of the 2 by 2 texels' of the one before it,
// rounded to the nearest, clamped at an odd edge.
texture_box_chain_rgba8 :: proc(
	size: [2]u32,
	texels: []u8,
	allocator := context.allocator,
) -> (
	mips: []byte,
	mip_count: u32,
) {
	mip_count = 1
	for max(size.x >> mip_count, size.y >> mip_count) > 0 {
		mip_count += 1
	}
	mips = make([]byte, texture_chain_size(.RGBA8_Unorm, size, mip_count), allocator)
	level := mips[:int(size.x) * int(size.y) * 4]
	copy(level, texels)
	offset := len(level)
	from := size
	for mip in 1 ..< mip_count {
		to := [2]u32{max(size.x >> mip, 1), max(size.y >> mip, 1)}
		next := mips[offset:][:int(to.x) * int(to.y) * 4]
		for y in 0 ..< to.y {
			y0, y1 := min(2 * y, from.y - 1), min(2 * y + 1, from.y - 1)
			for x in 0 ..< to.x {
				x0, x1 := min(2 * x, from.x - 1), min(2 * x + 1, from.x - 1)
				for c in u32(0) ..< 4 {
					sum :=
						u32(level[(y0 * from.x + x0) * 4 + c]) +
						u32(level[(y0 * from.x + x1) * 4 + c]) +
						u32(level[(y1 * from.x + x0) * 4 + c]) +
						u32(level[(y1 * from.x + x1) * 4 + c])
					next[(y * to.x + x) * 4 + c] = u8((sum + 2) / 4)
				}
			}
		}
		level, offset, from = next, offset + len(next), to
	}
	return
}

// texture_channel decodes the first channel of one mip of size texels, from 0 to 1, row-major with x fastest: R16_Unorm,
// RGBA8_Unorm's red, or BC4_Unorm. It fails for another format, or a mip of the wrong size.
texture_channel :: proc(
	format: Texture_Format,
	size: [2]u32,
	mip: []byte,
	allocator := context.allocator,
) -> (
	values: []f32,
	ok: bool,
) {
	if len(mip) != texture_mip_size(format, size.x, size.y) {
		return
	}
	#partial switch format {
	case .R16_Unorm, .RGBA8_Unorm, .BC4_Unorm:
	case:
		return
	}
	values = make([]f32, int(size.x) * int(size.y), allocator)
	#partial switch format {
	case .R16_Unorm:
		for &v, i in values {
			v = f32(u16(mip[2 * i]) | u16(mip[2 * i + 1]) << 8) / 65535
		}
	case .RGBA8_Unorm:
		for &v, i in values {
			v = f32(mip[4 * i]) / 255
		}
	case .BC4_Unorm:
		blocks := [2]int{int(size.x + 3) / 4, int(size.y + 3) / 4}
		for by in 0 ..< blocks.y {
			for bx in 0 ..< blocks.x {
				texels := texture_bc4_block(mip[(by * blocks.x + bx) * 8:][:8])
				for k in 0 ..< 16 {
					x, y := bx * 4 + k % 4, by * 4 + k / 4
					if x < int(size.x) && y < int(size.y) {
						values[y * int(size.x) + x] = f32(texels[k]) / 255
					}
				}
			}
		}
	}
	return values, true
}

// texture_bc4_block decodes one BC4 block of 8 bytes into its 16 texels, row-major: two endpoints, then a 3-bit index
// a texel into the eight values between them, or six between them with 0 and 255 when the first is not above the
// second.
texture_bc4_block :: proc(block: []byte) -> (texels: [16]u8) {
	r0, r1 := u32(block[0]), u32(block[1])
	palette: [8]u32
	palette[0], palette[1] = r0, r1
	if r0 > r1 {
		for i in u32(1) ..< 7 {
			palette[i + 1] = ((7 - i) * r0 + i * r1 + 3) / 7
		}
	} else {
		for i in u32(1) ..< 5 {
			palette[i + 1] = ((5 - i) * r0 + i * r1 + 2) / 5
		}
		palette[6], palette[7] = 0, 255
	}
	bits: u64
	for i in 0 ..< 6 {
		bits |= u64(block[2 + i]) << (8 * u64(i))
	}
	for k in 0 ..< 16 {
		texels[k] = u8(palette[(bits >> (3 * u64(k))) & 7])
	}
	return
}

// texture_page_payload_size is the size of a page of a format, uncompressed: its tile's blocks, or 0 for a format that is
// not block-compressed.
texture_page_payload_size :: proc "contextless" (format: Texture_Format) -> int {
	blocks := TEXTURE_PAGE_TEXELS / 4
	return blocks * blocks * texture_format_block(format)
}

// texture_tail_mip is the first mip of a mip chain whose sides are both at most TEXTURE_TAIL_SIZE, which is where a
// virtual texture's tail starts. It is mip_count if no mip of the chain is.
texture_tail_mip :: proc "contextless" (size: [2]u32, mip_count: u32) -> u32 {
	for mip in 0 ..< mip_count {
		if max(size.x >> mip, 1) <= TEXTURE_TAIL_SIZE &&
		   max(size.y >> mip, 1) <= TEXTURE_TAIL_SIZE {
			return mip
		}
	}
	return mip_count
}

// texture_tail_size is the size of the mips from tail_mip on of a mip chain of one layer, tightly packed.
texture_tail_size :: proc "contextless" (
	format: Texture_Format,
	size: [2]u32,
	tail_mip, mip_count: u32,
) -> int {
	if tail_mip >= mip_count {
		return 0
	}
	return texture_chain_size(
		format,
		{max(size.x >> tail_mip, 1), max(size.y >> tail_mip, 1)},
		mip_count - tail_mip,
	)
}

// texture_levels is a virtual texture's levels, empty for any other texture.
texture_levels :: proc "contextless" (data: []byte, blob: ^Texture_Blob) -> []Texture_Level {
	bytes := blob_bytes(data, blob.levels)
	return ([^]Texture_Level)(raw_data(bytes))[:len(bytes) / size_of(Texture_Level)]
}

// texture_pages is a virtual texture's page table, empty for any other texture.
texture_pages :: proc "contextless" (data: []byte, blob: ^Texture_Blob) -> []Texture_Page {
	bytes := blob_bytes(data, blob.pages)
	return ([^]Texture_Page)(raw_data(bytes))[:len(bytes) / size_of(Texture_Page)]
}

// texture_tail is a virtual texture's mips from tail_mip on, empty for any other texture.
texture_tail :: proc "contextless" (data: []byte, blob: ^Texture_Blob) -> []byte {
	return blob_bytes(data, blob.tail)
}

// texture_mips_from is a texture's mips from mip on, in the order that the GPU takes a stream in: each layer's chain after
// the other, mip first. The texture's layer 0 is a slice of the blob's, and the layers of an array or a cube are copied
// into memory from allocator. It is empty if mip is past the chain or the blob is shorter than its header says.
texture_mips_from :: proc(
	data: []byte,
	blob: ^Texture_Blob,
	mip: u32,
	allocator := context.allocator,
) -> []byte {
	mips := blob_bytes(data, blob.mips)
	layers := max(int(blob.layer_count), 1)
	chain := texture_chain_size(blob.format, blob.size, blob.mip_count)
	skip := texture_chain_size(blob.format, blob.size, mip)
	rest := texture_tail_size(blob.format, blob.size, mip, blob.mip_count)
	if mip >= blob.mip_count || rest == 0 || len(mips) < chain * layers {
		return nil
	}
	if layers == 1 {
		return mips[skip:][:rest]
	}
	from_mip := make([]byte, rest * layers, allocator)
	for layer in 0 ..< layers {
		copy(from_mip[layer * rest:], mips[layer * chain + skip:][:rest])
	}
	return from_mip
}

// texture_page_level is the paged mip that a page of the table is in, or false for a page that no level has.
texture_page_level :: proc "contextless" (
	levels: []Texture_Level,
	page: u32,
) -> (
	mip: u32,
	ok: bool,
) {
	for l, i in levels {
		if page >= l.first_page && u64(page) < u64(l.first_page) + u64(l.grid.x) * u64(l.grid.y) {
			return u32(i), true
		}
	}
	return
}

// texture_page_strip copies the blocks of a page's payload that are its mip's own, without its border and clipped to
// the mip, into dst_mip, which holds the whole mip tightly packed: rows of blocks, level.size over 4 rounded up across.
// payload is the page uncompressed. A reader that has every page of a level assembles the level with it.
texture_page_strip :: proc(
	format: Texture_Format,
	payload: []byte,
	level: Texture_Level,
	page_x, page_y: u32,
	dst_mip: []byte,
) {
	block := texture_format_block(format)
	if block == 0 || page_x >= level.grid.x || page_y >= level.grid.y {
		return
	}
	tile_blocks := TEXTURE_PAGE_TEXELS / 4
	border_blocks := TEXTURE_PAGE_BORDER / 4
	mip_blocks := [2]int{int(level.size.x + 3) / 4, int(level.size.y + 3) / 4}
	first := [2]int{int(page_x) * TEXTURE_PAGE_SIZE / 4, int(page_y) * TEXTURE_PAGE_SIZE / 4}
	count := [2]int {
		min(TEXTURE_PAGE_SIZE / 4, mip_blocks.x - first.x),
		min(TEXTURE_PAGE_SIZE / 4, mip_blocks.y - first.y),
	}
	for row in 0 ..< count.y {
		from := ((border_blocks + row) * tile_blocks + border_blocks) * block
		to := ((first.y + row) * mip_blocks.x + first.x) * block
		copy(dst_mip[to:][:count.x * block], payload[from:][:count.x * block])
	}
}

// texture_head_size is how many of a blob's first bytes a reader needs, from at least its first size_of(Texture_Blob)
// bytes: the head of a virtual texture. It is false for any other blob, which a reader needs the whole of.
texture_head_size :: proc(start: []byte) -> (size: u64, ok: bool) {
	header := blob_header(start) or_return
	if header.kind != .Texture ||
	   header.layout != texture_layout() ||
	   len(start) < size_of(Texture_Blob) {
		return
	}
	blob := (^Texture_Blob)(raw_data(start))
	if .Virtual not_in blob.flags ||
	   blob.head_size < size_of(Texture_Blob) ||
	   blob.head_size > blob.file_size {
		return
	}
	return blob.head_size, true
}

// texture_view checks a texture blob: its header, its layout, its slices, that its layers suit its dimension, and that
// its mips are the size that its format, size, mip count and layer count give. A virtual texture's head, which is all
// that a reader of it holds, is checked as well: its levels, its page table, and its tail (see texture_view_virtual).
texture_view :: proc(data: []byte) -> (blob: ^Texture_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Texture ||
	   header.layout != texture_layout() ||
	   len(data) < size_of(Texture_Blob) {
		return
	}
	blob = (^Texture_Blob)(raw_data(data))
	for s in ([?]Slice{blob.mips, blob.source_path, blob.levels, blob.pages, blob.tail}) {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.format > max(Texture_Format) ||
	   !texture_sampler_valid(blob.sampler) ||
	   blob.mip_count == 0 ||
	   blob.size.x == 0 ||
	   blob.size.y == 0 {
		return nil, false
	}
	switch blob.dimension {
	case .D2:
		if blob.layer_count != 1 {
			return nil, false
		}
	case .Cube:
		if blob.layer_count != 6 || blob.size.x != blob.size.y {
			return nil, false
		}
	case .D2_Array:
		if blob.layer_count == 0 || blob.layer_count > MAX_TEXTURE_LAYERS {
			return nil, false
		}
	case:
		return nil, false
	}
	if blob.flags - {.Virtual} != {} {
		return nil, false
	}
	if .Virtual in blob.flags {
		return blob, texture_view_virtual(data, blob)
	}
	if int(blob.mips.size) !=
		   texture_chain_size(blob.format, blob.size, blob.mip_count) * int(blob.layer_count) ||
	   blob.tail_mip != 0 ||
	   blob.levels.size != 0 ||
	   blob.pages.size != 0 ||
	   blob.tail.size != 0 ||
	   blob.head_size != blob.file_size ||
	   blob.file_size > u64(len(data)) {
		return nil, false
	}
	return blob, true
}

// texture_view_virtual checks what texture_view checks of a virtual texture's head: that it is a 2D texture of a block
// format, that its levels are its mips' sizes with the grids and first pages that follow, that its page table has the
// pages of its levels in order, with its root, the last level's only page, in the head and every other page past it,
// and that its tail is the mips from tail_mip on.
@(private = "file")
texture_view_virtual :: proc(data: []byte, blob: ^Texture_Blob) -> bool {
	if blob.dimension != .D2 ||
	   texture_format_block(blob.format) == 0 ||
	   blob.mips.size != 0 ||
	   blob.head_size < size_of(Texture_Blob) ||
	   blob.head_size > blob.file_size ||
	   blob.head_size > u64(len(data)) ||
	   blob.levels.size % size_of(Texture_Level) != 0 ||
	   blob.levels.offset % align_of(Texture_Level) != 0 ||
	   blob.pages.size % size_of(Texture_Page) != 0 ||
	   blob.pages.offset % align_of(Texture_Page) != 0 ||
	   blob.tail.offset % BLOB_ALIGN != 0 {
		return false
	}
	for s in ([?]Slice{blob.levels, blob.pages, blob.tail, blob.source_path}) {
		if u64(s.offset) + u64(s.size) > blob.head_size {
			return false
		}
	}
	tail_mip := texture_tail_mip(blob.size, blob.mip_count)
	if tail_mip == 0 ||
	   tail_mip >= blob.mip_count ||
	   blob.tail_mip != tail_mip ||
	   max(blob.size.x, blob.size.y) <= TEXTURE_PAGE_SIZE ||
	   int(blob.tail.size) != texture_tail_size(blob.format, blob.size, tail_mip, blob.mip_count) {
		return false
	}
	levels := texture_levels(data, blob)
	pages := texture_pages(data, blob)
	if len(levels) != int(tail_mip) {
		return false
	}
	next_page: u32
	for l, mip in levels {
		size := [2]u32{max(blob.size.x >> u32(mip), 1), max(blob.size.y >> u32(mip), 1)}
		grid := [2]u32 {
			(size.x + TEXTURE_PAGE_SIZE - 1) / TEXTURE_PAGE_SIZE,
			(size.y + TEXTURE_PAGE_SIZE - 1) / TEXTURE_PAGE_SIZE,
		}
		if l.size != size || l.grid != grid || l.first_page != next_page {
			return false
		}
		next_page += grid.x * grid.y
	}
	last := levels[len(levels) - 1]
	if last.grid != {1, 1} || int(next_page) != len(pages) {
		return false
	}
	payload := texture_page_payload_size(blob.format)
	for p, i in pages {
		mip, _ := texture_page_level(levels, u32(i))
		l := levels[mip]
		in_level := u32(i) - l.first_page
		root := i == len(pages) - 1
		end := p.offset + u64(p.compressed_size)
		switch {
		case p.flags - {.Root} !=
		     {},
		     (.Root in p.flags) !=
		     root,
		     u32(p.mip) !=
		     mip,
		     u32(p.x) !=
		     in_level % l.grid.x,
		     u32(p.y) !=
		     in_level / l.grid.x,
		     p.compressed_size ==
		     0,
		     end >
		     blob.file_size,
		     root ? end > blob.head_size : p.offset < blob.head_size,
		     p.offset % BLOB_ALIGN !=
		     0,
		     int(p.size) !=
		     payload:
			return false
		}
	}
	return true
}

// texture_sampler_valid is whether a sampler's enums are in range and its anisotropy is at most MAX_TEXTURE_ANISOTROPY.
texture_sampler_valid :: proc(s: Texture_Sampler) -> bool {
	return(
		s.wrap <= max(Texture_Wrap) &&
		s.filter <= max(Texture_Filter) &&
		s.mip_filter <= max(Texture_Filter) &&
		s.anisotropy <= MAX_TEXTURE_ANISOTROPY \
	)
}

// Texture_Page_Contents is a virtual texture's page to write: its record, and its compressed block. texture_write sets
// the record's offset, compressed_size, mip, x and y.
Texture_Page_Contents :: struct {
	record:     Texture_Page,
	compressed: []byte,
}

Texture_Contents :: struct {
	guid:        Guid,
	key:         u64,
	format:      Texture_Format,
	usage:       Texture_Usage,
	dimension:   Texture_Dimension,
	// 0 means 1.
	layer_count: u32,
	size:        [2]u32,
	mip_count:   u32,
	sampler:     Texture_Sampler,
	// The layers' mip chains, as Texture_Blob.mips holds them. For a virtual texture, its tail instead, the mips from
	// tail_mip on.
	mips:        []byte,
	source_path: string,
	// With the Virtual flag: its pages, level by level and row by row, with the last one the root (flagged Root). The
	// levels and the tail mip follow from the texture's size and mip count.
	flags:       Texture_Flags,
	pages:       []Texture_Page_Contents,
}

// texture_write builds a texture blob. A virtual texture's head comes first, with its root page at its end, and the
// other pages after it.
texture_write :: proc(contents: Texture_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Texture_Blob), allocator)
	virtual := .Virtual in contents.flags
	tail_mip := virtual ? texture_tail_mip(contents.size, contents.mip_count) : 0
	levels: Slice
	pages: Slice
	if virtual {
		levels = reserve_bytes(&buffer, int(tail_mip) * size_of(Texture_Level), BLOB_ALIGN)
		pages = reserve_bytes(&buffer, len(contents.pages) * size_of(Texture_Page), BLOB_ALIGN)
	}
	mips := reserve_bytes(&buffer, len(contents.mips), BLOB_ALIGN)
	copy(buffer[mips.offset:], contents.mips)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	head_size := u64(len(buffer))
	if virtual {
		records := make([]Texture_Page, len(contents.pages), context.temp_allocator)
		// The root ends the head, and the other pages follow it. The buffer grows once for them all.
		compressed_size := 0
		for p in contents.pages {
			compressed_size += len(p.compressed) + BLOB_ALIGN
		}
		reserve(&buffer, len(buffer) + compressed_size)
		next_page: u32
		for mip in 0 ..< tail_mip {
			level := Texture_Level {
				size       = {max(contents.size.x >> mip, 1), max(contents.size.y >> mip, 1)},
				first_page = next_page,
			}
			level.grid = {
				(level.size.x + TEXTURE_PAGE_SIZE - 1) / TEXTURE_PAGE_SIZE,
				(level.size.y + TEXTURE_PAGE_SIZE - 1) / TEXTURE_PAGE_SIZE,
			}
			mem.copy(&buffer[levels.offset + mip * size_of(Texture_Level)], &level, size_of(level))
			for i in 0 ..< level.grid.x * level.grid.y {
				if int(next_page + i) < len(records) {
					records[next_page + i].mip = u16(mip)
					records[next_page + i].x = u16(i % level.grid.x)
					records[next_page + i].y = u16(i / level.grid.x)
				}
			}
			next_page += level.grid.x * level.grid.y
		}
		for root in ([2]bool{true, false}) {
			for p, i in contents.pages {
				if (.Root in p.record.flags) != root {
					continue
				}
				record := p.record
				record.mip, record.x, record.y = records[i].mip, records[i].x, records[i].y
				s := reserve_bytes(&buffer, len(p.compressed), BLOB_ALIGN)
				copy(buffer[s.offset:], p.compressed)
				record.offset = u64(s.offset)
				record.compressed_size = u32(len(p.compressed))
				records[i] = record
			}
			if root {
				head_size = u64(len(buffer))
			}
		}
		copy(buffer[pages.offset:], mem.slice_to_bytes(records))
	} else {
		head_size = u64(len(buffer))
	}
	blob := Texture_Blob {
		header = {
			magic = BLOB_MAGIC,
			kind = .Texture,
			layout = texture_layout(),
			key = contents.key,
			guid = contents.guid,
		},
		format = contents.format,
		usage = contents.usage,
		dimension = contents.dimension,
		layer_count = max(contents.layer_count, 1),
		size = contents.size,
		mip_count = contents.mip_count,
		sampler = contents.sampler,
		mips = virtual ? Slice{} : mips,
		source_path = source_path,
		flags = contents.flags,
		tail_mip = tail_mip,
		levels = levels,
		pages = pages,
		tail = virtual ? mips : Slice{},
		head_size = head_size,
		file_size = u64(len(buffer)),
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

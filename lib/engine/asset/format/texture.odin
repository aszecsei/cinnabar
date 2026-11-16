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
	// It starts at BLOB_ALIGN.
	mips:        Slice,
	source_path: Slice,
}

texture_layout :: proc() -> u64 {
	return layout.hash(Texture_Blob)
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

// texture_view checks a texture blob: its header, its layout, its slices, that its layers suit its dimension, and that
// its mips are the size that its format, size, mip count and layer count give.
texture_view :: proc(data: []byte) -> (blob: ^Texture_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Texture ||
	   header.layout != texture_layout() ||
	   len(data) < size_of(Texture_Blob) {
		return
	}
	blob = (^Texture_Blob)(raw_data(data))
	for s in ([?]Slice{blob.mips, blob.source_path}) {
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
	if int(blob.mips.size) !=
	   texture_chain_size(blob.format, blob.size, blob.mip_count) * int(blob.layer_count) {
		return nil, false
	}
	return blob, true
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
	// The layers' mip chains, as Texture_Blob.mips holds them.
	mips:        []byte,
	source_path: string,
}

// texture_write builds a texture blob.
texture_write :: proc(contents: Texture_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Texture_Blob), allocator)
	mips := reserve_bytes(&buffer, len(contents.mips), BLOB_ALIGN)
	copy(buffer[mips.offset:], contents.mips)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
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
		mips = mips,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

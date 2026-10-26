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
}

// Texture_Usage is how a texture is used, which its import setting `usage` names. It selects the format and the mip
// filter (see docs/content/kinds/textures.md#textures).
Texture_Usage :: enum u32 {
	Color,
	Normal,
	Mask,
	HDR,
	Data,
}

// Texture_Blob is the start of a texture blob (see docs/content/blobs-and-loading.md#blob-format).
Texture_Blob :: struct {
	header:      Blob_Header,
	format:      Texture_Format,
	usage:       Texture_Usage,
	size:        [2]u32,
	mip_count:   u32,
	// The whole mip chain, each mip tightly packed, mip 0 first, as gpu_stream_texture takes it. It starts at
	// BLOB_ALIGN.
	mips:        Slice,
	source_path: Slice,
}

texture_layout :: proc() -> u64 {
	return layout.hash(Texture_Blob)
}

// texture_format_block is the size of a format's 4x4 block in bytes, or 0 for a format that is not block-compressed.
texture_format_block :: proc "contextless" (format: Texture_Format) -> int {
	switch format {
	case .RGBA8_Unorm:
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
	return int(width) * int(height) * 4
}

// texture_chain_size is the size of a mip chain.
texture_chain_size :: proc "contextless" (format: Texture_Format, size: [2]u32, mip_count: u32) -> (total: int) {
	for mip in 0 ..< mip_count {
		total += texture_mip_size(format, max(size.x >> mip, 1), max(size.y >> mip, 1))
	}
	return
}

// texture_view checks a texture blob: its header, its layout, its slices, and that its mips are the size that its
// format, size and mip count give.
texture_view :: proc(data: []byte) -> (blob: ^Texture_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Texture || header.layout != texture_layout() || len(data) < size_of(Texture_Blob) {
		return
	}
	blob = (^Texture_Blob)(raw_data(data))
	for s in ([?]Slice{blob.mips, blob.source_path}) {
		if u64(s.offset) + u64(s.size) > u64(len(data)) {
			return nil, false
		}
	}
	if blob.format > max(Texture_Format) || blob.mip_count == 0 || blob.size.x == 0 || blob.size.y == 0 {
		return nil, false
	}
	if int(blob.mips.size) != texture_chain_size(blob.format, blob.size, blob.mip_count) {
		return nil, false
	}
	return blob, true
}

Texture_Contents :: struct {
	guid:        Guid,
	key:         u64,
	format:      Texture_Format,
	usage:       Texture_Usage,
	size:        [2]u32,
	mip_count:   u32,
	// The mip chain, as Texture_Blob.mips holds it.
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
		header = {magic = BLOB_MAGIC, kind = .Texture, layout = texture_layout(), key = contents.key, guid = contents.guid},
		format = contents.format,
		usage = contents.usage,
		size = contents.size,
		mip_count = contents.mip_count,
		mips = mips,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

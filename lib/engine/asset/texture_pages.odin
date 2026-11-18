package asset

import "core:hash"
import "core:log"
import "core:mem"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

// Texture_Page_Error is why a virtual texture's page does not go into its mip.
Texture_Page_Error :: enum u8 {
	None,
	// The block is not the one that the table names: a blob cooked over this one.
	Checksum,
	// The block does not decompress to the page's tile.
	Decompress,
}

// texture_page_place checks a page's LZ4 block against its record, decompresses it into payload, which holds the tile
// uncompressed (format.texture_page_payload_size of its format), and copies the page's own texels' blocks into dst_mip,
// which holds the whole mip as format.texture_page_strip takes it.
texture_page_place :: proc(
	texture_format: format.Texture_Format,
	record: format.Texture_Page,
	level: format.Texture_Level,
	block, payload, dst_mip: []byte,
) -> Texture_Page_Error {
	if hash.fnv32a(block) != record.checksum {
		return .Checksum
	}
	if len(payload) != format.texture_page_payload_size(texture_format) ||
	   len(payload) != int(record.size) ||
	   !lz4.decompress(block, payload) {
		return .Decompress
	}
	format.texture_page_strip(
		texture_format,
		payload,
		level,
		u32(record.x),
		u32(record.y),
		dst_mip,
	)
	return .None
}

// texture_mip0 assembles mip 0 of a virtual texture from its pages, blocking: the root's block, if mip 0 is one page, is
// in head, the blob's head that the asset holds, and the other blocks are read from the blob's file in one read. mip is
// the whole mip in allocator, as it is in a texture that is not virtual, and its read is in frame memory. It fails, with
// a log line, for a blob that is not virtual, a file that is not stored as it is, one that is shorter than its table
// says, or a page that is not the table's.
texture_mip0 :: proc(
	a: ^Assets,
	guid: format.Guid,
	head: []byte,
	blob: ^format.Texture_Blob,
	allocator: mem.Allocator,
) -> (
	mip: []byte,
	ok: bool,
) {
	buffer: [32]u8
	name := format.guid_format(guid, &buffer)
	levels := format.texture_levels(head, blob)
	pages := format.texture_pages(head, blob)
	if .Virtual not_in blob.flags || len(levels) == 0 || len(pages) == 0 {
		log.errorf("asset: texture %s is not virtual, so it has no pages", name)
		return
	}
	level := levels[0]
	count := int(level.grid.x) * int(level.grid.y)
	if int(level.first_page) + count > len(pages) {
		log.errorf("asset: texture %s has a page table that is too short for its mip 0", name)
		return
	}
	level_pages := pages[level.first_page:][:count]
	// The blocks that are not in the head are in the file, after it, and one read has them all.
	first, end: u64
	for p in level_pages {
		if .Root in p.flags {
			continue
		}
		if end == 0 {
			first = p.offset
		}
		first = min(first, p.offset)
		end = max(end, p.offset + u64(p.compressed_size))
	}
	file: []byte
	if end != 0 {
		location, found := blob_location(a, guid)
		if !found || !location.raw {
			log.errorf(
				"asset: texture %s is not stored as it is, so its pages cannot be read",
				name,
			)
			return
		}
		if a.platform.file_read_range == nil || end > blob.file_size {
			log.errorf("asset: texture %s has pages that its file cannot give", name)
			return
		}
		file = make([]byte, end - first, a.platform.frame_allocator)
		if a.platform.file_read_range(location.path, location.offset + i64(first), file) !=
		   len(file) {
			log.errorf("asset: texture %s has pages that are not all in its file", name)
			return
		}
	}
	payload := make(
		[]byte,
		format.texture_page_payload_size(blob.format),
		a.platform.frame_allocator,
	)
	mip = make([]byte, format.texture_mip_size(blob.format, level.size.x, level.size.y), allocator)
	for p in level_pages {
		block: []byte
		if .Root in p.flags {
			if p.offset + u64(p.compressed_size) > u64(len(head)) {
				log.errorf("asset: texture %s has a root page that its head does not hold", name)
				delete(mip, allocator)
				return nil, false
			}
			block = head[p.offset:][:p.compressed_size]
		} else {
			block = file[p.offset - first:][:p.compressed_size]
		}
		if err := texture_page_place(blob.format, p, level, block, payload, mip); err != .None {
			log.errorf("asset: texture %s has a page that is not valid: %v", name, err)
			delete(mip, allocator)
			return nil, false
		}
	}
	return mip, true
}

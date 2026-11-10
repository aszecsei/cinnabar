// Package lz4 binds LZ4's block codec, which `just lz4` builds from vendor/lz4. The cooker compresses a mesh's pages
// with it, and the runtime decompresses them. See docs/content/blobs-and-loading.md#blob-format.
package lz4

import "core:c"

foreign import lib "../../../build/obj/lz4/out/cn_lz4.lib"

// The level that compress uses: LZ4HC's highest, as a page is compressed once and read many times.
LEVEL :: 12

// The largest block that LZ4 takes.
MAX_SIZE :: 0x7E000000

@(default_calling_convention = "c", link_prefix = "LZ4_")
foreign lib {
	compressBound :: proc(size: c.int) -> c.int ---
	compress_HC :: proc(src: [^]byte, dst: [^]byte, src_size: c.int, dst_capacity: c.int, level: c.int) -> c.int ---
	decompress_safe :: proc(src: [^]byte, dst: [^]byte, compressed_size: c.int, dst_capacity: c.int) -> c.int ---
}

// bound is the most bytes that data of this size compresses to, or 0 if the size is more than LZ4 takes.
bound :: proc(size: int) -> int {
	if size < 0 || size > MAX_SIZE {
		return 0
	}
	return int(compressBound(c.int(size)))
}

// compress writes data as one LZ4 block into out, which needs bound(len(data)) bytes to be sure to hold it, and returns
// the block. It returns nil if out is too small or data is empty.
compress :: proc(data: []byte, out: []byte) -> []byte {
	if len(data) == 0 || len(data) > MAX_SIZE || len(out) == 0 {
		return nil
	}
	size := compress_HC(raw_data(data), raw_data(out), c.int(len(data)), c.int(min(len(out), MAX_SIZE)), LEVEL)
	return size > 0 ? out[:size] : nil
}

// decompress writes a block's data into out, and returns true only if the block is whole and fills out exactly. It
// never writes outside out, whatever the block holds.
decompress :: proc(block: []byte, out: []byte) -> bool {
	if len(block) == 0 || len(block) > MAX_SIZE || len(out) == 0 || len(out) > MAX_SIZE {
		return false
	}
	size := decompress_safe(raw_data(block), raw_data(out), c.int(len(block)), c.int(len(out)))
	return int(size) == len(out)
}

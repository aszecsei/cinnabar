package cook

import "core:c"

// tools/cook/compressonator/cn_compress.cpp with Compressonator's CMP_Core, which `just compressonator` builds. Only
// the cooker links it.
foreign import compressonator "../../build/compressonator/out/cn_compressonator.lib"

// The justfile passes the vendor/compressonator tag, so a Compressonator update cooks every texture again.
COMPRESSONATOR_VERSION :: #config(COMPRESSONATOR_VERSION, "unknown")

// Compressed_Format matches CnFormat in cn_compress.cpp.
Compressed_Format :: enum c.int {
	BC1  = 1,
	BC4  = 4,
	BC5  = 5,
	BC6H = 6,
	BC7  = 7,
}

@(default_calling_convention = "c")
foreign compressonator {
	// cn_compressed_size is the size of a mip of the format: 4x4 blocks, and a block for a partial one.
	cn_compressed_size :: proc(format: Compressed_Format, width, height: c.uint) -> c.size_t ---
	// cn_compress compresses a mip into out, which holds cn_compressed_size bytes. pixels are RGBA8, or RGBA half
	// floats for BC6H. BC4 takes red, and BC5 red and green. quality is from 0 to 1, and srgb weighs BC1's error in
	// sRGB. It uses every core, and returns 0 or Compressonator's error code.
	cn_compress :: proc(format: Compressed_Format, quality: f32, srgb: bool, pixels: rawptr, width, height: c.uint, out: rawptr) -> c.int ---
	// cn_decompress decodes a mip into pixels of the layout that cn_compress takes, with alpha 1 for BC4, BC5 and BC6H.
	// The cooker's tests use it.
	cn_decompress :: proc(format: Compressed_Format, data: rawptr, width, height: c.uint, pixels: rawptr) -> c.int ---
}

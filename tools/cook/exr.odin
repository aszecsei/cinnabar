package cook

import "core:c"
import "core:strings"

// TinyEXR, from vendor/lightusd's src/external, which `just lightusd` builds into cn_usd.lib with cn_exr.cpp, its C
// interface (see usd/cn_exr.h). It inflates with the miniz in lightusd_static.lib.
foreign import exr {"../../build/obj/lightusd/out/cn_usd.lib", "../../build/obj/lightusd/out/lightusd_static.lib"}

@(default_calling_convention = "c")
foreign exr {
	cn_exr_decode :: proc(data: [^]u8, size: c.size_t, width, height: ^i32, error: ^cstring) -> [^]f32 ---
	cn_exr_free :: proc(pixels: [^]f32) ---
	cn_exr_free_error :: proc(error: cstring) ---
}

// EXR_MAGIC starts every OpenEXR file.
EXR_MAGIC :: [4]u8{0x76, 0x2f, 0x31, 0x01}

// decode_exr decodes an OpenEXR image's first part into linear RGBA, in temporary memory, or gives why it cannot.
decode_exr :: proc(data: []byte) -> (width, height: int, pixels: [][4]f32, err: string) {
	w, h: i32
	message: cstring
	rgba := cn_exr_decode(raw_data(data), c.size_t(len(data)), &w, &h, &message)
	if rgba == nil {
		err = strings.clone(string(message) if message != nil else "unknown error", context.temp_allocator)
		cn_exr_free_error(message)
		return
	}
	defer cn_exr_free(rgba)
	width, height = int(w), int(h)
	pixels = make([][4]f32, width * height, context.temp_allocator)
	for &p, i in pixels {
		p = {rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3]}
	}
	return
}

// The OpenEXR compressions that TinyEXR decodes: none, RLE, ZIPS, ZIP, PIZ, PXR24, B44 and B44A. DWAA (8) and DWAB (9)
// are lossy DCT codecs that it does not have.
EXR_COMPRESSION_NAMES := [?]string{"none", "RLE", "ZIPS", "ZIP", "PIZ", "PXR24", "B44", "B44A", "DWAA", "DWAB"}
EXR_LAST_DECODED_COMPRESSION :: 7

// exr_compression reads an OpenEXR header's compression: its attributes are each a name, a type name, a size and a
// value, until an empty name.
exr_compression :: proc(data: []byte) -> (compression: int, ok: bool) {
	if len(data) < 8 || ([4]u8{data[0], data[1], data[2], data[3]}) != EXR_MAGIC {
		return
	}
	at := 8
	text :: proc(data: []byte, at: ^int) -> (s: string, ok: bool) {
		start := at^
		for at^ < len(data) && data[at^] != 0 {
			at^ += 1
		}
		if at^ >= len(data) {
			return
		}
		at^ += 1
		return string(data[start:at^ - 1]), true
	}
	for {
		name := text(data, &at) or_return
		if name == "" {
			return
		}
		kind := text(data, &at) or_return
		if at + 4 > len(data) {
			return
		}
		size := int(data[at]) | int(data[at + 1]) << 8 | int(data[at + 2]) << 16 | int(data[at + 3]) << 24
		at += 4
		if size < 0 || at + size > len(data) {
			return
		}
		if name == "compression" && kind == "compression" && size == 1 {
			return int(data[at]), true
		}
		at += size
	}
}

// exr_undecodable gives why TinyEXR cannot decode an OpenEXR image, from the start of its file, or "" when it can.
exr_undecodable :: proc(head: []byte) -> string {
	compression, ok := exr_compression(head)
	switch {
	case !ok:
		return "its header cannot be read"
	case compression <= EXR_LAST_DECODED_COMPRESSION:
		return ""
	case compression < len(EXR_COMPRESSION_NAMES):
		return strings.concatenate({EXR_COMPRESSION_NAMES[compression], " compression"}, context.temp_allocator)
	}
	return "an unknown compression"
}

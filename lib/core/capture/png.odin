package capture

import "base:runtime"
import "core:c"

import stbi "vendor:stb/image"

// encode_png writes an RGB8 image as a PNG into memory from the allocator, with stb_image_write.
encode_png :: proc(img: Image, allocator: runtime.Allocator) -> (png: []byte, ok: bool) {
	if img.size.x == 0 ||
	   img.size.y == 0 ||
	   len(img.pixels) < int(img.size.x) * int(img.size.y) * 3 {
		return
	}
	out := make([dynamic]byte, allocator)
	written := stbi.write_png_to_func(
		append_bytes,
		&out,
		c.int(img.size.x),
		c.int(img.size.y),
		3,
		raw_data(img.pixels),
		c.int(img.size.x) * 3,
	)
	if written == 0 {
		delete(out)
		return
	}
	return out[:], true
}

// append_bytes is stb's write callback. The dynamic array keeps its own allocator, so the context's does not matter.
@(private = "file")
append_bytes :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
	context = runtime.default_context()
	out := (^[dynamic]byte)(ctx)
	append(out, ..([^]byte)(data)[:size])
}

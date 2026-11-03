package cook

import "core:c"
import "core:fmt"
import "core:strings"

import exr "vendor:OpenEXRCore"

// EXR_MAGIC starts every OpenEXR file.
EXR_MAGIC :: [4]u8{0x76, 0x2f, 0x31, 0x01}

// Exr_Reader is what a context's callbacks reach: the bytes of a file that is read from memory, and the library's last
// error message, which would otherwise go to stderr.
@(private = "file")
Exr_Reader :: struct {
	data:    []byte,
	message: [512]u8,
}

@(private = "file")
exr_keep_error :: proc "c" (ctx: exr.const_context_t, code: exr.result_t, message: cstring) {
	user: rawptr
	if exr.get_user_data(ctx, &user) != .SUCCESS || user == nil {
		return
	}
	reader := (^Exr_Reader)(user)
	n := copy(reader.message[:len(reader.message) - 1], transmute([]u8)string(message))
	reader.message[n] = 0
}

@(private = "file")
exr_read_memory :: proc "c" (ctx: exr.const_context_t, user: rawptr, buffer: rawptr, size, offset: u64, error: exr.stream_error_func_ptr_t) -> i64 {
	data := (^Exr_Reader)(user).data
	if offset >= u64(len(data)) {
		return 0
	}
	return i64(copy(([^]u8)(buffer)[:min(size, u64(len(data)) - offset)], data[offset:]))
}

@(private = "file")
exr_size_memory :: proc "c" (ctx: exr.const_context_t, user: rawptr) -> i64 {
	return i64(len((^Exr_Reader)(user).data))
}

// exr_initializer sets size, which the binding's default leaves at 0, because the library ignores flags without it. A
// damaged file is an error, not an image with holes.
@(private = "file")
exr_initializer :: proc(reader: ^Exr_Reader) -> exr.context_initializer_t {
	init := exr.DEFAULT_CONTEXT_INITIALIZER
	init.size = size_of(exr.context_initializer_t)
	init.error_handler_fn = exr_keep_error
	init.user_data = reader
	init.flags = exr.CONTEXT_FLAG_DISABLE_CHUNK_RECONSTRUCTION
	return init
}

@(private = "file")
exr_failure :: proc(reader: ^Exr_Reader, result: exr.result_t) -> string {
	message := string(cstring(&reader.message[0]))
	if message == "" {
		message = string(exr.get_default_error_message(result))
	}
	return strings.clone(message, context.temp_allocator)
}

// Exr_Layout is what the cooker reads of a file's first part.
@(private = "file")
Exr_Layout :: struct {
	window:   exr.attr_box2i_t,
	storage:  exr.storage_t,
	// The index in the part's channel list of each of R, G, B and A, or -1.
	channels: [4]int,
	gray:     bool,
}

// exr_layout finds the channels to read, or gives why the part cannot cook. One channel of any name is gray. Otherwise
// the part needs plain R, G and B, and takes A if it has it, and it ignores the rest, such as Z or another layer.
@(private = "file")
exr_layout :: proc(ctx: exr.const_context_t, reader: ^Exr_Reader) -> (layout: Exr_Layout, problem: string) {
	if result := exr.get_storage(ctx, 0, &layout.storage); result != .SUCCESS {
		return layout, exr_failure(reader, result)
	}
	if layout.storage == .DEEP_SCANLINE || layout.storage == .DEEP_TILED {
		return layout, "it holds deep data"
	}
	if result := exr.get_data_window(ctx, 0, &layout.window); result != .SUCCESS {
		return layout, exr_failure(reader, result)
	}
	list: ^exr.attr_chlist_t
	if result := exr.get_channels(ctx, 0, &list); result != .SUCCESS {
		return layout, exr_failure(reader, result)
	}
	entries := list.entries[:list.num_channels]

	layout.channels = {-1, -1, -1, -1}
	names := [4]string{"R", "G", "B", "A"}
	if len(entries) == 1 {
		layout.channels[0], layout.gray = 0, true
	} else {
		for entry, i in entries {
			for name, slot in names {
				if string(entry.name.str) == name {
					layout.channels[slot] = i
				}
			}
		}
		if layout.channels[0] < 0 || layout.channels[1] < 0 || layout.channels[2] < 0 {
			found := make([]string, len(entries), context.temp_allocator)
			for entry, i in entries {
				found[i] = string(entry.name.str)
			}
			return layout, fmt.tprintf("it has no R, G and B channels, only %s", strings.join(found, ", ", context.temp_allocator))
		}
	}
	for index in layout.channels {
		if index < 0 {
			continue
		}
		entry := entries[index]
		if entry.pixel_type == .UINT {
			return layout, fmt.tprintf("its %s channel holds unsigned integers, not half or float", string(entry.name.str))
		}
		if entry.x_sampling != 1 || entry.y_sampling != 1 {
			return layout, fmt.tprintf("its %s channel is subsampled", string(entry.name.str))
		}
	}
	return layout, ""
}

// Exr_Decoder decodes one part's chunks with one pipeline into interleaved pixels.
@(private = "file")
Exr_Decoder :: struct {
	ctx:      exr.const_context_t,
	layout:   Exr_Layout,
	width:    int,
	pixels:   [][4]f32,
	pipeline: exr.decode_pipeline_t,
	started:  bool,
}

// exr_decode_chunk decodes a chunk whose first pixel belongs at x, y of the image. The default routines pick their
// conversions from the first chunk's channels, and later chunks only move the pointers.
@(private = "file")
exr_decode_chunk :: proc(d: ^Exr_Decoder, chunk: ^exr.chunk_info_t, x, y: int) -> exr.result_t {
	result: exr.result_t
	if d.started {
		result = exr.decoding_update(d.ctx, 0, chunk, &d.pipeline)
	} else {
		result = exr.decoding_initialize(d.ctx, 0, chunk, &d.pipeline)
	}
	if result != .SUCCESS {
		return result
	}
	for index, slot in d.layout.channels {
		if index < 0 {
			continue
		}
		channel := &d.pipeline.channels[index]
		channel.user_bytes_per_element = size_of(f32)
		channel.user_data_type = u16(exr.pixel_type_t.FLOAT)
		channel.user_pixel_stride = size_of([4]f32)
		channel.user_line_stride = i32(d.width * size_of([4]f32))
		channel.decode_to_ptr = (^u8)(&d.pixels[y * d.width + x][slot])
	}
	if !d.started {
		if result = exr.decoding_choose_default_routines(d.ctx, 0, &d.pipeline); result != .SUCCESS {
			return result
		}
		d.started = true
	}
	return exr.decoding_run(d.ctx, 0, &d.pipeline)
}

// exr_decode_chunks decodes the part's largest level, which is all of a scanline part's. A tile's chunk gives its index
// among the tiles, and a scanline chunk its first line in the file's coordinates, which start at the window's corner.
@(private = "file")
exr_decode_chunks :: proc(d: ^Exr_Decoder) -> exr.result_t {
	chunk: exr.chunk_info_t
	if d.layout.storage == .TILED {
		tile_width, tile_height: u32
		if result := exr.get_tile_descriptor(d.ctx, 0, &tile_width, &tile_height, nil, nil); result != .SUCCESS {
			return result
		}
		columns, rows: i32
		if result := exr.get_tile_counts(d.ctx, 0, 0, 0, &columns, &rows); result != .SUCCESS {
			return result
		}
		for row in 0 ..< rows {
			for column in 0 ..< columns {
				if result := exr.read_tile_chunk_info(d.ctx, 0, column, row, 0, 0, &chunk); result != .SUCCESS {
					return result
				}
				if result := exr_decode_chunk(d, &chunk, int(column) * int(tile_width), int(row) * int(tile_height)); result != .SUCCESS {
					return result
				}
			}
		}
		return .SUCCESS
	}
	lines: i32
	if result := exr.get_scanlines_per_chunk(d.ctx, 0, &lines); result != .SUCCESS {
		return result
	}
	window := d.layout.window
	for y := window.min.y; y <= window.max.y; y += lines {
		if result := exr.read_scanline_chunk_info(d.ctx, 0, y, &chunk); result != .SUCCESS {
			return result
		}
		if result := exr_decode_chunk(d, &chunk, 0, int(chunk.start_y - window.min.y)); result != .SUCCESS {
			return result
		}
	}
	return .SUCCESS
}

// decode_exr decodes an OpenEXR image's first part into linear RGBA, in temporary memory, or gives why it cannot. The
// image is the part's data window. RGB is opaque, and one channel is gray and opaque.
decode_exr :: proc(data: []byte) -> (width, height: int, pixels: [][4]f32, err: string) {
	reader := Exr_Reader {
		data = data,
	}
	init := exr_initializer(&reader)
	init.read_fn = exr_read_memory
	init.size_fn = exr_size_memory
	ctx: exr.context_t
	if result := exr.start_read(&ctx, "image", &init); result != .SUCCESS {
		err = exr_failure(&reader, result)
		return
	}
	defer exr.finish(&ctx)

	layout, problem := exr_layout(ctx, &reader)
	if problem != "" {
		err = problem
		return
	}
	columns := int(layout.window.max.x) - int(layout.window.min.x) + 1
	rows := int(layout.window.max.y) - int(layout.window.min.y) + 1
	decoded, allocation := make([][4]f32, columns * rows, context.temp_allocator)
	if allocation != nil {
		err = fmt.tprintf("its %dx%d pixels do not fit in memory", columns, rows)
		return
	}
	for &p in decoded {
		p = {0, 0, 0, 1}
	}

	d := Exr_Decoder {
		ctx      = ctx,
		layout   = layout,
		width    = columns,
		pixels   = decoded,
		pipeline = exr.DECODE_PIPELINE_INITIALIZER,
	}
	defer exr.decoding_destroy(ctx, &d.pipeline)
	if result := exr_decode_chunks(&d); result != .SUCCESS {
		err = exr_failure(&reader, result)
		return
	}
	if layout.gray {
		for &p in decoded {
			p.g, p.b = p.r, p.r
		}
	}
	return columns, rows, decoded, ""
}

// exr_undecodable gives why the cooker cannot decode an OpenEXR file, or "" when it can, from its header alone.
exr_undecodable :: proc(path: string) -> string {
	reader: Exr_Reader
	init := exr_initializer(&reader)
	ctx: exr.context_t
	if result := exr.start_read(&ctx, strings.clone_to_cstring(path, context.temp_allocator), &init); result != .SUCCESS {
		return exr_failure(&reader, result)
	}
	defer exr.finish(&ctx)
	_, problem := exr_layout(ctx, &reader)
	return problem
}

// openexr_version is the linked library's version, which texture keys hold, so that an OpenEXRCore update cooks every
// texture again. It is asked of the library because the library comes with the Odin compiler, not from vendor/.
openexr_version :: proc() -> string {
	major, minor, patch: c.int
	extra: cstring
	exr.get_library_version(&major, &minor, &patch, &extra)
	return fmt.tprintf("%d.%d.%d%s", major, minor, patch, string(extra))
}

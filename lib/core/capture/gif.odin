package capture

import "base:runtime"

// A looping GIF89a of RGB8 frames with one global palette (see docs/editor/capture.md#history-ring). The palette is
// fixed, 6 levels of red, 7 of green and 6 of blue, 252 colors, and ordered dithering with a 4x4 Bayer matrix hides
// the steps, so no quantization pass runs over the frames. Each frame is a full image: no transparency and no
// disposal, so a viewer that drops frames still shows whole ones.

// The levels of each channel in the palette, and its size.
RED_LEVELS :: 6
GREEN_LEVELS :: 7
BLUE_LEVELS :: 6
PALETTE_SIZE :: RED_LEVELS * GREEN_LEVELS * BLUE_LEVELS

// The GIF's color table has 256 entries; the ones past the palette are black.
@(private = "file")
TABLE_SIZE :: 256

// GIF LZW codes are at most 12 bits, and an image's codes start at 8 bits for 256 colors.
@(private = "file")
MIN_CODE_SIZE :: 8
@(private = "file")
MAX_CODES :: 4096
@(private = "file")
CLEAR_CODE :: 256
@(private = "file")
END_CODE :: 257
@(private = "file")
FIRST_CODE :: 258

// The 4x4 Bayer matrix, as thresholds from 0 to 15.
@(private = "file")
BAYER := [4][4]u8{{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}}

// palette_color is the RGB of a palette index.
palette_color :: proc(index: u8) -> [3]u8 {
	if int(index) >= PALETTE_SIZE {
		return {}
	}
	r := int(index) / (GREEN_LEVELS * BLUE_LEVELS)
	g := int(index) / BLUE_LEVELS % GREEN_LEVELS
	b := int(index) % BLUE_LEVELS
	return {
		u8(r * 255 / (RED_LEVELS - 1)),
		u8(g * 255 / (GREEN_LEVELS - 1)),
		u8(b * 255 / (BLUE_LEVELS - 1)),
	}
}

// palette_index is the palette entry nearest a color after the Bayer threshold of the pixel's position moves it by
// up to a level, so flat regions dither into a pattern instead of banding.
palette_index :: proc(r, g, b: u8, x, y: u32) -> u8 {
	threshold := (f32(BAYER[y % 4][x % 4]) + 0.5) / 16 - 0.5
	ri := quantize(r, RED_LEVELS, threshold)
	gi := quantize(g, GREEN_LEVELS, threshold)
	bi := quantize(b, BLUE_LEVELS, threshold)
	return u8(ri * GREEN_LEVELS * BLUE_LEVELS + gi * BLUE_LEVELS + bi)
}

@(private = "file")
quantize :: proc(value: u8, levels: int, threshold: f32) -> int {
	scaled := f32(value) / 255 * f32(levels - 1) + threshold
	return clamp(int(scaled + 0.5), 0, levels - 1)
}

// encode_gif writes the frames, all of one size, as a looping GIF with delay_cs hundredths of a second between
// frames, into memory from the allocator.
encode_gif :: proc(
	frames: []Image,
	delay_cs: u16,
	allocator: runtime.Allocator,
) -> (
	gif: []byte,
	ok: bool,
) {
	if len(frames) == 0 || frames[0].size.x == 0 || frames[0].size.y == 0 {
		return
	}
	size := frames[0].size
	for f in frames {
		if f.size != size || len(f.pixels) < int(size.x) * int(size.y) * 3 {
			return
		}
	}
	if size.x > 0xffff || size.y > 0xffff {
		return
	}

	out := make([dynamic]byte, allocator)
	append(&out, "GIF89a")
	append_u16(&out, u16(size.x))
	append_u16(&out, u16(size.y))
	// A global color table of 256 entries, 8 bits of color, background 0, square pixels.
	append(&out, 0xf7, 0, 0)
	for i in 0 ..< TABLE_SIZE {
		color := palette_color(u8(i))
		append(&out, color.r, color.g, color.b)
	}
	// The NETSCAPE2.0 application extension loops forever.
	append(&out, 0x21, 0xff, 0x0b)
	append(&out, "NETSCAPE2.0")
	append(&out, 0x03, 0x01, 0x00, 0x00, 0x00)

	indices := make([]byte, int(size.x) * int(size.y), allocator)
	defer delete(indices, allocator)
	codes := make([dynamic]byte, allocator)
	defer delete(codes)
	encoder: Lzw_Encoder
	lzw_init(&encoder, allocator)
	defer lzw_destroy(&encoder)
	for f in frames {
		for y in 0 ..< size.y {
			for x in 0 ..< size.x {
				p := f.pixels[(int(y) * int(size.x) + int(x)) * 3:][:3]
				indices[int(y) * int(size.x) + int(x)] = palette_index(p[0], p[1], p[2], x, y)
			}
		}
		// The graphic control extension: no disposal, no transparency, the delay.
		append(&out, 0x21, 0xf9, 0x04, 0x00)
		append_u16(&out, delay_cs)
		append(&out, 0x00, 0x00)
		// The image descriptor: the whole screen, no local table, not interlaced.
		append(&out, 0x2c, 0, 0, 0, 0)
		append_u16(&out, u16(size.x))
		append_u16(&out, u16(size.y))
		append(&out, 0x00)
		append(&out, MIN_CODE_SIZE)
		clear(&codes)
		lzw_encode(&encoder, indices, &codes)
		write_blocks(codes[:], &out)
	}
	append(&out, 0x3b)
	return out[:], true
}

@(private = "file")
append_u16 :: proc(out: ^[dynamic]byte, v: u16) {
	append(out, u8(v), u8(v >> 8))
}

// write_blocks writes data as GIF sub-blocks of at most 255 bytes, then the empty block that ends them.
write_blocks :: proc(data: []byte, out: ^[dynamic]byte) {
	rest := data
	for len(rest) > 0 {
		n := min(len(rest), 255)
		append(out, u8(n))
		append(out, ..rest[:n])
		rest = rest[n:]
	}
	append(out, 0)
}

// Lzw_Encoder is the code table of GIF's LZW: each code's first child and next sibling, so a prefix's extensions are
// a list, and its value. The table is reused across frames, cleared each time.
Lzw_Encoder :: struct {
	first_child: []i16,
	sibling:     []i16,
	value:       []u8,
	allocator:   runtime.Allocator,
}

lzw_init :: proc(e: ^Lzw_Encoder, allocator: runtime.Allocator) {
	e.allocator = allocator
	e.first_child = make([]i16, MAX_CODES, allocator)
	e.sibling = make([]i16, MAX_CODES, allocator)
	e.value = make([]u8, MAX_CODES, allocator)
}

lzw_destroy :: proc(e: ^Lzw_Encoder) {
	delete(e.first_child, e.allocator)
	delete(e.sibling, e.allocator)
	delete(e.value, e.allocator)
	e^ = {}
}

@(private = "file")
Bit_Writer :: struct {
	out:   ^[dynamic]byte,
	bits:  u32,
	count: u32,
}

@(private = "file")
write_bits :: proc(w: ^Bit_Writer, code: u32, size: u32) {
	w.bits |= code << w.count
	w.count += size
	for w.count >= 8 {
		append(w.out, u8(w.bits))
		w.bits >>= 8
		w.count -= 8
	}
}

@(private = "file")
flush_bits :: proc(w: ^Bit_Writer) {
	if w.count > 0 {
		append(w.out, u8(w.bits))
	}
	w.bits, w.count = 0, 0
}

@(private = "file")
reset_table :: proc(e: ^Lzw_Encoder) {
	for i in 0 ..< MAX_CODES {
		e.first_child[i] = -1
		e.sibling[i] = -1
	}
}

// lzw_encode writes the GIF LZW codes of the indices, with the minimum code size MIN_CODE_SIZE: a clear code first,
// variable code sizes from 9 to 12 bits, a clear when the table is full, and the end code last.
lzw_encode :: proc(e: ^Lzw_Encoder, indices: []byte, out: ^[dynamic]byte) {
	w := Bit_Writer {
		out = out,
	}
	code_size := u32(MIN_CODE_SIZE + 1)
	next_code := i16(FIRST_CODE)
	reset_table(e)
	write_bits(&w, CLEAR_CODE, code_size)
	if len(indices) == 0 {
		write_bits(&w, END_CODE, code_size)
		flush_bits(&w)
		return
	}
	prefix := i16(indices[0])
	for value in indices[1:] {
		// Is prefix + value in the table?
		child := e.first_child[prefix]
		for child >= 0 && e.value[child] != value {
			child = e.sibling[child]
		}
		if child >= 0 {
			prefix = child
			continue
		}
		write_bits(&w, u32(prefix), code_size)
		if next_code < MAX_CODES {
			e.value[next_code] = value
			e.sibling[next_code] = e.first_child[prefix]
			e.first_child[prefix] = next_code
			// A code's size grows once the code that needs the next bit exists.
			if u32(next_code) == 1 << code_size {
				code_size += 1
			}
			next_code += 1
		}
		if next_code == MAX_CODES {
			write_bits(&w, CLEAR_CODE, code_size)
			reset_table(e)
			code_size = MIN_CODE_SIZE + 1
			next_code = FIRST_CODE
		}
		prefix = i16(value)
	}
	write_bits(&w, u32(prefix), code_size)
	write_bits(&w, END_CODE, code_size)
	flush_bits(&w)
}

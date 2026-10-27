package capture

import "core:math/rand"
import "core:testing"

@(test)
palette_colors_map_to_themselves :: proc(t: ^testing.T) {
	for i in 0 ..< PALETTE_SIZE {
		c := palette_color(u8(i))
		// At the matrix's middle threshold the color sits on its own level.
		testing.expect_value(t, palette_index(c.r, c.g, c.b, 1, 2), u8(i))
	}
	testing.expect_value(t, palette_color(0), [3]u8{0, 0, 0})
	testing.expect_value(t, palette_color(PALETTE_SIZE - 1), [3]u8{255, 255, 255})
	testing.expect_value(t, palette_color(255), [3]u8{})
}

@(test)
dithering_varies_a_grey_between_neighbours :: proc(t: ^testing.T) {
	// A grey between two levels of each channel lands on either, by position.
	seen: map[u8]bool
	defer delete(seen)
	for y in 0 ..< u32(4) {
		for x in 0 ..< u32(4) {
			seen[palette_index(128, 128, 128, x, y)] = true
		}
	}
	testing.expect(t, len(seen) >= 2)
	// Black and white never move.
	testing.expect_value(t, palette_index(0, 0, 0, 3, 3), u8(0))
	testing.expect_value(t, palette_index(255, 255, 255, 0, 0), u8(PALETTE_SIZE - 1))
}

@(test)
lzw_round_trips :: proc(t: ^testing.T) {
	e: Lzw_Encoder
	lzw_init(&e, context.allocator)
	defer lzw_destroy(&e)
	out := make([dynamic]byte)
	defer delete(out)

	// A run, random noise, and a stream long enough to fill the table and clear it.
	streams := [][]byte {
		{},
		{7},
		{1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		make([]byte, 1000),
		make([]byte, 70000),
	}
	defer delete(streams[3])
	defer delete(streams[4])
	state := rand.create(42)
	context.random_generator = rand.default_random_generator(&state)
	for &b in streams[3] {
		b = u8(rand.int_max(256))
	}
	for &b in streams[4] {
		b = u8(rand.int_max(256))
	}
	for stream in streams {
		clear(&out)
		lzw_encode(&e, stream, &out)
		decoded := lzw_decode(out[:], len(stream))
		defer delete(decoded)
		testing.expect(t, string(decoded) == string(stream))
	}
}

@(test)
gif_has_the_header_the_loop_and_a_frame_per_image :: proc(t: ^testing.T) {
	frames := [2]Image {
		{size = {4, 4}, pixels = make([]byte, 48)},
		{size = {4, 4}, pixels = make([]byte, 48)},
	}
	defer delete(frames[0].pixels)
	defer delete(frames[1].pixels)
	for i in 0 ..< 16 {
		frames[0].pixels[i * 3] = u8(i * 17)
		frames[1].pixels[i * 3 + 2] = 255
	}
	gif, ok := encode_gif(frames[:], 10, context.allocator)
	defer delete(gif)
	testing.expect(t, ok)
	testing.expect(t, string(gif[:6]) == "GIF89a")
	testing.expect_value(t, gif[6], u8(4))
	testing.expect_value(t, gif[8], u8(4))
	testing.expect_value(t, gif[10], u8(0xf7))
	table_end := 13 + 256 * 3
	testing.expect(t, string(gif[table_end + 3:][:11]) == "NETSCAPE2.0")
	// The first frame's graphic control extension and image descriptor follow the loop block.
	frame := table_end + 19
	testing.expect(t, string(gif[frame:][:4]) == "\x21\xf9\x04\x00")
	testing.expect_value(t, gif[frame + 4], u8(10))
	testing.expect_value(t, gif[frame + 8], u8(0x2c))
	testing.expect_value(t, gif[frame + 18], u8(8))
	descriptors := 0
	for i in 0 ..< len(gif) {
		if i + 3 < len(gif) && gif[i] == 0x21 && gif[i + 1] == 0xf9 && gif[i + 2] == 0x04 {
			descriptors += 1
		}
	}
	testing.expect_value(t, descriptors, 2)
	testing.expect_value(t, gif[len(gif) - 1], u8(0x3b))

	// The first frame's codes decode to its indices.
	blocks := make([dynamic]byte)
	defer delete(blocks)
	at := frame + 19
	for gif[at] != 0 {
		n := int(gif[at])
		append(&blocks, ..gif[at + 1:][:n])
		at += n + 1
	}
	decoded := lzw_decode(blocks[:], 16)
	defer delete(decoded)
	for y in 0 ..< u32(4) {
		for x in 0 ..< u32(4) {
			p := frames[0].pixels[(y * 4 + x) * 3:][:3]
			testing.expect_value(t, decoded[y * 4 + x], palette_index(p[0], p[1], p[2], x, y))
		}
	}

	// Frames of different sizes are refused.
	odd := [2]Image{frames[0], {size = {2, 2}, pixels = make([]byte, 12)}}
	defer delete(odd[1].pixels)
	_, bad := encode_gif(odd[:], 10, context.allocator)
	testing.expect(t, !bad)
	_, none := encode_gif(nil, 10, context.allocator)
	testing.expect(t, !none)
}

// lzw_decode is a plain GIF LZW decoder for the tests: it reads the codes with the growing code size, follows the
// clear and end codes, and returns the decoded bytes.
@(private = "file")
lzw_decode :: proc(data: []byte, expected: int) -> []byte {
	out := make([dynamic]byte, 0, expected)
	prefix := make([]i32, 4096)
	defer delete(prefix)
	suffix := make([]u8, 4096)
	defer delete(suffix)
	length := make([]int, 4096)
	defer delete(length)
	for i in 0 ..< 256 {
		prefix[i] = -1
		suffix[i] = u8(i)
		length[i] = 1
	}
	bits, count: u32
	at := 0
	code_size := u32(9)
	next := 258
	previous := -1
	read_code :: proc(data: []byte, at: ^int, bits, count: ^u32, size: u32) -> (int, bool) {
		for count^ < size {
			if at^ >= len(data) {
				return 0, false
			}
			bits^ |= u32(data[at^]) << count^
			count^ += 8
			at^ += 1
		}
		code := int(bits^ & (1 << size - 1))
		bits^ >>= size
		count^ -= size
		return code, true
	}
	write_code :: proc(
		out: ^[dynamic]byte,
		prefix: []i32,
		suffix: []u8,
		length: []int,
		code: int,
	) -> u8 {
		start := len(out)
		resize(out, start + length[code])
		c := code
		for i := length[code] - 1; i >= 0; i -= 1 {
			out[start + i] = suffix[c]
			c = int(prefix[c])
		}
		return out[start]
	}
	for {
		code, ok := read_code(data, &at, &bits, &count, code_size)
		if !ok || code == 257 {
			break
		}
		if code == 256 {
			code_size = 9
			next = 258
			previous = -1
			continue
		}
		if previous < 0 {
			write_code(&out, prefix, suffix, length, code)
			previous = code
			continue
		}
		first: u8
		if code < next {
			first = write_code(&out, prefix, suffix, length, code)
		} else {
			// The code being defined: the previous string plus its own first byte.
			first = write_code(&out, prefix, suffix, length, previous)
			append(&out, first)
		}
		if next < 4096 {
			prefix[next] = i32(previous)
			suffix[next] = first
			length[next] = length[previous] + 1
			next += 1
			if next == 1 << code_size && code_size < 12 {
				code_size += 1
			}
		}
		previous = code
	}
	return out[:]
}

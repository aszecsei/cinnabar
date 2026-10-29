package cook

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"

// A baseline TIFF reader for textures (see docs/content/kinds/textures.md): the first image of a file, in strips,
// uncompressed, PackBits, LZW or Deflate, with or without the horizontal predictor, of 8- or 16-bit unsigned or 32-bit
// float samples, gray or RGB, with or without alpha. Its pixels are the stored values from 0 to 1, or the floats as
// they are, which are linear.

TIFF_COMPRESSION_NONE :: 1
TIFF_COMPRESSION_LZW :: 5
TIFF_COMPRESSION_DEFLATE :: 8
TIFF_COMPRESSION_ADOBE_DEFLATE :: 32946
TIFF_COMPRESSION_PACKBITS :: 32773

// Tiff_Image is a decoded TIFF: RGBA, and whether its samples were floats.
Tiff_Image :: struct {
	width, height: int,
	pixels:        [][4]f32,
	linear:        bool,
}

@(private = "file")
Tiff_Reader :: struct {
	data: []byte,
	big:  bool,
}

@(private = "file")
tiff_u16 :: proc(r: Tiff_Reader, at: int) -> (v: u16, ok: bool) {
	if at < 0 || at + 2 > len(r.data) {
		return
	}
	return endian.get_u16(r.data[at:], r.big ? .Big : .Little)
}

@(private = "file")
tiff_u32 :: proc(r: Tiff_Reader, at: int) -> (v: u32, ok: bool) {
	if at < 0 || at + 4 > len(r.data) {
		return
	}
	return endian.get_u32(r.data[at:], r.big ? .Big : .Little)
}

// tiff_values reads an entry's values of type BYTE, SHORT or LONG, which are in the entry when they fit in 4 bytes.
@(private = "file")
tiff_values :: proc(r: Tiff_Reader, entry: int) -> (values: []u32, ok: bool) {
	kind := tiff_u16(r, entry + 2) or_return
	count := int(tiff_u32(r, entry + 4) or_return)
	size: int
	switch kind {
	case 1:
		size = 1
	case 3:
		size = 2
	case 4:
		size = 4
	case:
		return
	}
	if count < 0 || count > len(r.data) {
		return
	}
	at := entry + 8
	if count * size > 4 {
		at = int(tiff_u32(r, entry + 8) or_return)
	}
	values = make([]u32, count, context.temp_allocator)
	for &v, i in values {
		switch size {
		case 1:
			if at + i >= len(r.data) {
				return nil, false
			}
			v = u32(r.data[at + i])
		case 2:
			v = u32(tiff_u16(r, at + i * 2) or_return)
		case 4:
			v = tiff_u32(r, at + i * 4) or_return
		}
	}
	return values, true
}

// decode_tiff decodes a TIFF's first image, or gives why it cannot.
decode_tiff :: proc(data: []byte) -> (image: Tiff_Image, err: string) {
	r := Tiff_Reader{data = data}
	switch {
	case len(data) >= 8 && data[0] == 'I' && data[1] == 'I':
	case len(data) >= 8 && data[0] == 'M' && data[1] == 'M':
		r.big = true
	case:
		return {}, "is not a TIFF"
	}
	if magic, _ := tiff_u16(r, 2); magic != 42 {
		return {}, "is a BigTIFF or not a TIFF"
	}
	ifd, _ := tiff_u32(r, 4)
	entries, entries_ok := tiff_u16(r, int(ifd))
	if !entries_ok {
		return {}, "has no image directory"
	}
	tags := make(map[u16][]u32, context.temp_allocator)
	for i in 0 ..< int(entries) {
		entry := int(ifd) + 2 + i * 12
		tag, tag_ok := tiff_u16(r, entry)
		if !tag_ok {
			return {}, "has a cut-off image directory"
		}
		if values, ok := tiff_values(r, entry); ok {
			tags[tag] = values
		}
	}
	one :: proc(tags: map[u16][]u32, tag: u16, default: u32) -> u32 {
		values, found := tags[tag]
		return values[0] if found && len(values) > 0 else default
	}
	width, height := int(one(tags, 256, 0)), int(one(tags, 257, 0))
	samples := int(one(tags, 277, 1))
	compression := one(tags, 259, TIFF_COMPRESSION_NONE)
	photometric := one(tags, 262, 1)
	predictor := one(tags, 317, 1)
	sample_format := one(tags, 339, 1)
	rows_per_strip := int(one(tags, 278, u32(height)))
	bits := tags[258] or_else []u32{1}
	offsets, counts := tags[273], tags[279]
	switch {
	case width <= 0 || height <= 0 || width > 1 << 15 || height > 1 << 15:
		return {}, fmt.tprintf("has a size of %dx%d", width, height)
	case 322 in tags:
		return {}, "is tiled, which the cooker does not read"
	case one(tags, 284, 1) != 1:
		return {}, "has separate planes, which the cooker does not read"
	case photometric > 2:
		return {}, fmt.tprintf("has photometric interpretation %d, which the cooker does not read", photometric)
	case samples < 1 || (photometric == 2 && samples < 3):
		return {}, fmt.tprintf("has %d samples a pixel", samples)
	case len(offsets) == 0 || len(offsets) != len(counts):
		return {}, "has no strips"
	}
	depth := bits[0]
	for b in bits {
		if b != depth {
			return {}, "has samples of different sizes"
		}
	}
	switch {
	case (depth == 8 || depth == 16) && sample_format == 1:
	case depth == 32 && sample_format == 3:
	case:
		return {}, fmt.tprintf("has %d-bit samples of format %d, which the cooker does not read", depth, sample_format)
	}
	switch compression {
	case TIFF_COMPRESSION_NONE, TIFF_COMPRESSION_LZW, TIFF_COMPRESSION_DEFLATE, TIFF_COMPRESSION_ADOBE_DEFLATE, TIFF_COMPRESSION_PACKBITS:
	case:
		return {}, fmt.tprintf("has compression %d, which the cooker does not read", compression)
	}
	if predictor != 1 && (predictor != 2 || depth == 32) {
		return {}, fmt.tprintf("has predictor %d, which the cooker does not read", predictor)
	}
	if rows_per_strip <= 0 {
		rows_per_strip = height
	}

	sample_bytes := int(depth / 8)
	row_bytes := width * samples * sample_bytes
	image = {width = width, height = height, pixels = make([][4]f32, width * height, context.temp_allocator), linear = depth == 32}
	for offset, strip in offsets {
		first_row := strip * rows_per_strip
		if first_row >= height {
			break
		}
		rows := min(rows_per_strip, height - first_row)
		start, size := int(offset), int(counts[strip])
		if start < 0 || size < 0 || start + size > len(data) {
			return {}, "has a strip past its end"
		}
		want := rows * row_bytes
		raw, raw_ok := tiff_decompress(data[start:][:size], compression, want)
		if !raw_ok || len(raw) < want {
			return {}, "has a strip that does not decompress"
		}
		if predictor == 2 {
			tiff_undo_predictor(raw[:want], rows, width, samples, sample_bytes, r.big)
		}
		for y in 0 ..< rows {
			row := raw[y * row_bytes:][:row_bytes]
			for x in 0 ..< width {
				p := &image.pixels[(first_row + y) * width + x]
				v: [4]f32
				for s in 0 ..< min(samples, 4) {
					at := (x * samples + s) * sample_bytes
					switch depth {
					case 8:
						v[s] = f32(row[at]) / 255
					case 16:
						v[s] = f32(endian.get_u16(row[at:], r.big ? .Big : .Little) or_else 0) / 65535
					case 32:
						v[s] = transmute(f32)(endian.get_u32(row[at:], r.big ? .Big : .Little) or_else 0)
					}
				}
				if photometric == 0 {
					v[0] = 1 - v[0]
				}
				switch {
				case photometric == 2 && samples >= 4:
					p^ = v
				case photometric == 2:
					p^ = {v[0], v[1], v[2], 1}
				case samples >= 2:
					p^ = {v[0], v[0], v[0], v[1]}
				case:
					p^ = {v[0], v[0], v[0], 1}
				}
			}
		}
	}
	return image, ""
}

// tiff_decompress gives a strip's bytes, at least want of them when it can.
@(private = "file")
tiff_decompress :: proc(strip: []byte, compression: u32, want: int) -> (out: []byte, ok: bool) {
	switch compression {
	case TIFF_COMPRESSION_NONE:
		return strip, true
	case TIFF_COMPRESSION_PACKBITS:
		return tiff_packbits(strip, want)
	case TIFF_COMPRESSION_LZW:
		return tiff_lzw(strip, want)
	case TIFF_COMPRESSION_DEFLATE, TIFF_COMPRESSION_ADOBE_DEFLATE:
		buf: bytes.Buffer
		buf.buf.allocator = context.temp_allocator
		if zlib.inflate_from_byte_array(strip, &buf, expected_output_size = want) != nil {
			return
		}
		return bytes.buffer_to_bytes(&buf), true
	}
	return
}

// tiff_packbits decodes PackBits: a byte n then n + 1 bytes as they are for n from 0 to 127, or the next byte 1 - n
// times for n from -127 to -1.
@(private = "file")
tiff_packbits :: proc(strip: []byte, want: int) -> (out: []byte, ok: bool) {
	result := make([dynamic]byte, 0, want, context.temp_allocator)
	for i := 0; i < len(strip) && len(result) < want; {
		n := int(i8(strip[i]))
		i += 1
		switch {
		case n >= 0:
			if i + n + 1 > len(strip) {
				return
			}
			append(&result, ..strip[i:][:n + 1])
			i += n + 1
		case n != -128:
			if i >= len(strip) {
				return
			}
			for _ in 0 ..< 1 - n {
				append(&result, strip[i])
			}
			i += 1
		}
	}
	return result[:], true
}

// tiff_lzw decodes TIFF's LZW: codes from 9 to 12 bits, most significant bit first, 256 to clear the table and 257 to
// end, each width taken one code early. An entry after the first 258 is the previous code's bytes and the next byte,
// which are together in the output, so it is a run of the output.
@(private = "file")
tiff_lzw :: proc(strip: []byte, want: int) -> (out: []byte, ok: bool) {
	CLEAR :: 256
	END :: 257
	FIRST :: 258
	Entry :: struct {
		start, length: int,
	}
	result := make([dynamic]byte, 0, want, context.temp_allocator)
	table := make([dynamic]Entry, FIRST, 4096, context.temp_allocator)
	read :: proc(strip: []byte, bit: ^int, width: int) -> (code: int, ok: bool) {
		if bit^ + width > len(strip) * 8 {
			return
		}
		for _ in 0 ..< width {
			code = code << 1 | int(strip[bit^ / 8] >> (7 - uint(bit^ % 8)) & 1)
			bit^ += 1
		}
		return code, true
	}
	// put appends a code's bytes: a byte's own for a code below 256, else its run of the output.
	put :: proc(result: ^[dynamic]byte, table: []Entry, code: int) {
		if code < CLEAR {
			append(result, byte(code))
			return
		}
		e := table[code]
		for k in 0 ..< e.length {
			append(result, result[e.start + k])
		}
	}
	bit, width := 0, 9
	previous, previous_start := -1, 0
	for len(result) < want {
		code := read(strip, &bit, width) or_break
		switch {
		case code == END:
			return result[:], true
		case code == CLEAR:
			resize(&table, FIRST)
			width, previous = 9, -1
			continue
		}
		start := len(result)
		switch {
		case code < len(table) && (code < CLEAR || code >= FIRST):
			put(&result, table[:], code)
		case code == len(table) && previous >= 0:
			put(&result, table[:], previous)
			append(&result, result[start])
		case:
			return
		}
		if previous >= 0 && len(table) < 4096 {
			append(&table, Entry{previous_start, start - previous_start + 1})
		}
		previous, previous_start = code, start
		switch len(table) {
		case 511:
			width = 10
		case 1023:
			width = 11
		case 2047:
			width = 12
		}
	}
	return result[:], true
}

// tiff_undo_predictor adds each sample to the same sample of the pixel before it in its row.
@(private = "file")
tiff_undo_predictor :: proc(raw: []byte, rows, width, samples, sample_bytes: int, big: bool) {
	row_bytes := width * samples * sample_bytes
	for y in 0 ..< rows {
		row := raw[y * row_bytes:][:row_bytes]
		for x in 1 ..< width {
			for s in 0 ..< samples {
				at := (x * samples + s) * sample_bytes
				before := ((x - 1) * samples + s) * sample_bytes
				if sample_bytes == 1 {
					row[at] += row[before]
				} else {
					order: endian.Byte_Order = big ? .Big : .Little
					v := (endian.get_u16(row[at:], order) or_else 0) + (endian.get_u16(row[before:], order) or_else 0)
					endian.put_u16(row[at:], order, v)
				}
			}
		}
	}
}

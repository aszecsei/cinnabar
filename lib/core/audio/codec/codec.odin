// Package audio_codec decodes compressed sounds, a block at a time, for the mixer's stream thread and for the engine's
// load of a sound. It never allocates, and it never runs on the mix thread. See docs/audio/design.md#streaming.
package audio_codec

import "core:c"
import "core:encoding/endian"
import "core:mem"

import stb "vendor:stb/vorbis"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/adpcm"
import "cinnabar:core/audio/opus"

// The most frames that one decoded block holds. Vorbis's largest block gives 4096, which is the most of any format.
OUTPUT_FRAMES :: 4096
// How many frames a loop crosses over from the end of a pass into the start of the next, about 11 ms. The cooker codes the
// sound's own start again after its end, so these frames continue the end of the pass. Without this, a loop's two sides
// meet with a step the size of the coding noise, which a recording shows as a click.
SEAM_FRAMES :: 512
// The bytes of a sound held at once. An Ogg page and the Vorbis headers must fit whole, and a page is below 64 KB.
@(private)
INPUT_BYTES :: 1 << 17
// stb_vorbis takes all of its memory from this. It can only say how much it needs after it succeeds, so a test holds this
// to account against what the cooker's encoder writes.
@(private)
VORBIS_STATE_BYTES :: 1 << 19
// The alignment of a decoder's memory.
MEMORY_ALIGN :: 16
// The most frames that a seek decodes and throws away, 0.5 s: seek_table keeps its points this close, counting an Opus
// decoder's preroll.
SEEK_INTERVAL :: 24000

// Read reads bytes of the sound's data into buffer, and returns how many, or a negative number on failure.
Read :: #type proc(user: rawptr, offset: u64, buffer: rawptr, size: u64) -> i64

Status :: enum {
	// A block of frames.
	Frames,
	// The pass has given all of the sound's frames. decoder_restart starts the next one.
	End,
	Failed,
}

// Decoder is a voice's place in a compressed sound, in memory that its owner gives it.
Decoder :: struct {
	format:      audio.Sound_Format,
	channels:    int,
	frames:      u64,
	skip:        u64,
	size:        u64,
	state:       []byte,
	output:      [^]i16,
	input:       []byte,
	input_start: int,
	input_end:   int,
	// The offset in the data of input_end.
	next_read:   u64,
	left_skip:   u64,
	given:       u64,
	vorbis:      ^stb.vorbis,
	// What the data holds after the pass that ended, which the next pass crosses over from.
	seam:        [^]i16,
	seam_frames: int,
	// How far the next pass has crossed over, and how far it goes.
	crossed:     int,
	crossing:    int,
	// Every frame that the decoder has decoded, kept or not, for its tests.
	decoded:     u64,
}

@(private)
state_bytes :: proc(format: audio.Sound_Format, channels: int) -> int {
	#partial switch format {
	case .Vorbis:
		return VORBIS_STATE_BYTES
	case .Opus:
		return mem.align_forward_int(int(opus.decoder_get_size(c.int(channels))), MEMORY_ALIGN)
	}
	return 0
}

@(private)
input_bytes :: proc(format: audio.Sound_Format, channels: int) -> int {
	return adpcm.block_bytes(channels) if format == .ADPCM else INPUT_BYTES
}

// memory_bytes is the memory that a decoder of this format takes, aligned to MEMORY_ALIGN.
memory_bytes :: proc(format: audio.Sound_Format, channels: int) -> int {
	return(
		state_bytes(format, channels) +
		(OUTPUT_FRAMES + SEAM_FRAMES) * channels * size_of(i16) +
		input_bytes(format, channels) \
	)
}

// decoder_init sets a decoder up at the start of a sound, in memory of memory_bytes.
decoder_init :: proc(
	d: ^Decoder,
	format: audio.Sound_Format,
	channels: int,
	frames, skip, size: u64,
	memory: []byte,
) -> bool {
	state_size := state_bytes(format, channels)
	output_size := OUTPUT_FRAMES * channels * size_of(i16)
	seam_size := SEAM_FRAMES * channels * size_of(i16)
	d^ = {
		format   = format,
		channels = channels,
		frames   = frames,
		skip     = skip,
		size     = size,
		state    = memory[:state_size],
		output   = ([^]i16)(raw_data(memory[state_size:])),
		seam     = ([^]i16)(raw_data(memory[state_size + output_size:])),
		input    = memory[state_size + output_size + seam_size:][:input_bytes(format, channels)],
	}
	if format == .Opus &&
	   opus.decoder_init((^opus.Decoder)(raw_data(d.state)), audio.SAMPLE_RATE, c.int(channels)) !=
		   opus.OK {
		return false
	}
	decoder_restart(d)
	return true
}

// decoder_restart returns a decoder to the start of its sound, for the next pass of a loop. The Vorbis headers are read
// again, because stb_vorbis_flush_pushdata drops a frame and looks for a page, which is not a seamless return to the start.
decoder_restart :: proc(d: ^Decoder) {
	d.crossed = 0
	d.crossing = int(min(u64(d.seam_frames), d.frames))
	d.seam_frames = 0
	d.input_start = 0
	d.input_end = 0
	d.next_read = 0
	d.left_skip = d.skip
	d.given = 0
	d.vorbis = nil
	if d.format == .Opus {
		opus.decoder_ctl((^opus.Decoder)(raw_data(d.state)), opus.RESET_STATE)
	}
}

// decoder_next gives the next block of frames, interleaved, which last until the next call.
decoder_next :: proc(
	d: ^Decoder,
	read: Read,
	user: rawptr,
) -> (
	frames: [^]i16,
	count: int,
	status: Status,
) {
	for d.given < d.frames {
		decoded, ok := decode_block(d, read, user)
		if !ok {
			return nil, 0, .Failed
		}
		d.decoded += u64(decoded)
		skipped := int(min(u64(decoded), d.left_skip))
		d.left_skip -= u64(skipped)
		kept := int(min(u64(decoded - skipped), d.frames - d.given))
		if kept > 0 {
			d.given += u64(kept)
			block := d.output[skipped * d.channels:]
			seam_keep(d, block[kept * d.channels:], decoded - skipped - kept)
			cross_over(d, block, kept)
			return block, kept, .Frames
		}
	}
	// A failure here ends the seam early, and the next pass reports it if it lasts.
	for d.format != .ADPCM && d.seam_frames < SEAM_FRAMES {
		decoded, ok := decode_block(d, read, user)
		if !ok {
			break
		}
		d.decoded += u64(decoded)
		seam_keep(d, d.output, decoded)
	}
	return nil, 0, .End
}

// seek_preroll is how many frames a decoder of this format decodes after it starts at a seek point before its frames are
// the sound.
seek_preroll :: proc "contextless" (format: audio.Sound_Format) -> u64 {
	return audio.SEEK_PREROLL_OPUS if format == .Opus else 0
}

// seek_point_before is the last point of a table whose frames are the sound by target, a frame of the coded data.
@(private)
seek_point_before :: proc(
	format: audio.Sound_Format,
	table: []audio.Seek_Point,
	target: u64,
) -> (
	point: audio.Seek_Point,
	found: bool,
) {
	preroll := seek_preroll(format)
	low, high := 0, len(table)
	for low < high {
		middle := (low + high) / 2
		if table[middle].frame + preroll <= target {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low == 0 {
		return {}, false
	}
	return table[low - 1], true
}

// decoder_seek moves a decoder to a frame of its pass, below frames, so that decoder_next gives the pass from there. It
// starts at the last point of the table that is the sound by then, or at the start of the data without one, and the next
// decoder_next throws away what comes before the frame. ADPCM needs no table, as each block starts on an exact sample. A
// seek ends any crossing from the last pass. It returns false when the Vorbis headers do not read.
decoder_seek :: proc(
	d: ^Decoder,
	frame: u64,
	table: []audio.Seek_Point,
	read: Read,
	user: rawptr,
) -> bool {
	place := min(frame, d.frames)
	target := d.skip + place
	point, found := seek_point_before(d.format, table, target)
	if d.format == .ADPCM {
		block := target / adpcm.BLOCK_FRAMES
		point = {block * u64(adpcm.block_bytes(d.channels)), block * adpcm.BLOCK_FRAMES}
		found = block > 0
	}
	decoder_restart(d)
	d.crossing = 0
	d.given = place
	d.left_skip = target
	if !found {
		return true
	}
	if d.format == .Vorbis {
		// The headers are at the start of the data. stb_vorbis then looks for a page, which it reads past, and decodes from
		// the page after it: seek_table measured the frame that this gives.
		if !vorbis_open(d, read, user) {
			return false
		}
		stb.flush_pushdata(d.vorbis)
		d.input_start = 0
		d.input_end = 0
	}
	d.next_read = point.offset
	d.left_skip = target - point.frame
	return true
}

// seek_table finds the places in a Vorbis or Opus sound's data where a decoder can start afresh, and keeps the fewest of
// them that leave no seek more than SEEK_INTERVAL frames to decode and throw away. A Vorbis point is a page, which
// stb_vorbis reads past, and its frame is what this decoder measures there, so the table is the runtime's own. Points
// come no closer than the data's pages or packets, which the cooker ends at least every SEEK_INTERVAL / 2. It returns nil
// for the other formats, and fails on data that does not decode.
seek_table :: proc(
	format: audio.Sound_Format,
	channels: int,
	data: []byte,
	allocator := context.allocator,
) -> (
	table: []audio.Seek_Point,
	ok: bool,
) {
	candidates := make([dynamic]audio.Seek_Point, context.temp_allocator)
	#partial switch format {
	case .Opus:
		frame: u64
		for offset := 0; offset + 2 <= len(data); {
			size := int(data[offset]) | int(data[offset + 1]) << 8
			if size == 0 || offset + 2 + size > len(data) {
				return nil, false
			}
			frames := opus.packet_get_nb_samples(&data[offset + 2], i32(size), audio.SAMPLE_RATE)
			if frames <= 0 {
				return nil, false
			}
			if offset > 0 {
				append(&candidates, audio.Seek_Point{u64(offset), frame})
			}
			frame += u64(frames)
			offset += 2 + size
		}
	case .Vorbis:
		vorbis_pages(&candidates, channels, data) or_return
	case:
		return nil, true
	}
	return thin_seek_points(candidates[:], seek_preroll(format), allocator), true
}

// The bytes before an Ogg page's segment table.
@(private)
OGG_HEADER :: 27

// vorbis_pages measures each page of Vorbis data that a seek can start at: the frame that this decoder gives first when it
// starts there, which stb_vorbis reports through its place after those frames.
@(private)
vorbis_pages :: proc(candidates: ^[dynamic]audio.Seek_Point, channels: int, data: []byte) -> bool {
	memory, err := mem.make_aligned(
		[]byte,
		memory_bytes(.Vorbis, channels),
		MEMORY_ALIGN,
		context.temp_allocator,
	)
	if err != nil {
		return false
	}
	d: Decoder
	if !decoder_init(&d, .Vorbis, channels, 1, 0, u64(len(data)), memory) {
		return false
	}
	reader := Memory_Reader{data}
	if !vorbis_open(&d, read_memory, &reader) {
		return false
	}
	for offset := 0; offset + OGG_HEADER <= len(data); {
		segments := int(data[offset + 26])
		if string(data[offset:][:4]) != "OggS" || offset + OGG_HEADER + segments > len(data) {
			return false
		}
		size := OGG_HEADER + segments
		for s in 0 ..< segments {
			size += int(data[offset + OGG_HEADER + s])
		}
		granule := i64(endian.unchecked_get_u64le(data[offset + 6:]))
		// A page of headers has granule 0, and one that no packet ends on has -1.
		if granule > 0 {
			stb.flush_pushdata(d.vorbis)
			d.input_start = 0
			d.input_end = 0
			d.next_read = u64(offset)
			for _ in 0 ..< 8 {
				frames, decoded := decode_vorbis(&d, read_memory, &reader)
				if !decoded {
					break
				}
				if frames > 0 {
					place := int(stb.get_sample_offset(d.vorbis))
					if place >= frames {
						append(candidates, audio.Seek_Point{u64(offset), u64(place - frames)})
					}
					break
				}
			}
		}
		offset += size
	}
	return true
}

// thin_seek_points keeps, from the start, the farthest candidate that leaves no more than SEEK_INTERVAL frames to decode
// before any frame up to the next. Where two candidates are farther apart than that, it keeps both.
@(private)
thin_seek_points :: proc(
	candidates: []audio.Seek_Point,
	preroll: u64,
	allocator := context.allocator,
) -> []audio.Seek_Point {
	points := make([dynamic]audio.Seek_Point, allocator)
	last: u64
	i := 0
	for i < len(candidates) {
		limit := last + SEEK_INTERVAL - preroll
		best := -1
		for i < len(candidates) && candidates[i].frame <= limit {
			if candidates[i].frame > last {
				best = i
			}
			i += 1
		}
		if best < 0 {
			if i >= len(candidates) {
				break
			}
			best = i
			i += 1
		}
		append(&points, candidates[best])
		last = candidates[best].frame
	}
	return points[:]
}

// seam_keep keeps frames from past the end of the pass, for the next pass to cross over from. An ADPCM sound has none: its
// last block only pads, and it has no coded start after its end.
@(private)
seam_keep :: proc(d: ^Decoder, frames: [^]i16, count: int) {
	if d.format == .ADPCM {
		return
	}
	kept := min(count, SEAM_FRAMES - d.seam_frames)
	copy(d.seam[d.seam_frames * d.channels:][:kept * d.channels], frames[:kept * d.channels])
	d.seam_frames += kept
}

// cross_over fades the end of the last pass out as the start of this one fades in. Both are the same sound with different
// coding noise, so their levels add to the sound's.
@(private)
cross_over :: proc(d: ^Decoder, frames: [^]i16, count: int) {
	for i := 0; i < count && d.crossed < d.crossing; i, d.crossed = i + 1, d.crossed + 1 {
		fade_in := (f32(d.crossed) + 0.5) / f32(d.crossing)
		for c in 0 ..< d.channels {
			from := f32(d.seam[d.crossed * d.channels + c])
			to := f32(frames[i * d.channels + c])
			frames[i * d.channels + c] = i16(from + (to - from) * fade_in)
		}
	}
}

@(private)
decode_block :: proc(d: ^Decoder, read: Read, user: rawptr) -> (frames: int, ok: bool) {
	#partial switch d.format {
	case .ADPCM:
		return decode_adpcm(d, read, user)
	case .Vorbis:
		return decode_vorbis(d, read, user)
	case .Opus:
		return decode_opus(d, read, user)
	}
	return 0, false
}

// refill moves what is left of the input to its start and reads more after it. It returns how many bytes it read, and 0
// at the end of the data, which is a failure to a decoder that needs more.
@(private)
refill :: proc(d: ^Decoder, read: Read, user: rawptr) -> int {
	left := d.input_end - d.input_start
	if d.input_start > 0 {
		copy(d.input, d.input[d.input_start:d.input_end])
		d.input_start = 0
		d.input_end = left
	}
	room := u64(len(d.input) - left)
	wanted := min(room, d.size - d.next_read)
	if wanted == 0 {
		return 0
	}
	got := read(user, d.next_read, &d.input[left], wanted)
	if got <= 0 {
		return 0
	}
	d.input_end += int(got)
	d.next_read += u64(got)
	return int(got)
}

@(private)
decode_adpcm :: proc(d: ^Decoder, read: Read, user: rawptr) -> (frames: int, ok: bool) {
	block := adpcm.block_bytes(d.channels)
	for d.input_end - d.input_start < block {
		if refill(d, read, user) == 0 {
			return 0, false
		}
	}
	if !adpcm.decode_block(d.input[d.input_start:][:block], d.channels, d.output) {
		return 0, false
	}
	d.input_start += block
	return adpcm.BLOCK_FRAMES, true
}

@(private)
decode_opus :: proc(d: ^Decoder, read: Read, user: rawptr) -> (frames: int, ok: bool) {
	for {
		held := d.input_end - d.input_start
		if held >= 2 {
			size := int(d.input[d.input_start]) | int(d.input[d.input_start + 1]) << 8
			// No packet is empty, and libopus would take an empty one for a lost one and make up sound.
			if size == 0 {
				return 0, false
			}
			if held >= 2 + size {
				decoded := opus.decode(
					(^opus.Decoder)(raw_data(d.state)),
					&d.input[d.input_start + 2],
					i32(size),
					d.output,
					OUTPUT_FRAMES,
					0,
				)
				if decoded < 0 {
					return 0, false
				}
				d.input_start += 2 + size
				return int(decoded), true
			}
		}
		if refill(d, read, user) == 0 {
			return 0, false
		}
	}
}

@(private)
vorbis_open :: proc(d: ^Decoder, read: Read, user: rawptr) -> bool {
	if refill(d, read, user) == 0 {
		return false
	}
	for {
		allocation := stb.vorbis_alloc{raw_data(d.state), c.int(len(d.state))}
		consumed: c.int
		error: stb.Error
		d.vorbis = stb.open_pushdata(
			&d.input[d.input_start],
			c.int(d.input_end - d.input_start),
			&consumed,
			&error,
			&allocation,
		)
		if d.vorbis != nil {
			d.input_start += int(consumed)
			info := stb.get_info(d.vorbis)
			return info.sample_rate == audio.SAMPLE_RATE && int(info.channels) == d.channels
		}
		if error != .need_more_data || refill(d, read, user) == 0 {
			return false
		}
	}
}

@(private)
decode_vorbis :: proc(d: ^Decoder, read: Read, user: rawptr) -> (frames: int, ok: bool) {
	if d.vorbis == nil && !vorbis_open(d, read, user) {
		return 0, false
	}
	for {
		channels, samples: c.int
		output: [^]^f32
		held := d.input_end - d.input_start
		used := stb.decode_frame_pushdata(
			d.vorbis,
			raw_data(d.input[d.input_start:]),
			c.int(held),
			&channels,
			&output,
			&samples,
		)
		if used == 0 && samples == 0 {
			if refill(d, read, user) == 0 {
				return 0, false
			}
			continue
		}
		d.input_start += int(used)
		// Vorbis gives nothing for the first block of a stream.
		if samples == 0 {
			return 0, true
		}
		if int(channels) != d.channels || samples > OUTPUT_FRAMES {
			return 0, false
		}
		for channel in 0 ..< d.channels {
			from := ([^]f32)(output[channel])
			for i in 0 ..< int(samples) {
				d.output[i * d.channels + channel] = i16(clamp(from[i] * 32768, -32768, 32767))
			}
		}
		return int(samples), true
	}
}

// Memory_Reader is what read_memory reads from.
Memory_Reader :: struct {
	data: []byte,
}

// read_memory is a Read for a sound in memory.
read_memory :: proc(user: rawptr, offset: u64, buffer: rawptr, size: u64) -> i64 {
	r := (^Memory_Reader)(user)
	if offset >= u64(len(r.data)) {
		return 0
	}
	count := min(size, u64(len(r.data)) - offset)
	mem.copy_non_overlapping(buffer, &r.data[offset], int(count))
	return i64(count)
}

// decode_all decodes a whole sound in memory to out, which holds its frames. It gives what a later pass of a loop gives,
// crossed over from the end of the data, so a loop of out has no seam, and the first time through is no different to hear.
decode_all :: proc(
	format: audio.Sound_Format,
	data: []byte,
	channels: int,
	frames, skip: u64,
	out: []i16,
	allocator := context.allocator,
) -> bool {
	memory, err := mem.make_aligned(
		[]byte,
		memory_bytes(format, channels),
		MEMORY_ALIGN,
		allocator,
	)
	if err != nil {
		return false
	}
	defer delete(memory, allocator)
	decoder: Decoder
	if !decoder_init(&decoder, format, channels, frames, skip, u64(len(data)), memory) {
		return false
	}
	reader := Memory_Reader{data}
	written := 0
	for {
		block, count, status := decoder_next(&decoder, read_memory, &reader)
		switch status {
		case .Failed:
			return false
		case .End:
			decoder_restart(&decoder)
			cross_over(&decoder, raw_data(out), int(frames))
			return written == int(frames) * channels
		case .Frames:
			copy(out[written:], block[:count * channels])
			written += count * channels
		}
	}
}

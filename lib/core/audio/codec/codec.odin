// Package audio_codec decodes compressed sounds, a block at a time, for the mixer's stream thread and for the engine's
// load of a sound. It never allocates, and it never runs on the mix thread. See docs/audio/design.md#streaming.
package audio_codec

import "core:c"
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
	return state_bytes(format, channels) + (OUTPUT_FRAMES + SEAM_FRAMES) * channels * size_of(i16) + input_bytes(format, channels)
}

// decoder_init sets a decoder up at the start of a sound, in memory of memory_bytes.
decoder_init :: proc(d: ^Decoder, format: audio.Sound_Format, channels: int, frames, skip, size: u64, memory: []byte) -> bool {
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
	if format == .Opus && opus.decoder_init((^opus.Decoder)(raw_data(d.state)), audio.SAMPLE_RATE, c.int(channels)) != opus.OK {
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
decoder_next :: proc(d: ^Decoder, read: Read, user: rawptr) -> (frames: [^]i16, count: int, status: Status) {
	for d.given < d.frames {
		decoded, ok := decode_block(d, read, user)
		if !ok {
			return nil, 0, .Failed
		}
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
		seam_keep(d, d.output, decoded)
	}
	return nil, 0, .End
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
				decoded := opus.decode((^opus.Decoder)(raw_data(d.state)), &d.input[d.input_start + 2], i32(size), d.output, OUTPUT_FRAMES, 0)
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
		d.vorbis = stb.open_pushdata(&d.input[d.input_start], c.int(d.input_end - d.input_start), &consumed, &error, &allocation)
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
		used := stb.decode_frame_pushdata(d.vorbis, raw_data(d.input[d.input_start:]), c.int(held), &channels, &output, &samples)
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
decode_all :: proc(format: audio.Sound_Format, data: []byte, channels: int, frames, skip: u64, out: []i16, allocator := context.allocator) -> bool {
	memory, err := mem.make_aligned([]byte, memory_bytes(format, channels), MEMORY_ALIGN, allocator)
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

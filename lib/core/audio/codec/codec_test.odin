package audio_codec

import "core:c"
import "core:encoding/endian"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:testing"

import stb "vendor:stb/vorbis"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/adpcm"

// The cooker's encoders write these: `odin test tools/cook -define:WRITE_AUDIO_FIXTURES=true`. Each is the frames as a u64,
// the channels and the skip as u32s, then the coded data.
@(private = "file")
Coded :: struct {
	format: audio.Sound_Format,
	file:   []byte,
}

@(private = "file")
coded_files :: proc() -> []Coded {
	files := make([]Coded, 6, context.temp_allocator)
	files[0] = {.Vorbis, #load("testdata/tone_mono.vorbis")}
	files[1] = {.Vorbis, #load("testdata/tone_stereo.vorbis")}
	files[2] = {.Vorbis, #load("testdata/short_mono.vorbis")}
	files[3] = {.Opus, #load("testdata/tone_mono.opus")}
	files[4] = {.Opus, #load("testdata/tone_stereo.opus")}
	files[5] = {.Opus, #load("testdata/short_mono.opus")}
	return files
}

@(private = "file")
Header :: struct {
	frames:   u64,
	channels: int,
	skip:     u64,
	data:     []byte,
}

@(private = "file")
header_of :: proc(file: []byte) -> Header {
	frames, _ := endian.get_u64(file[0:], .Little)
	channels, _ := endian.get_u32(file[8:], .Little)
	skip, _ := endian.get_u32(file[12:], .Little)
	return {frames, int(channels), u64(skip), file[16:]}
}

// The fixtures' sound: a tone with a whole number of cycles in its frames, and another in the right channel.
@(private = "file")
tone :: proc(frames: u64, channels: int) -> []i16 {
	samples := make([]i16, int(frames) * channels, context.temp_allocator)
	for i in 0 ..< int(frames) {
		for c in 0 ..< channels {
			samples[i * channels + c] = i16(
				math.sin(f64(i) * f64(480 + c * 240) * math.TAU / 48000) * 12000,
			)
		}
	}
	return samples
}

@(private = "file")
signal_to_noise :: proc(source, decoded: []i16) -> f64 {
	signal, noise: f64
	for sample, i in source {
		signal += f64(sample) * f64(sample)
		difference := f64(sample) - f64(decoded[i])
		noise += difference * difference
	}
	return 10 * math.log10(signal / max(noise, 1))
}

// Each format gives the sound, in its place and its length, so a pass is not a frame out.
@(test)
a_pass_is_the_sound :: proc(t: ^testing.T) {
	for coded in coded_files() {
		h := header_of(coded.file)
		out := make([]i16, int(h.frames) * h.channels, context.temp_allocator)
		testing.expect(t, decode_all(coded.format, h.data, h.channels, h.frames, h.skip, out))
		testing.expect(t, signal_to_noise(tone(h.frames, h.channels), out) > 15)
	}
	source := tone(4000, 2)
	data := adpcm.encode(source, 2, context.temp_allocator)
	out := make([]i16, len(source), context.temp_allocator)
	testing.expect(t, decode_all(.ADPCM, data, 2, 4000, 0, out))
	testing.expect(t, signal_to_noise(source, out) > 15)
}

// One pass after another through a decoder, in small reads as a stream makes them.
@(private = "file")
two_passes :: proc(t: ^testing.T, coded: Coded) -> (first, second: []i16) {
	h := header_of(coded.file)
	memory, _ := mem.make_aligned(
		[]byte,
		memory_bytes(coded.format, h.channels),
		MEMORY_ALIGN,
		context.temp_allocator,
	)
	decoder: Decoder
	testing.expect(
		t,
		decoder_init(
			&decoder,
			coded.format,
			h.channels,
			h.frames,
			h.skip,
			u64(len(h.data)),
			memory,
		),
	)
	reader := Memory_Reader{h.data}
	passes: [2][]i16
	for pass in 0 ..< 2 {
		out := make([dynamic]i16, context.temp_allocator)
		loop: for {
			frames, count, status := decoder_next(&decoder, read_memory, &reader)
			switch status {
			case .Failed:
				testing.expect(t, false)
				break loop
			case .End:
				break loop
			case .Frames:
				testing.expect(t, count <= OUTPUT_FRAMES)
				append(&out, ..frames[:count * h.channels])
			}
		}
		testing.expect_value(t, len(out), int(h.frames) * h.channels)
		passes[pass] = out[:]
		decoder_restart(&decoder)
	}
	return passes[0], passes[1]
}

// A later pass is the first but for where it crosses over, and what decode_all gives is a later pass.
@(test)
a_restart_repeats_and_decode_all_matches :: proc(t: ^testing.T) {
	for coded in coded_files() {
		first, second := two_passes(t, coded)
		h := header_of(coded.file)
		same := len(first) == len(second)
		for sample, i in first {
			same &&= i < SEAM_FRAMES * h.channels || sample == second[i]
		}
		testing.expect(t, same)
		whole := make([]i16, len(first), context.temp_allocator)
		testing.expect(t, decode_all(coded.format, h.data, h.channels, h.frames, h.skip, whole))
		same = true
		for sample, i in whole {
			same &&= sample == second[i]
		}
		testing.expect(t, same)
	}
}

// The second difference of a sound is what a step shows up in: a step of s makes it s, whatever the sound does around it.
@(private = "file")
seam_step :: proc(frames: []i16, channels, channel: int) -> i32 {
	at :: proc(frames: []i16, channels, channel, frame: int) -> i32 {
		count := len(frames) / channels
		return i32(frames[((frame + count) % count) * channels + channel])
	}
	return abs(
		at(frames, channels, channel, 0) -
		2 * at(frames, channels, channel, -1) +
		at(frames, channels, channel, -2),
	)
}

// Where a later pass meets the next, the second difference of a slow chord is no more than it is elsewhere, so a loop has
// no step for a recording to show as a click. Two passes that meet with a hard cut do not pass this, as coding noise is
// larger than this sound's second difference: it is what the crossing is for.
@(test)
a_loop_has_no_step_at_its_seam :: proc(t: ^testing.T) {
	files := [?]Coded {
		{.Vorbis, #load("testdata/pad_mono.vorbis")},
		{.Opus, #load("testdata/pad_mono.opus")},
	}
	for coded in files {
		_, second := two_passes(t, coded)
		h := header_of(coded.file)
		for c in 0 ..< h.channels {
			largest: i32
			for frame in SEAM_FRAMES + 2 ..< int(h.frames) {
				previous := second[(frame - 1) * h.channels + c]
				before := second[(frame - 2) * h.channels + c]
				largest = max(
					largest,
					abs(i32(second[frame * h.channels + c]) - 2 * i32(previous) + i32(before)),
				)
			}
			testing.expectf(
				t,
				seam_step(second, h.channels, c) <= largest + largest / 2,
				"%v: a step of %d, and %d elsewhere",
				coded.format,
				seam_step(second, h.channels, c),
				largest,
			)
		}
	}
}

// The state that stb_vorbis takes for what the cooker writes fits, with room for a sound with a larger setup.
@(test)
the_vorbis_state_is_large_enough :: proc(t: ^testing.T) {
	for coded in coded_files() {
		if coded.format != .Vorbis {
			continue
		}
		h := header_of(coded.file)
		state := make([]byte, VORBIS_STATE_BYTES, context.temp_allocator)
		allocation := stb.vorbis_alloc{raw_data(state), c.int(len(state))}
		consumed: c.int
		error: stb.Error
		v := stb.open_pushdata(
			raw_data(h.data),
			c.int(len(h.data)),
			&consumed,
			&error,
			&allocation,
		)
		testing.expect(t, v != nil)
		if v == nil {
			continue
		}
		info := stb.get_info(v)
		used := int(
			info.setup_memory_required +
			info.setup_temp_memory_required +
			info.temp_memory_required,
		)
		testing.expectf(t, used * 2 <= VORBIS_STATE_BYTES, "stb_vorbis uses %d bytes", used)
	}
}

// Data that ends early or is not what it says fails, and never gives more than the sound's frames.
@(test)
bad_data_fails :: proc(t: ^testing.T) {
	for coded in coded_files() {
		h := header_of(coded.file)
		out := make([]i16, int(h.frames) * h.channels, context.temp_allocator)
		testing.expect(
			t,
			!decode_all(coded.format, h.data[:len(h.data) / 8], h.channels, h.frames, h.skip, out),
		)
		garbage := make([]byte, 4096, context.temp_allocator)
		for &b, i in garbage {
			b = u8(i * 37)
		}
		testing.expect(t, !decode_all(coded.format, garbage, h.channels, h.frames, h.skip, out))
	}
	out: [16]i16
	block: [adpcm.CHANNEL_BYTES]byte
	block[2] = 200
	testing.expect(t, !decode_all(.ADPCM, block[:], 1, 16, 0, out[:]))
	testing.expect(t, !decode_all(.ADPCM, block[:10], 1, 16, 0, out[:]))
}

// A decoder over a coded file, as a stream has one.
@(private = "file")
open_coded :: proc(
	t: ^testing.T,
	coded: Coded,
) -> (
	d: ^Decoder,
	reader: ^Memory_Reader,
	h: Header,
) {
	h = header_of(coded.file)
	memory, _ := mem.make_aligned(
		[]byte,
		memory_bytes(coded.format, h.channels),
		MEMORY_ALIGN,
		context.temp_allocator,
	)
	d = new(Decoder, context.temp_allocator)
	testing.expect(
		t,
		decoder_init(d, coded.format, h.channels, h.frames, h.skip, u64(len(h.data)), memory),
	)
	reader = new_clone(Memory_Reader{h.data}, context.temp_allocator)
	return
}

// The frames that a decoder gives from its place, up to count, and how many it decoded and threw away first.
@(private = "file")
frames_from :: proc(
	t: ^testing.T,
	d: ^Decoder,
	reader: ^Memory_Reader,
	count: int,
) -> (
	out: []i16,
	thrown: u64,
) {
	samples := make([dynamic]i16, context.temp_allocator)
	for len(samples) < count * d.channels {
		before := d.decoded
		frames, kept, status := decoder_next(d, read_memory, reader)
		if status != .Frames {
			testing.expect(t, status == .End)
			break
		}
		if len(samples) == 0 {
			thrown = d.decoded - before - u64(kept)
		}
		append(&samples, ..frames[:kept * d.channels])
	}
	return samples[:min(len(samples), count * d.channels)], thrown
}

// The largest difference between two runs of samples.
@(private = "file")
largest_difference :: proc(a, b: []i16) -> i32 {
	largest: i32
	for sample, i in a {
		largest = max(largest, abs(i32(sample) - i32(b[i])))
	}
	return largest
}

// A seek to any frame gives what a decode from the start gives there. Vorbis and ADPCM give the same samples, and Opus,
// which starts its decoder afresh before the place, differs by no more than its coding noise.
@(test)
a_seek_gives_what_a_decode_from_the_start_gives :: proc(t: ^testing.T) {
	adpcm_source := tone(20000, 2)
	adpcm_file := make([]byte, 16, context.temp_allocator)
	endian.put_u64(adpcm_file[0:], .Little, 20000)
	endian.put_u32(adpcm_file[8:], .Little, 2)
	files := make([dynamic]Coded, context.temp_allocator)
	append(&files, ..coded_files())
	append(&files, Coded{.Vorbis, #load("testdata/pad_mono.vorbis")})
	append(&files, Coded{.Opus, #load("testdata/pad_mono.opus")})
	{
		data := adpcm.encode(adpcm_source, 2, context.temp_allocator)
		file := make([]byte, 16 + len(data), context.temp_allocator)
		copy(file, adpcm_file)
		copy(file[16:], data)
		append(&files, Coded{.ADPCM, file})
	}
	for coded in files {
		first, _ := two_passes(t, coded)
		h := header_of(coded.file)
		table, ok := seek_table(coded.format, h.channels, h.data, context.temp_allocator)
		testing.expect(t, ok)
		d, reader, _ := open_coded(t, coded)
		places := [?]u64{0, 1, 777, h.frames / 3, h.frames / 2 + 5, h.frames - 300, h.frames - 1}
		for place in places {
			if place >= h.frames {
				continue
			}
			testing.expect(t, decoder_seek(d, place, table, read_memory, reader))
			count := min(1024, int(h.frames - place))
			out, _ := frames_from(t, d, reader, count)
			testing.expect_value(t, len(out), count * h.channels)
			expected := first[int(place) * h.channels:][:len(out)]
			largest := largest_difference(out, expected)
			bound: i32 = 32 if coded.format == .Opus else 0
			testing.expectf(
				t,
				largest <= bound,
				"%v with %d frames, at %d: a difference of %d",
				coded.format,
				h.frames,
				place,
				largest,
			)
		}
	}
}

// A seek table keeps each seek within one interval, and a pass after a seek goes on to its end.
@(test)
a_seek_decodes_at_most_one_interval :: proc(t: ^testing.T) {
	files := [?]Coded {
		{.Vorbis, #load("testdata/tone_stereo.vorbis")},
		{.Vorbis, #load("testdata/pad_mono.vorbis")},
		{.Opus, #load("testdata/tone_stereo.opus")},
	}
	for coded in files {
		h := header_of(coded.file)
		table, ok := seek_table(coded.format, h.channels, h.data, context.temp_allocator)
		testing.expect(t, ok)
		testing.expectf(t, len(table) >= 3, "%v has %d points", coded.format, len(table))
		d, reader, _ := open_coded(t, coded)
		generator := rand.create(529)
		largest: u64
		for _ in 0 ..< 100 {
			place := rand.uint64_range(0, h.frames, rand.default_random_generator(&generator))
			testing.expect(t, decoder_seek(d, place, table, read_memory, reader))
			out, thrown := frames_from(t, d, reader, 64)
			testing.expect(t, len(out) > 0)
			largest = max(largest, thrown)
		}
		testing.expectf(
			t,
			largest <= SEEK_INTERVAL,
			"%v: a seek threw away %d frames",
			coded.format,
			largest,
		)
		// Without a table, a seek decodes from the start.
		testing.expect(t, decoder_seek(d, h.frames - 10, nil, read_memory, reader))
		_, thrown := frames_from(t, d, reader, 10)
		testing.expect(t, thrown >= h.frames - 10)
	}
}

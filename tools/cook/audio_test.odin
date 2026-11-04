package cook

import cc "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

import ma "vendor:miniaudio"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/opus"
import format "cinnabar:engine/asset/format"

// A .wav file of 16-bit PCM, as its header says.
@(private = "file")
wav :: proc(samples: []i16, channels, rate: int) -> string {
	size := len(samples) * size_of(i16)
	data := make([]byte, 44 + size, context.temp_allocator)
	copy(data[0:], "RIFF")
	endian.put_u32(data[4:], .Little, u32(36 + size))
	copy(data[8:], "WAVEfmt ")
	endian.put_u32(data[16:], .Little, 16)
	endian.put_u16(data[20:], .Little, 1)
	endian.put_u16(data[22:], .Little, u16(channels))
	endian.put_u32(data[24:], .Little, u32(rate))
	endian.put_u32(data[28:], .Little, u32(rate * channels * size_of(i16)))
	endian.put_u16(data[32:], .Little, u16(channels * size_of(i16)))
	endian.put_u16(data[34:], .Little, 16)
	copy(data[36:], "data")
	endian.put_u32(data[40:], .Little, u32(size))
	for sample, i in samples {
		endian.put_i16(data[44 + i * size_of(i16):], .Little, sample)
	}
	return string(data)
}

@(private = "file")
tone :: proc(frames, rate: int) -> []i16 {
	samples := make([]i16, frames, context.temp_allocator)
	for &sample, i in samples {
		sample = i16(math.sin(f32(i) * 440 * math.TAU / f32(rate)) * 16384)
	}
	return samples
}

@(private = "file")
cooked :: proc(t: ^testing.T, tree: Tree, name: string) -> (data: []byte, blob: ^format.Audio_Blob) {
	data = tree_blob(t, tree, tree_guid(t, tree, name))
	ok: bool
	blob, ok = format.audio_view(data)
	testing.expect(t, ok)
	return
}

// set_settings rewrites a sound's .meta file with these import settings.
@(private = "file")
set_settings :: proc(t: ^testing.T, tree: Tree, name: string, settings: []format.Meta_Setting) {
	text := meta_with(tree_guid(t, tree, name), "", settings)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/%s.meta", tree.dir, name), text) == nil)
}

// A sound at the engine's rate keeps its exact samples, and a second cook finds it up to date.
@(test)
a_sound_cooks_to_its_samples :: proc(t: ^testing.T) {
	samples := [?]i16{100, -100, 2000, -2000, 32767, -32768}
	tree := make_tree(t, {{"content/audio/click.wav", wav(samples[:], 1, 48000)}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Audio}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Audio], 1)
	data, blob := cooked(t, tree, "audio/click.wav")
	if blob == nil {
		return
	}
	testing.expect_value(t, blob.frames, 6)
	testing.expect_value(t, blob.channels, 1)
	testing.expect(t, !bool(blob.stream))
	for sample, i in format.audio_samples(data, blob) {
		testing.expect_value(t, sample, samples[i])
	}
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/audio/click.wav")

	pass = cook(options, {.Audio}, log_problems = false)
	testing.expect_value(t, pass.current[.Audio], 1)
	testing.expect_value(t, pass.cooked[.Audio], 0)
}

// A sound at another rate takes the same time at the engine's.
@(test)
a_sound_converts_its_rate :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/audio/low.wav", wav(tone(24000, 24000), 1, 24000)}})
	defer remove_tree(tree)
	testing.expect(t, cook(tree_options(tree), {.Audio}, log_problems = false).ok)
	data, blob := cooked(t, tree, "audio/low.wav")
	if blob == nil {
		return
	}
	testing.expect(t, abs(i64(blob.frames) - 48000) < 16)
	// Still a 440 Hz tone: about 880 zero crossings in its one second.
	samples := format.audio_samples(data, blob)
	crossings := 0
	for i in 1 ..< len(samples) {
		if (samples[i] >= 0) != (samples[i - 1] >= 0) {
			crossings += 1
		}
	}
	testing.expect(t, abs(crossings - 880) < 8)
}

// A sound at another rate lands on the same sound at the engine's, in its place, and a loop of it continues into itself.
// A resampler left to start and end on the sound alone puts a step where it returns to the start.
@(test)
a_converted_sound_loops_without_a_step :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, rate: int, cycles_per_second: f64) {
		seconds := 3
		source := make([]i16, rate * seconds, context.temp_allocator)
		for &sample, i in source {
			sample = i16(math.sin(f64(i) * cycles_per_second * math.TAU / f64(rate)) * 12000)
		}
		tree := make_tree(t, {{"content/audio/low.wav", wav(source, 1, rate)}})
		defer remove_tree(tree)
		testing.expect(t, cook(tree_options(tree), {.Audio}, log_problems = false).ok)
		data, blob := cooked(t, tree, "audio/low.wav")
		if blob == nil {
			return
		}
		testing.expect_value(t, blob.frames, u64(48000 * seconds))
		samples := format.audio_samples(data, blob)
		ideal := make([]i16, len(samples), context.temp_allocator)
		for &sample, i in ideal {
			sample = i16(math.sin(f64(i) * cycles_per_second * math.TAU / 48000) * 12000)
		}
		// A frame out of place on this tone is about 25 dB.
		testing.expectf(t, signal_to_noise(ideal, samples) > 50, "%d Hz: %.1f dB", rate, signal_to_noise(ideal, samples))
		// The step from the last frame to the first is one of the sound's own.
		steepest: i32
		for i in 1 ..< len(samples) {
			steepest = max(steepest, abs(i32(samples[i]) - i32(samples[i - 1])))
		}
		step := abs(i32(samples[0]) - i32(samples[len(samples) - 1]))
		testing.expectf(t, step <= steepest + steepest / 4, "%d Hz: a step of %d, and %d elsewhere", rate, step, steepest)
	}
	check(t, 24000, 440)
	check(t, 44100, 440)
	check(t, 96000, 440)
	check(t, 11025, 300)
}

// Stereo stays stereo, and the channels setting changes it, and invalidates the old blob.
@(test)
the_channels_setting_chooses :: proc(t: ^testing.T) {
	samples := [?]i16{1000, 3000, 1000, 3000}
	tree := make_tree(t, {{"content/audio/both.wav", wav(samples[:], 2, 48000)}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
	_, blob := cooked(t, tree, "audio/both.wav")
	if blob != nil {
		testing.expect_value(t, blob.channels, 2)
		testing.expect_value(t, blob.frames, 2)
	}
	set_settings(t, tree, "audio/both.wav", {{"channels", "mono"}})
	pass := cook(options, {.Audio}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Audio], 1)
	data, mono := cooked(t, tree, "audio/both.wav")
	if mono != nil {
		testing.expect_value(t, mono.channels, 1)
		testing.expect_value(t, format.audio_samples(data, mono)[0], 2000)
	}
}

// A long sound streams by itself, a short one does not, and the setting says otherwise for either.
@(test)
the_stream_setting_and_the_length_choose :: proc(t: ^testing.T) {
	long := make([]i16, (AUDIO_STREAM_SECONDS + 1) * format.AUDIO_SAMPLE_RATE, context.temp_allocator)
	short := [?]i16{1, 2, 3, 4}
	tree := make_tree(t, {{"content/audio/long.wav", wav(long, 1, 48000)}, {"content/audio/short.wav", wav(short[:], 1, 48000)}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
	_, a := cooked(t, tree, "audio/long.wav")
	_, b := cooked(t, tree, "audio/short.wav")
	if a != nil && b != nil {
		testing.expect(t, bool(a.stream))
		testing.expect(t, !bool(b.stream))
	}
	set_settings(t, tree, "audio/short.wav", {{"stream", "true"}})
	testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
	_, c := cooked(t, tree, "audio/short.wav")
	if c != nil {
		testing.expect(t, bool(c.stream))
	}
}

// What is not a sound fails, keeps its old blob, and a bad setting is an error.
@(test)
a_bad_sound_fails :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/audio/broken.wav", "this is not a sound"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Audio}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Audio], 0)

	samples := [?]i16{1, 2}
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/audio/broken.wav", tree.dir), wav(samples[:], 1, 48000)) == nil)
	testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
	set_settings(t, tree, "audio/broken.wav", {{"stream", "maybe"}})
	testing.expect(t, !cook(options, {.Audio}, log_problems = false).ok)
}

// A slow chord, with a whole number of cycles of each part in its frames: smooth enough that coding noise is the largest
// thing in its second difference, as it is in a pad of music.
@(private = "file")
loop_pad :: proc(frames, channels: int) -> []i16 {
	PARTS := [?]f64{55, 82.5, 110, 137.5, 165, 220, 277.5, 330}
	samples := make([]i16, frames * channels, context.temp_allocator)
	for i in 0 ..< frames {
		for c in 0 ..< channels {
			sum: f64
			for part, n in PARTS {
				sum += math.sin(f64(i) * part * math.TAU / 48000 + f64(n * (c + 1))) * 1800
			}
			samples[i * channels + c] = i16(sum)
		}
	}
	return samples
}

// A loop's tone, with a whole number of cycles in its frames, and another in the right channel.
@(private = "file")
loop_tone :: proc(frames, channels: int) -> []i16 {
	samples := make([]i16, frames * channels, context.temp_allocator)
	for i in 0 ..< frames {
		for c in 0 ..< channels {
			samples[i * channels + c] = i16(math.sin(f64(i) * f64(480 + c * 240) * math.TAU / 48000) * 12000)
		}
	}
	return samples
}

// Decodes a blob's Vorbis data with miniaudio, as this package must not link stb_vorbis as well, and returns the frames
// that a pass keeps.
@(private = "file")
decode_vorbis_pass :: proc(t: ^testing.T, data: []byte, channels: int, frames, skip: u64) -> []i16 {
	config := ma.decoder_config_init(.s16, u32(channels), 48000)
	decoder: ma.decoder
	testing.expect_value(t, ma.decoder_init_memory(raw_data(data), len(data), &config, &decoder), ma.result.SUCCESS)
	defer ma.decoder_uninit(&decoder)
	all := make([]i16, (frames + skip + 2 * AUDIO_ROLL_FRAMES) * u64(channels), context.temp_allocator)
	read: u64
	ma.decoder_read_pcm_frames(&decoder, raw_data(all), u64(len(all) / channels), &read)
	testing.expect(t, read >= skip + frames)
	return all[skip * u64(channels):][:frames * u64(channels)]
}

// Decodes a blob's Opus packets, and returns the frames that a pass keeps.
@(private = "file")
decode_opus_pass :: proc(t: ^testing.T, data: []byte, channels: int, frames, skip: u64) -> []i16 {
	state := make([]byte, opus.decoder_get_size(cc.int(channels)), context.temp_allocator)
	decoder := (^opus.Decoder)(raw_data(state))
	testing.expect_value(t, opus.decoder_init(decoder, 48000, cc.int(channels)), opus.OK)
	all := make([dynamic]i16, context.temp_allocator)
	block: [AUDIO_OPUS_PACKET_FRAMES * 2]i16
	for at := 0; at < len(data); {
		size := int(data[at]) | int(data[at + 1]) << 8
		count := opus.decode(decoder, &data[at + 2], i32(size), &block[0], AUDIO_OPUS_PACKET_FRAMES, 0)
		testing.expect_value(t, count, AUDIO_OPUS_PACKET_FRAMES)
		append(&all, ..block[:AUDIO_OPUS_PACKET_FRAMES * channels])
		at += 2 + size
	}
	testing.expect(t, u64(len(all) / channels) >= skip + frames)
	return all[skip * u64(channels):][:frames * u64(channels)]
}

// The ratio of signal to error in decibels, which falls far if a pass is even a little out of place.
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

// A compressed format changes the blob and invalidates the old one, and a pass of its data is the sound, in its place, in
// its length. A format that does not exist is an error.
@(test)
the_format_setting_chooses :: proc(t: ^testing.T) {
	FRAMES :: 96000
	for channels in 1 ..= 2 {
		source := loop_tone(FRAMES, channels)
		tree := make_tree(t, {{"content/audio/tone.wav", wav(source, channels, 48000)}})
		defer remove_tree(tree)
		options := tree_options(tree)
		testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
		data, pcm := cooked(t, tree, "audio/tone.wav")
		if pcm == nil {
			return
		}
		testing.expect_value(t, pcm.format, audio.Sound_Format.PCM)
		testing.expect_value(t, pcm.skip, 0)
		pcm_size := len(format.audio_data(data, pcm))
		testing.expect_value(t, pcm_size, FRAMES * channels * size_of(i16))

		set_settings(t, tree, "audio/tone.wav", {{"format", "adpcm"}})
		pass := cook(options, {.Audio}, log_problems = false)
		testing.expect_value(t, pass.cooked[.Audio], 1)
		data_a, a := cooked(t, tree, "audio/tone.wav")
		if a != nil {
			testing.expect_value(t, a.format, audio.Sound_Format.ADPCM)
			testing.expect_value(t, a.skip, 0)
			testing.expect_value(t, a.frames, FRAMES)
			testing.expect(t, pcm_size / len(format.audio_data(data_a, a)) >= 3)
		}

		set_settings(t, tree, "audio/tone.wav", {{"format", "vorbis"}})
		testing.expect_value(t, cook(options, {.Audio}, log_problems = false).cooked[.Audio], 1)
		data_v, v := cooked(t, tree, "audio/tone.wav")
		if v != nil {
			testing.expect_value(t, v.format, audio.Sound_Format.Vorbis)
			testing.expect_value(t, v.frames, FRAMES)
			bytes := format.audio_data(data_v, v)
			testing.expect(t, pcm_size / len(bytes) >= 5)
			testing.expect(t, signal_to_noise(source, decode_vorbis_pass(t, bytes, channels, v.frames, u64(v.skip))) > 15)
		}

		set_settings(t, tree, "audio/tone.wav", {{"format", "opus"}})
		testing.expect_value(t, cook(options, {.Audio}, log_problems = false).cooked[.Audio], 1)
		data_o, o := cooked(t, tree, "audio/tone.wav")
		if o != nil {
			testing.expect_value(t, o.format, audio.Sound_Format.Opus)
			testing.expect_value(t, o.frames, FRAMES)
			bytes := format.audio_data(data_o, o)
			testing.expect(t, pcm_size / len(bytes) >= 5)
			testing.expect(t, signal_to_noise(source, decode_opus_pass(t, bytes, channels, o.frames, u64(o.skip))) > 15)
		}

		set_settings(t, tree, "audio/tone.wav", {{"format", "mp4"}})
		testing.expect(t, !cook(options, {.Audio}, log_problems = false).ok)
	}
}

// A sound far shorter than the roll wraps around itself, and still gives its frames.
@(test)
a_very_short_sound_compresses :: proc(t: ^testing.T) {
	source := loop_tone(1000, 1)
	tree := make_tree(t, {{"content/audio/tone.wav", wav(source, 1, 48000)}})
	defer remove_tree(tree)
	options := tree_options(tree)
	testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
	for name in ([]string{"adpcm", "vorbis", "opus"}) {
		set_settings(t, tree, "audio/tone.wav", {{"format", name}})
		testing.expect(t, cook(options, {.Audio}, log_problems = false).ok)
		_, blob := cooked(t, tree, "audio/tone.wav")
		if blob != nil {
			testing.expect_value(t, blob.frames, 1000)
		}
	}
}

// -define:WRITE_AUDIO_FIXTURES=true writes what lib/core/audio/codec and the mixer's tests decode, as neither can encode
// Vorbis. Each file is the frames as a u64, the channels and the skip as u32s, then the coded data.
WRITE_AUDIO_FIXTURES :: #config(WRITE_AUDIO_FIXTURES, false)

when WRITE_AUDIO_FIXTURES {
	@(test)
	write_audio_fixtures :: proc(t: ^testing.T) {
		Fixture :: struct {
			name:             string,
			samples:          []i16,
			frames, channels: int,
		}
		fixtures := []Fixture {
			{"tone_mono", loop_tone(96000, 1), 96000, 1},
			{"tone_stereo", loop_tone(96000, 2), 96000, 2},
			{"short_mono", loop_tone(1000, 1), 1000, 1},
			{"pad_mono", loop_pad(96000, 1), 96000, 1},
		}
		formats := []audio.Sound_Format{.Vorbis, .Opus}
		names := []string{"vorbis", "opus"}
		for fixture in fixtures {
			for sound_format, i in formats {
				coded, skip, ok := audio_encode(sound_format, fixture.samples, fixture.channels)
				testing.expect(t, ok)
				out := make([]byte, 16 + len(coded), context.temp_allocator)
				endian.put_u64(out[0:], .Little, u64(fixture.frames))
				endian.put_u32(out[8:], .Little, u32(fixture.channels))
				endian.put_u32(out[12:], .Little, skip)
				copy(out[16:], coded)
				path := fmt.tprintf("%s../../lib/core/audio/codec/testdata/%s.%s", #directory, fixture.name, names[i])
				testing.expect(t, os.write_entire_file(path, out) == nil)
			}
		}
	}
}

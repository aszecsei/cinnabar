package cook

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"

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

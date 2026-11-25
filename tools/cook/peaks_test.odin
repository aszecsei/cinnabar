package cook

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

// A stereo sound at 48 kHz: 256 frames of silence, 256 at 12000 on the left and -8000 on the right, then a ramp of 300
// frames up on the left and down on the right, whose last peak covers 44 frames.
@(private = "file")
PEAKS_WAV := #load("testdata/audio/peaks.wav", string)
// Its peak file, as tools/cook/testdata/audio says by hand: (0, 0), (-8000, 12000), (-12750, 25500) and (-14950, 29900).
@(private = "file")
PEAKS_GOLDEN := #load("testdata/audio/peaks.peaks", []byte)

@(private = "file")
peaks_of :: proc(t: ^testing.T, d: ^Daemon, tree: Tree, name: string) -> string {
	buffer: [32]u8
	guid := format.guid_format(tree_guid(t, tree, name), &buffer)
	return d.index.assets[guid].peaks
}

@(test)
a_sounds_peaks_are_each_runs_lowest_and_highest_sample :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/audio/peaks.wav", PEAKS_WAV}})
	defer remove_tree(tree)
	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	testing.expect(t, daemon_pass(&d, Changed_Everything{}).ok)

	path := peaks_of(t, &d, tree, "audio/peaks.wav")
	testing.expect(t, strings.has_prefix(path, fmt.tprintf("%s/peaks/", d.options.cache)))
	testing.expect(t, strings.has_suffix(path, ".peaks"))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), string(PEAKS_GOLDEN))

	testing.expect_value(t, string(data[:4]), "PEAK")
	version, _ := endian.get_u32(data[4:], .Little)
	frames_per_peak, _ := endian.get_u32(data[8:], .Little)
	frames, _ := endian.get_u64(data[12:], .Little)
	count, _ := endian.get_u32(data[20:], .Little)
	testing.expect_value(t, version, PEAKS_VERSION)
	testing.expect_value(t, frames_per_peak, PEAK_FRAMES)
	testing.expect_value(t, frames, 812)
	testing.expect_value(t, count, 4)
	want := [4][2]i16{{0, 0}, {-8000, 12000}, {-12750, 25500}, {-14950, 29900}}
	for pair, i in want {
		low, _ := endian.get_i16(data[PEAKS_HEADER_SIZE + i * 4:], .Little)
		high, _ := endian.get_i16(data[PEAKS_HEADER_SIZE + i * 4 + 2:], .Little)
		testing.expectf(t, low == pair[0] && high == pair[1], "peak %d is (%d, %d)", i, low, high)
	}
}

// A mono sound's peaks are its own samples', and one with no frames has a header and no peaks.
@(test)
peaks_make_takes_every_channel_and_a_short_last_run :: proc(t: ^testing.T) {
	samples := make([]i16, PEAK_FRAMES + 1, context.temp_allocator)
	samples[3], samples[PEAK_FRAMES] = -5, 7
	data := peaks_make(samples, 1, context.temp_allocator)
	testing.expect_value(t, len(data), PEAKS_HEADER_SIZE + 2 * 4)
	low, _ := endian.get_i16(data[PEAKS_HEADER_SIZE:], .Little)
	last, _ := endian.get_i16(data[PEAKS_HEADER_SIZE + 4:], .Little)
	testing.expect_value(t, low, -5)
	testing.expect_value(t, last, 7)
	testing.expect_value(t, len(peaks_make(nil, 2, context.temp_allocator)), PEAKS_HEADER_SIZE)
}

// A sound that cooks again has a new file, and the old one goes.
@(test)
a_recooked_sound_has_a_new_peak_file_and_the_old_one_goes :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/audio/peaks.wav", PEAKS_WAV}})
	defer remove_tree(tree)
	d := Daemon {
		options = tree_options(tree),
	}
	defer index_destroy(&d.index)
	testing.expect(t, daemon_pass(&d, Changed_Everything{}).ok)
	old := strings.clone(peaks_of(t, &d, tree, "audio/peaks.wav"), context.temp_allocator)

	// The same sound, louder by its ramp's end.
	changed := transmute([]byte)strings.clone(PEAKS_WAV, context.temp_allocator)
	endian.put_i16(changed[len(changed) - 4:], .Little, 32000)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/content/audio/peaks.wav", tree.dir), changed) == nil,
	)
	pass := daemon_pass(&d, Changed_Everything{})
	testing.expect_value(t, pass.cooked[.Audio], 1)

	path := peaks_of(t, &d, tree, "audio/peaks.wav")
	testing.expect(t, path != "" && path != old)
	testing.expect(t, os.exists(path))
	testing.expect(t, !os.exists(old))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	high, _ := endian.get_i16(data[len(data) - 2:], .Little)
	testing.expect_value(t, high, 32000)
}

// A daemon that starts again carries the sound and keeps its file. One whose file went makes it again, with no cook.
@(test)
a_carried_sound_keeps_its_peak_file_and_one_that_went_comes_back :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/audio/peaks.wav", PEAKS_WAV}})
	defer remove_tree(tree)
	options := tree_options(tree)
	first := Daemon {
		options = options,
	}
	defer index_destroy(&first.index)
	testing.expect(t, daemon_pass(&first, Changed_Everything{}).ok)
	path := strings.clone(peaks_of(t, &first, tree, "audio/peaks.wav"), context.temp_allocator)

	again := Daemon {
		options = options,
	}
	defer index_destroy(&again.index)
	testing.expect(t, index_load(&again.index, options))
	pass := daemon_pass(&again, Changed_Everything{})
	testing.expect_value(t, pass.cooked[.Audio], 0)
	testing.expect_value(t, peaks_of(t, &again, tree, "audio/peaks.wav"), path)

	testing.expect(t, os.remove(path) == nil)
	third := Daemon {
		options = options,
	}
	defer index_destroy(&third.index)
	testing.expect(t, index_load(&third.index, options))
	pass = daemon_pass(&third, Changed_Everything{})
	testing.expect_value(t, pass.cooked[.Audio], 0)
	testing.expect_value(t, peaks_of(t, &third, tree, "audio/peaks.wav"), path)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), string(PEAKS_GOLDEN))
}

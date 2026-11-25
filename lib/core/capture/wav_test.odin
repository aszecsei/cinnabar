package capture

import "core:encoding/endian"
import "core:testing"

// The header names 16-bit PCM at the rate, and its sizes count the frames that it is written again with.
@(test)
a_wav_header_counts_its_frames :: proc(t: ^testing.T) {
	h := wav_header(1000, 48000, 2)
	testing.expect_value(t, string(h[0:4]), "RIFF")
	testing.expect_value(t, string(h[8:16]), "WAVEfmt ")
	testing.expect_value(t, string(h[36:40]), "data")
	size, _ := endian.get_u32(h[4:], .Little)
	data, _ := endian.get_u32(h[40:], .Little)
	rate, _ := endian.get_u32(h[24:], .Little)
	bytes_a_second, _ := endian.get_u32(h[28:], .Little)
	testing.expect_value(t, data, 4000)
	testing.expect_value(t, size, 36 + 4000)
	testing.expect_value(t, rate, 48000)
	testing.expect_value(t, bytes_a_second, 192000)

	empty := wav_header(0, 48000, 2)
	size, _ = endian.get_u32(empty[4:], .Little)
	testing.expect_value(t, size, 36)
}

// Samples clip to [-1, 1] and round to the nearest step.
@(test)
pcm16_clips_and_rounds :: proc(t: ^testing.T) {
	out: [8]u8
	bytes := pcm16({1, -2, 0.5, 0}, out[:])
	testing.expect_value(t, len(bytes), 8)
	values: [4]i16
	for &v, i in values {
		v, _ = endian.get_i16(bytes[2 * i:], .Little)
	}
	testing.expect_value(t, values, [4]i16{32767, -32767, 16384, 0})
}

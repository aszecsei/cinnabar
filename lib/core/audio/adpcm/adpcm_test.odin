package audio_adpcm

import "core:math"
import "core:testing"

@(private = "file")
tone :: proc(frames, channels: int) -> []i16 {
	samples := make([]i16, frames * channels, context.temp_allocator)
	for i in 0 ..< frames {
		for c in 0 ..< channels {
			samples[i * channels + c] = i16(math.sin(f32(i) * (480 + f32(c) * 240) * math.TAU / 48000) * 16384)
		}
	}
	return samples
}

@(private = "file")
decode_all :: proc(t: ^testing.T, data: []byte, frames, channels: int) -> []i16 {
	out := make([]i16, (frames + BLOCK_FRAMES) * channels, context.temp_allocator)
	size := block_bytes(channels)
	for block in 0 ..< len(data) / size {
		testing.expect(t, decode_block(data[block * size:][:size], channels, &out[block * BLOCK_FRAMES * channels]))
	}
	return out[:frames * channels]
}

// The decoded sound stays close to the source, and each block starts exactly on it.
@(test)
a_round_trip_stays_close :: proc(t: ^testing.T) {
	for channels in 1 ..= 2 {
		FRAMES :: 4 * BLOCK_FRAMES + 100
		samples := tone(FRAMES, channels)
		data := encode(samples, channels, context.temp_allocator)
		testing.expect_value(t, u64(len(data)), data_bytes(FRAMES, channels))
		out := decode_all(t, data, FRAMES, channels)
		worst: i32
		// The step adapts in the first few frames, from the smallest.
		for i in 64 * channels ..< len(out) {
			worst = max(worst, abs(i32(out[i]) - i32(samples[i])))
		}
		testing.expect(t, worst < 256)
		for block in 0 ..< 4 {
			first := block * BLOCK_FRAMES * channels
			testing.expect_value(t, out[first], samples[first])
		}
	}
}

// Whole blocks hold about 4 frames of PCM to the byte, and a short sound takes one.
@(test)
sizes_are_whole_blocks :: proc(t: ^testing.T) {
	testing.expect_value(t, data_bytes(1, 1), CHANNEL_BYTES)
	testing.expect_value(t, data_bytes(BLOCK_FRAMES, 2), 2 * CHANNEL_BYTES)
	testing.expect_value(t, data_bytes(BLOCK_FRAMES + 1, 2), 4 * CHANNEL_BYTES)
	samples := [?]i16{100, -100, 2000}
	data := encode(samples[:], 1, context.temp_allocator)
	out := decode_all(t, data, 3, 1)
	testing.expect_value(t, out[0], 100)
}

// A wrong size or a step past the table is refused.
@(test)
a_bad_block_is_refused :: proc(t: ^testing.T) {
	out: [BLOCK_FRAMES]i16
	block: [CHANNEL_BYTES]byte
	testing.expect(t, !decode_block(block[:1], 1, &out[0]))
	block[2] = 200
	testing.expect(t, !decode_block(block[:], 1, &out[0]))
}

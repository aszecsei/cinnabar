package capture

import "core:encoding/endian"
import "core:math"

// WAV_HEADER_SIZE is the size of the header of a 16-bit PCM WAV file, before its samples.
WAV_HEADER_SIZE :: 44

// wav_header is the header of a 16-bit PCM WAV file of frames frames of channels channels at rate a second. A writer
// that does not know its length yet writes it with 0 frames, then writes it again over the start once it does.
wav_header :: proc(frames: u32, rate: u32, channels: u16) -> (header: [WAV_HEADER_SIZE]u8) {
	block := u32(channels) * 2
	data := frames * block
	copy(header[0:], "RIFF")
	endian.put_u32(header[4:], .Little, 36 + data)
	copy(header[8:], "WAVEfmt ")
	endian.put_u32(header[16:], .Little, 16)
	// PCM, then the channels, the rate, the bytes a second, the bytes a frame and the bits a sample.
	endian.put_u16(header[20:], .Little, 1)
	endian.put_u16(header[22:], .Little, channels)
	endian.put_u32(header[24:], .Little, rate)
	endian.put_u32(header[28:], .Little, rate * block)
	endian.put_u16(header[32:], .Little, u16(block))
	endian.put_u16(header[34:], .Little, 16)
	copy(header[36:], "data")
	endian.put_u32(header[40:], .Little, data)
	return
}

// pcm16 writes float samples, clipped to [-1, 1], as 16-bit little-endian samples into out, which holds two bytes for
// each, and gives the bytes written.
pcm16 :: proc(samples: []f32, out: []u8) -> []u8 {
	assert(len(out) >= 2 * len(samples))
	for v, i in samples {
		endian.put_i16(out[2 * i:], .Little, i16(math.round(clamp(v, -1, 1) * 32767)))
	}
	return out[:2 * len(samples)]
}

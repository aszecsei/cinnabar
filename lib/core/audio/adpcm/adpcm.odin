// Package audio_adpcm is IMA ADPCM in fixed-size blocks: 4 bits a sample, about 4 times smaller than PCM. A block starts
// each channel with its exact sample and step, so a place in the sound is one multiplication away, and the decoder needs
// no state between blocks. See docs/content/kinds/audio.md#audio.
package audio_adpcm

// A channel's bytes in a block: 4 of header, then a nibble for each frame after the first.
CHANNEL_BYTES :: 512
BLOCK_FRAMES :: 1 + (CHANNEL_BYTES - 4) * 2

@(private)
STEPS := [89]i32 {
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
	157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
	1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
	12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
}

@(private)
INDEX_CHANGE := [16]i32{-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8}

@(private)
Channel :: struct {
	predictor: i32,
	index:     i32,
}

block_bytes :: proc "contextless" (channels: int) -> int {
	return CHANNEL_BYTES * channels
}

// data_bytes is the size of a sound's blocks. The last block is whole, and the frames past the sound's end mean nothing.
data_bytes :: proc "contextless" (frames: u64, channels: int) -> u64 {
	return (frames + BLOCK_FRAMES - 1) / BLOCK_FRAMES * u64(block_bytes(channels))
}

@(private)
step_decode :: #force_inline proc "contextless" (c: ^Channel, code: u8) {
	step := STEPS[c.index]
	delta := step >> 3
	if code & 4 != 0 {
		delta += step
	}
	if code & 2 != 0 {
		delta += step >> 1
	}
	if code & 1 != 0 {
		delta += step >> 2
	}
	c.predictor = clamp(c.predictor - delta if code & 8 != 0 else c.predictor + delta, -32768, 32767)
	c.index = clamp(c.index + INDEX_CHANGE[code], 0, len(STEPS) - 1)
}

// decode_block decodes a block of block_bytes(channels) into BLOCK_FRAMES interleaved frames, and returns false if its
// header is not one that encode writes.
decode_block :: proc "contextless" (block: []byte, channels: int, out: [^]i16) -> bool {
	if len(block) != block_bytes(channels) {
		return false
	}
	state: [2]Channel
	for c in 0 ..< channels {
		header := block[c * 4:]
		state[c] = {i32(i16(u16(header[0]) | u16(header[1]) << 8)), i32(header[2])}
		if state[c].index >= len(STEPS) {
			return false
		}
		out[c] = i16(state[c].predictor)
	}
	data := block[channels * 4:]
	for nibble in 0 ..< len(data) * 2 {
		c := nibble % channels
		code := data[nibble / 2] >> 4 if nibble & 1 != 0 else data[nibble / 2] & 15
		step_decode(&state[c], code)
		out[channels + nibble] = i16(state[c].predictor)
	}
	return true
}

// encode writes interleaved samples as blocks, from allocator.
encode :: proc(samples: []i16, channels: int, allocator := context.allocator) -> []byte {
	frames := u64(len(samples) / channels)
	out := make([]byte, data_bytes(frames, channels), allocator)
	state: [2]Channel
	block_size := block_bytes(channels)
	for block_start, block_index := 0, 0; block_start < int(frames); block_start, block_index = block_start + BLOCK_FRAMES, block_index + 1 {
		block := out[block_index * block_size:][:block_size]
		for c in 0 ..< channels {
			first := samples[block_start * channels + c]
			state[c].predictor = i32(first)
			block[c * 4] = u8(u16(first) & 0xff)
			block[c * 4 + 1] = u8(u16(first) >> 8)
			block[c * 4 + 2] = u8(state[c].index)
		}
		data := block[channels * 4:]
		for nibble in 0 ..< len(data) * 2 {
			c := nibble % channels
			frame := block_start + 1 + nibble / channels
			// The frames past the end hold the last sample, which nothing plays.
			index := min(frame, int(frames) - 1) * channels + c
			code := encode_sample(&state[c], i32(samples[index]))
			data[nibble / 2] |= code << 4 if nibble & 1 != 0 else code
		}
	}
	return out
}

@(private)
encode_sample :: proc "contextless" (c: ^Channel, sample: i32) -> u8 {
	step := STEPS[c.index]
	difference := sample - c.predictor
	code: u8
	if difference < 0 {
		code = 8
		difference = -difference
	}
	if difference >= step {
		code |= 4
		difference -= step
	}
	if difference >= step >> 1 {
		code |= 2
		difference -= step >> 1
	}
	if difference >= step >> 2 {
		code |= 1
	}
	step_decode(c, code)
	return code
}

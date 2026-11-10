package lz4

import "core:testing"

@(test)
data_round_trips_and_gets_smaller :: proc(t: ^testing.T) {
	data := make([]byte, 64 << 10, context.temp_allocator)
	for &b, i in data {
		b = byte(i / 7 % 61)
	}
	out := make([]byte, bound(len(data)), context.temp_allocator)
	block := compress(data, out)
	testing.expect(t, len(block) > 0 && len(block) < len(data) / 2, "repeating data compresses to less than half")

	back := make([]byte, len(data), context.temp_allocator)
	testing.expect(t, decompress(block, back), "the block decompresses")
	for b, i in back {
		if b != data[i] {
			testing.expectf(t, false, "byte %d came back as %d, not %d", i, b, data[i])
			break
		}
	}
}

@(test)
a_block_that_is_wrong_is_refused :: proc(t: ^testing.T) {
	data := make([]byte, 4096, context.temp_allocator)
	for &b, i in data {
		b = byte(i * 31 % 251)
	}
	out := make([]byte, bound(len(data)), context.temp_allocator)
	block := compress(data, out)
	testing.expect(t, len(block) > 0)

	back := make([]byte, len(data), context.temp_allocator)
	testing.expect(t, !decompress(block[:len(block) / 2], back), "half a block is refused")
	testing.expect(t, !decompress(block, back[:len(back) - 1]), "a block for more bytes than out holds is refused")
	larger := make([]byte, len(data) + 1, context.temp_allocator)
	testing.expect(t, !decompress(block, larger), "a block for fewer bytes than out holds is refused")
	testing.expect(t, !decompress(nil, back), "no block is refused")
	testing.expect(t, compress(data, out[:8]) == nil, "an out that is too small holds no block")
}

package asset_format

import "core:mem"
import "core:testing"

// An R16 chain's mips are the means of the texels under them, rounded up, so a mip reads 0 only where every texel under
// it does; an odd edge repeats its last texel, and the chain goes down to 1 by 1.
@(test)
box_chains_of_r16_texels :: proc(t: ^testing.T) {
	texels := []u16{0, 0, 4, 8, 0, 0, 0, 65535, 2, 2, 2, 2}
	mips, count := texture_box_chain_r16({4, 3}, texels, context.temp_allocator)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, len(mips), 2 * (12 + 2 + 1))
	chain := ([^]u16)(raw_data(mips))[:15]
	testing.expect_value(t, chain[0], 0)
	testing.expect_value(t, chain[7], 65535)
	// Mip 1 is 2 by 1: four zeros, and 4, 8, 0 and 65535.
	testing.expect_value(t, chain[12], 0)
	testing.expect_value(t, chain[13], u16((4 + 8 + 65535 + 3) / 4))
	// Mip 2 is 1 by 1, the mean of mip 1's two texels with the edge repeated.
	testing.expect_value(t, chain[14], u16((2 * u32(chain[13]) + 3) / 4))

	written := texture_write(
		{format = .R16_Unorm, usage = .Mask, size = {4, 3}, mip_count = count, mips = mips},
		context.temp_allocator,
	)
	// A blob is read at its alignment.
	data, _ := mem.alloc_bytes(len(written), BLOB_ALIGN, context.temp_allocator)
	copy(data, written)
	view, ok := texture_view(data)
	testing.expect(t, ok, "the chain is the size that a blob of its mips takes")
	if ok {
		testing.expect_value(t, view.mip_count, 3)
	}
}

// An RGBA8 chain's mips are the means of each channel of the texels under them, rounded to the nearest.
@(test)
box_chains_of_rgba8_texels :: proc(t: ^testing.T) {
	texels := []u8{255, 0, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 0, 0, 255, 0}
	mips, count := texture_box_chain_rgba8({2, 2}, texels, context.temp_allocator)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, len(mips), 4 * (4 + 1))
	testing.expect_value(t, mips[16], u8((510 + 2) / 4))
	testing.expect_value(t, mips[17], u8((255 + 2) / 4))
	testing.expect_value(t, mips[18], u8((255 + 2) / 4))
	testing.expect_value(t, mips[19], 0)
}

// The mips of a texture from a mip are what a stream of a smaller texture takes: each layer's chain from that mip, one
// layer after the other.
@(test)
texture_mips_from_cuts_each_layers_chain :: proc(t: ^testing.T) {
	chain := texture_chain_size(.RGBA8_Unorm, {4, 4}, 3)
	testing.expect_value(t, chain, 4 * (16 + 4 + 1))
	mips := make([]byte, chain * 2, context.temp_allocator)
	for &b, i in mips {
		b = u8(i / chain + 1)
	}
	written := texture_write(
		{
			format = .RGBA8_Unorm,
			usage = .Color,
			dimension = .D2_Array,
			layer_count = 2,
			size = {4, 4},
			mip_count = 3,
			mips = mips,
		},
		context.temp_allocator,
	)
	data, _ := mem.alloc_bytes(len(written), BLOB_ALIGN, context.temp_allocator)
	copy(data, written)
	blob, ok := texture_view(data)
	testing.expect(t, ok)

	whole := texture_mips_from(data, blob, 0, context.temp_allocator)
	testing.expect_value(t, len(whole), chain * 2)
	from_one := texture_mips_from(data, blob, 1, context.temp_allocator)
	testing.expect_value(t, len(from_one), 2 * 4 * (4 + 1))
	testing.expect_value(t, from_one[0], 1)
	testing.expect_value(t, from_one[4 * 5], 2)
	testing.expect_value(t, len(texture_mips_from(data, blob, 3, context.temp_allocator)), 0)
}

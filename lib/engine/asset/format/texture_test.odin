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

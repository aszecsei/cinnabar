package render

import "core:testing"

// Bloom halves the scene while the shorter side is at least 4 pixels, up to 8 levels, and the smallest levels, under 16
// pixels on their shorter side, are upsampled with Catmull-Rom (see docs/rendering/post-processing.md#bloom).
@(test)
bloom_goes_down_while_the_shorter_side_is_four_pixels :: proc(t: ^testing.T) {
	levels, sizes := bloom_chain({1920, 1080})
	testing.expect_value(t, levels, 8)
	testing.expect_value(t, sizes[0], [2]u32{960, 540})
	testing.expect_value(t, sizes[5], [2]u32{30, 16})
	testing.expect_value(t, sizes[7], [2]u32{7, 4})
	testing.expect_value(t, bloom_up_mode(sizes[5]), BLOOM_UP)
	testing.expect_value(t, bloom_up_mode(sizes[6]), BLOOM_UP_BICUBIC)
	testing.expect_value(t, bloom_up_mode(sizes[7]), BLOOM_UP_BICUBIC)

	levels, sizes = bloom_chain({2560, 1440})
	testing.expect_value(t, levels, 8)
	testing.expect_value(t, sizes[7], [2]u32{10, 5})

	// A small view stops before the shorter side is under 4 pixels.
	levels, sizes = bloom_chain({64, 36})
	testing.expect_value(t, levels, 3)
	testing.expect_value(t, sizes[2], [2]u32{8, 4})

	// The first level is there at any size.
	levels, sizes = bloom_chain({1, 1})
	testing.expect_value(t, levels, 1)
	testing.expect_value(t, sizes[0], [2]u32{1, 1})
}

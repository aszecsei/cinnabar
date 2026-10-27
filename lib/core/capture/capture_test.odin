package capture

import "core:testing"

import "cinnabar:core/gpu"

@(test)
sdr_captures_drop_alpha_and_walk_the_row_pitch :: proc(t: ^testing.T) {
	// A 3x2 frame with rows of 256 bytes, as D3D12 aligns them.
	pixels := make([]byte, 512)
	defer delete(pixels)
	for y in 0 ..< 2 {
		for x in 0 ..< 3 {
			p := pixels[y * 256 + x * 4:][:4]
			p[0], p[1], p[2], p[3] = u8(10 * x + 1), u8(10 * x + 2), u8(10 * x + 3 + 100 * y), 255
		}
	}
	rgba, ok := to_rgb8(
		{size = {3, 2}, format = .RGBA8_Unorm_Srgb, row_pitch = 256, pixels = pixels},
		context.allocator,
	)
	defer delete(rgba.pixels)
	testing.expect(t, ok)
	testing.expect_value(t, rgba.size, [2]u32{3, 2})
	expected := []byte{1, 2, 3, 11, 12, 13, 21, 22, 23, 1, 2, 103, 11, 12, 113, 21, 22, 123}
	testing.expect(t, string(rgba.pixels) == string(expected))

	bgra, ok2 := to_rgb8(
		{size = {3, 2}, format = .BGRA8_Unorm_Srgb, row_pitch = 256, pixels = pixels},
		context.allocator,
	)
	defer delete(bgra.pixels)
	testing.expect(t, ok2)
	testing.expect_value(t, bgra.pixels[0], u8(3))
	testing.expect_value(t, bgra.pixels[2], u8(1))

	_, bad := to_rgb8(
		{size = {3, 2}, format = .RGBA8_Unorm_Srgb, row_pitch = 256, pixels = pixels[:100]},
		context.allocator,
	)
	testing.expect(t, !bad)
	_, unknown := to_rgb8(
		{size = {3, 2}, format = .R32_Uint, row_pitch = 256, pixels = pixels},
		context.allocator,
	)
	testing.expect(t, !unknown)
}

@(test)
hdr_captures_map_the_sdr_white_to_white :: proc(t: ^testing.T) {
	// HDR10: the PQ code of 80 nits is white at the default SDR white, half of it is mid grey, and 0 is black.
	code := u32(nits_to_pq(80) * 1023 + 0.5)
	half := u32(nits_to_pq(40) * 1023 + 0.5)
	pixels := make([]byte, 256)
	defer delete(pixels)
	(^u32le)(&pixels[0])^ = u32le(code | code << 10 | code << 20 | 3 << 30)
	(^u32le)(&pixels[4])^ = u32le(half | half << 10 | half << 20)
	hdr10, ok := to_rgb8(
		{size = {3, 1}, format = .RGB10A2_Unorm, mode = .Hdr10, row_pitch = 256, pixels = pixels},
		context.allocator,
	)
	defer delete(hdr10.pixels)
	testing.expect(t, ok)
	testing.expect(t, hdr10.pixels[0] >= 253 && hdr10.pixels[1] >= 253 && hdr10.pixels[2] >= 253)
	// Linear 0.5 is sRGB 188.
	testing.expect(t, abs(int(hdr10.pixels[3]) - 188) <= 2)
	testing.expect_value(t, hdr10.pixels[6], u8(0))

	// A brighter SDR white makes the same code darker.
	dim, _ := to_rgb8(
		{
			size = {3, 1},
			format = .RGB10A2_Unorm,
			mode = .Hdr10,
			sdr_white = 160,
			row_pitch = 256,
			pixels = pixels,
		},
		context.allocator,
	)
	defer delete(dim.pixels)
	testing.expect(t, abs(int(dim.pixels[0]) - 188) <= 2)

	// scRGB: 1.0 is white, 0.5 is mid grey, and values past white clamp.
	halves := make([]byte, 256)
	defer delete(halves)
	(^[4]f16le)(&halves[0])^ = {1, 1, 1, 1}
	(^[4]f16le)(&halves[8])^ = {0.5, 0.5, 0.5, 1}
	(^[4]f16le)(&halves[16])^ = {4, 4, 4, 1}
	scrgb, ok2 := to_rgb8(
		{size = {3, 1}, format = .RGBA16_Float, mode = .Scrgb, row_pitch = 256, pixels = halves},
		context.allocator,
	)
	defer delete(scrgb.pixels)
	testing.expect(t, ok2)
	testing.expect_value(t, scrgb.pixels[0], u8(255))
	testing.expect(t, abs(int(scrgb.pixels[3]) - 188) <= 1)
	testing.expect_value(t, scrgb.pixels[6], u8(255))
}

@(test)
downscale_averages_two_by_two_and_repeats_the_odd_edge :: proc(t: ^testing.T) {
	// A 4x4 checker of black and white averages to grey.
	checker := Image {
		size   = {4, 4},
		pixels = make([]byte, 48),
	}
	defer delete(checker.pixels)
	for y in 0 ..< 4 {
		for x in 0 ..< 4 {
			v := u8(255) if (x + y) % 2 == 0 else 0
			checker.pixels[(y * 4 + x) * 3] = v
			checker.pixels[(y * 4 + x) * 3 + 1] = v
			checker.pixels[(y * 4 + x) * 3 + 2] = v
		}
	}
	half := downscale_half(checker, context.allocator)
	defer delete(half.pixels)
	testing.expect_value(t, half.size, [2]u32{2, 2})
	for p in half.pixels {
		testing.expect(t, p == 127 || p == 128)
	}

	// A 3x3 image gives 2x2, and the edge pixel is its own average.
	three := Image {
		size   = {3, 3},
		pixels = make([]byte, 27),
	}
	defer delete(three.pixels)
	for &p in three.pixels {
		p = 10
	}
	three.pixels[(2 * 3 + 2) * 3] = 50
	small := downscale_half(three, context.allocator)
	defer delete(small.pixels)
	testing.expect_value(t, small.size, [2]u32{2, 2})
	testing.expect_value(t, small.pixels[0], u8(10))
	testing.expect_value(t, small.pixels[(1 * 2 + 1) * 3], u8(50))
}

@(test)
png_has_the_signature_and_the_size :: proc(t: ^testing.T) {
	img := Image {
		size   = {5, 3},
		pixels = make([]byte, 45),
	}
	defer delete(img.pixels)
	png, ok := encode_png(img, context.allocator)
	defer delete(png)
	testing.expect(t, ok)
	testing.expect(t, len(png) > 33)
	testing.expect(t, string(png[:8]) == "\x89PNG\r\n\x1a\n")
	testing.expect(t, string(png[12:16]) == "IHDR")
	testing.expect_value(
		t,
		u32(png[16]) << 24 | u32(png[17]) << 16 | u32(png[18]) << 8 | u32(png[19]),
		u32(5),
	)
	testing.expect_value(
		t,
		u32(png[20]) << 24 | u32(png[21]) << 16 | u32(png[22]) << 8 | u32(png[23]),
		u32(3),
	)
	// 8 bits per channel, color type 2 (RGB).
	testing.expect_value(t, png[24], u8(8))
	testing.expect_value(t, png[25], u8(2))

	_, bad := encode_png({size = {5, 3}, pixels = img.pixels[:10]}, context.allocator)
	testing.expect(t, !bad)
}

@(test)
frame_capture_type_is_shared_with_the_backends :: proc(t: ^testing.T) {
	// The capture's pixels are the backend's; nothing here frees them.
	c: gpu.Frame_Capture
	testing.expect_value(t, len(c.pixels), 0)
}

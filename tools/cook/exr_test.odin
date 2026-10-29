package cook

import "core:testing"

// A 3x2 OpenEXR image of float channels, uncompressed, written from the format's description: each pixel's R is
// x + 0.25 * y, its G 2 + x, its B 10 * y, and its A 0.5.
@(private = "file")
EXR_TINY := [?]u8 {
	118, 47, 49, 1, 2, 0, 0, 0, 99, 104, 97, 110, 110, 101, 108, 115, 0, 99, 104, 108, 105, 115, 116, 0,
	73, 0, 0, 0, 65, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 66, 0,
	2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 71, 0, 2, 0, 0, 0, 0, 0,
	0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 82, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0,
	1, 0, 0, 0, 0, 99, 111, 109, 112, 114, 101, 115, 115, 105, 111, 110, 0, 99, 111, 109, 112, 114, 101, 115,
	115, 105, 111, 110, 0, 1, 0, 0, 0, 0, 100, 97, 116, 97, 87, 105, 110, 100, 111, 119, 0, 98, 111, 120,
	50, 105, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 100,
	105, 115, 112, 108, 97, 121, 87, 105, 110, 100, 111, 119, 0, 98, 111, 120, 50, 105, 0, 16, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 108, 105, 110, 101, 79, 114, 100, 101, 114,
	0, 108, 105, 110, 101, 79, 114, 100, 101, 114, 0, 1, 0, 0, 0, 0, 112, 105, 120, 101, 108, 65, 115, 112,
	101, 99, 116, 82, 97, 116, 105, 111, 0, 102, 108, 111, 97, 116, 0, 4, 0, 0, 0, 0, 0, 128, 63, 115,
	99, 114, 101, 101, 110, 87, 105, 110, 100, 111, 119, 67, 101, 110, 116, 101, 114, 0, 118, 50, 102, 0, 8, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 115, 99, 114, 101, 101, 110, 87, 105, 110, 100, 111, 119, 87, 105,
	100, 116, 104, 0, 102, 108, 111, 97, 116, 0, 4, 0, 0, 0, 0, 0, 128, 63, 0, 91, 1, 0, 0, 0,
	0, 0, 0, 147, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 48, 0, 0, 0, 0, 0, 0, 63, 0,
	0, 0, 63, 0, 0, 0, 63, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0,
	0, 64, 64, 0, 0, 128, 64, 0, 0, 0, 0, 0, 0, 128, 63, 0, 0, 0, 64, 1, 0, 0, 0, 48,
	0, 0, 0, 0, 0, 0, 63, 0, 0, 0, 63, 0, 0, 0, 63, 0, 0, 32, 65, 0, 0, 32, 65, 0,
	0, 32, 65, 0, 0, 0, 64, 0, 0, 64, 64, 0, 0, 128, 64, 0, 0, 128, 62, 0, 0, 160, 63, 0,
	0, 16, 64,
}

@(test)
exr_images_decode_to_linear_rgba :: proc(t: ^testing.T) {
	width, height, pixels, err := decode_exr(EXR_TINY[:])
	testing.expect_value(t, err, "")
	testing.expect_value(t, width, 3)
	testing.expect_value(t, height, 2)
	if err == "" {
		for y in 0 ..< 2 {
			for x in 0 ..< 3 {
				testing.expect_value(t, pixels[y * 3 + x], [4]f32{f32(x) + 0.25 * f32(y), 2 + f32(x), 10 * f32(y), 0.5})
			}
		}
	}
	_, _, _, broken := decode_exr(EXR_TINY[:40])
	testing.expect(t, broken != "")
}

// A texture's decoding picks its decoder by the file's first bytes, and an EXR's values are linear already, so a
// color texture keeps them where an 8-bit image's are decoded from sRGB.
@(test)
exr_color_textures_skip_srgb :: proc(t: ^testing.T) {
	problems: Problems
	image, ok := decode_image_bytes(EXR_TINY[:], "tiny.exr", {usage = .Color}, &problems)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, image.pixels[1], [4]f32{1, 3, 0, 0.5})
	}
}

// The header's compression decides whether the cooker can decode an image before it reads the pixels, so a stage
// warns of a DWAA image, which TinyEXR does not have, instead of failing its texture.
@(test)
exr_headers_say_whether_tinyexr_decodes_them :: proc(t: ^testing.T) {
	compression, ok := exr_compression(EXR_TINY[:])
	testing.expect(t, ok)
	testing.expect_value(t, compression, 0)
	testing.expect_value(t, exr_undecodable(EXR_TINY[:]), "")
	dwaa := EXR_TINY
	marker := "compression\x00compression\x00"
	for i in 0 ..< len(dwaa) - len(marker) - 5 {
		if string(dwaa[i:][:len(marker)]) == marker {
			dwaa[i + len(marker) + 4] = 8
			break
		}
	}
	testing.expect_value(t, exr_undecodable(dwaa[:]), "DWAA compression")
	testing.expect_value(t, exr_undecodable(dwaa[:20]), "its header cannot be read")
}

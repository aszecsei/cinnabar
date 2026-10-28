package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import stbi "vendor:stb/image"

import format "cinnabar:engine/asset/format"

// write_test_image writes a width x height image into the tree: a PNG of RGBA8 gradients, or an HDR file whose values
// pass 1.
@(private)
write_test_image :: proc(t: ^testing.T, tree: Tree, path: string, width, height: int) {
	full := strings.clone_to_cstring(fmt.tprintf("%s/content/%s", tree.dir, path), context.temp_allocator)
	written: i32
	if strings.has_suffix(path, ".hdr") {
		pixels := make([]f32, width * height * 3, context.temp_allocator)
		for &v, i in pixels {
			v = f32(i % 7) * 0.75
		}
		written = stbi.write_hdr(full, i32(width), i32(height), 3, raw_data(pixels))
	} else {
		pixels := make([]u8, width * height * 4, context.temp_allocator)
		for &v, i in pixels {
			v = u8(i * 37 % 256)
		}
		written = stbi.write_png(full, i32(width), i32(height), 4, raw_data(pixels), i32(width * 4))
	}
	testing.expectf(t, written != 0, "cannot write %s", path)
}

@(private = "file")
texture_blob :: proc(t: ^testing.T, tree: Tree, path: string) -> (data: []byte, blob: ^format.Texture_Blob, ok: bool) {
	data = tree_blob(t, tree, tree_guid(t, tree, path))
	blob, ok = format.texture_view(data)
	testing.expectf(t, ok, "%s did not cook into a texture blob", path)
	return
}

@(test)
textures_cook_by_usage_with_their_mips :: proc(t: ^testing.T) {
	tree := make_tree(t, {})
	defer remove_tree(tree)
	os.make_directory_all(fmt.tprintf("%s/content", tree.dir))
	// 18x10 is not whole blocks, so it grows to 20x12.
	write_test_image(t, tree, "albedo.png", 18, 10)
	write_test_image(t, tree, "bricks_n.png", 16, 16)
	write_test_image(t, tree, "rough_r.PNG", 8, 8)
	write_test_image(t, tree, "sky.hdr", 8, 4)
	options := tree_options(tree)

	pass := cook(options, {.Texture})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Texture], 4)

	// The usage comes from the name, and stays in the .meta file.
	meta, _ := os.read_entire_file(fmt.tprintf("%s/content/bricks_n.png.meta", tree.dir), context.temp_allocator)
	testing.expect(t, strings.contains(string(meta), "usage = normal"))

	if data, blob, ok := texture_blob(t, tree, "albedo.png"); ok {
		testing.expect_value(t, blob.format, format.Texture_Format.BC7_Unorm_Srgb)
		testing.expect_value(t, blob.size, [2]u32{20, 12})
		// 20x12, 10x6, 5x3, 2x1, 1x1.
		testing.expect_value(t, blob.mip_count, 5)
		testing.expect_value(t, format.blob_string(data, blob.source_path), "game/albedo.png")
	}
	if _, blob, ok := texture_blob(t, tree, "bricks_n.png"); ok {
		testing.expect_value(t, blob.format, format.Texture_Format.BC5_Unorm)
	}
	if _, blob, ok := texture_blob(t, tree, "rough_r.PNG"); ok {
		testing.expect_value(t, blob.format, format.Texture_Format.BC4_Unorm)
	}
	if _, blob, ok := texture_blob(t, tree, "sky.hdr"); ok {
		testing.expect_value(t, blob.format, format.Texture_Format.BC6H_Ufloat)
		testing.expect_value(t, blob.usage, format.Texture_Usage.HDR)
	}
	testing.expect_value(t, cook(options, {.Texture}).current[.Texture], 4)
}

@(test)
texture_settings_size_and_store_textures :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/ui.png.meta", "guid = 00112233445566778899aabbccddeeff\nusage = data\nmips = false\nmax_size = 256\n"}})
	defer remove_tree(tree)
	write_test_image(t, tree, "ui.png", 600, 300)

	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)
	if data, blob, ok := texture_blob(t, tree, "ui.png"); ok {
		// Halved twice to fit 256, not compressed, and one mip.
		testing.expect_value(t, blob.format, format.Texture_Format.RGBA8_Unorm)
		testing.expect_value(t, blob.size, [2]u32{150, 75})
		testing.expect_value(t, blob.mip_count, 1)
		testing.expect_value(t, len(format.blob_bytes(data, blob.mips)), 150 * 75 * 4)
	}
}

@(test)
a_texture_that_does_not_decode_fails :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/broken.png", "not a png"}})
	defer remove_tree(tree)
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
	expect_error(t, &errors, "broken.png: cannot decode")
}

@(test)
resampling_keeps_flat_images_flat :: proc(t: ^testing.T) {
	image := Image{6, 4, make([][4]f32, 24, context.temp_allocator)}
	for &p in image.pixels {
		p = {0.25, 0.5, 0.75, 1}
	}
	for wrap in ([]bool{true, false}) {
		for size in ([][2]int{{3, 2}, {12, 8}, {1, 1}}) {
			resized := resample(image, size.x, size.y, wrap)
			for p in resized.pixels {
				testing.expectf(t, abs(p.g - 0.5) < 1e-4, "a flat image changed when resized to %v", size)
			}
		}
	}
}

@(test)
compressed_mips_decode_close_to_their_source :: proc(t: ^testing.T) {
	// A smooth image, as most textures are, in values from 0.1 to 0.9.
	width, height :: 16, 8
	image := Image{width, height, make([][4]f32, width * height, context.temp_allocator)}
	for &p, i in image.pixels {
		x, y := f32(i % width) / width, f32(i / width) / height
		p = {0.1 + 0.8 * x, 0.1 + 0.8 * y, 0.5, 1}
	}
	cases := []struct {
		usage:      format.Texture_Usage,
		compressed: Compressed_Format,
		// The channels that the format keeps, and how far a decoded one may be from its source, out of 255.
		channels:   int,
		tolerance:  int,
	}{{.Color, .BC7, 3, 8}, {.Normal, .BC5, 2, 8}, {.Mask, .BC4, 1, 8}}
	for test in cases {
		source := image
		if test.usage == .Normal {
			source = Image{width, height, make([][4]f32, width * height, context.temp_allocator)}
			for p, i in image.pixels {
				source.pixels[i] = {p.x * 2 - 1, p.y * 2 - 1, 0, 1}
			}
		}
		block := format.texture_mip_size(texture_format_of(test.usage), width, height)
		encoded := make([]byte, block, context.temp_allocator)
		testing.expect(t, encode_mip(source, test.usage, DEV_TEXTURE_QUALITY, encoded))
		decoded := make([][4]u8, width * height, context.temp_allocator)
		testing.expect_value(t, cn_decompress(test.compressed, raw_data(encoded), width, height, raw_data(decoded)), 0)
		worst := 0
		for p, i in image.pixels {
			for ch in 0 ..< test.channels {
				want := p[ch]
				if test.usage == .Color {
					want = linear_to_srgb(want)
				}
				worst = max(worst, abs(int(decoded[i][ch]) - int(want * 255 + 0.5)))
			}
		}
		testing.expectf(t, worst <= test.tolerance, "%v decodes %d away from its source", test.usage, worst)
	}

	// BC6H interpolates the endpoints' half-float bits, which are close to logarithmic, so a block that reaches 0 has
	// coarse steps in between. These values stay within one order of magnitude of each other in every block.
	hdr := Image{width, height, make([][4]f32, width * height, context.temp_allocator)}
	for &p, i in hdr.pixels {
		p = {1 + f32(i % width) * 0.5, 4, 0.5, 1}
	}
	encoded := make([]byte, format.texture_mip_size(.BC6H_Ufloat, width, height), context.temp_allocator)
	testing.expect(t, encode_mip(hdr, .HDR, DEV_TEXTURE_QUALITY, encoded))
	decoded := make([][4]f16, width * height, context.temp_allocator)
	testing.expect_value(t, cn_decompress(.BC6H, raw_data(encoded), width, height, raw_data(decoded)), 0)
	for p, i in hdr.pixels {
		for ch in 0 ..< 3 {
			testing.expectf(t, abs(f32(decoded[i][ch]) - p[ch]) < p[ch] * 0.05, "BC6H decodes %v for %v", decoded[i][ch], p[ch])
		}
	}
}

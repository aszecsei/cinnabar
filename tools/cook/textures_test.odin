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

// write_foliage_image writes a PNG that a masked material's foliage might read: each texel is fully set or clear, as a
// seeded hash against a density that rises across the image, so filtered alpha approaches the density and little of it
// stays above 0.5. The density's slant keeps whole columns of texels from crossing a cutoff together in small mips.
@(private = "file")
write_foliage_image :: proc(t: ^testing.T, tree: Tree, path: string, size: int) {
	full := strings.clone_to_cstring(fmt.tprintf("%s/content/%s", tree.dir, path), context.temp_allocator)
	pixels := make([][4]u8, size * size, context.temp_allocator)
	state := u32(2166136261)
	for &p, i in pixels {
		state = state * 1664525 + 1013904223
		x, y := f32(i % size) / f32(size), f32(i / size) / f32(size)
		set := f32(state >> 8) / f32(1 << 24) < 0.55 * (0.7 * x + 0.3 * y)
		p = {40, 120, 30, set ? 255 : 0}
	}
	written := stbi.write_png(full, i32(size), i32(size), 4, raw_data(pixels), i32(size * 4))
	testing.expectf(t, written != 0, "cannot write %s", path)
}

// mip_coverages decodes a cooked color texture's mips, and gives the coverage of each at a cutoff, to the last mip that
// is at least 16 texels wide, where a texel's share of the mip is small beside a test's tolerance.
@(private = "file")
mip_coverages :: proc(t: ^testing.T, data: []byte, blob: ^format.Texture_Blob, cutoff: f32) -> []f32 {
	coverages := make([dynamic]f32, context.temp_allocator)
	mips := format.blob_bytes(data, blob.mips)
	width, height := blob.size.x, blob.size.y
	offset := 0
	for _ in 0 ..< blob.mip_count {
		if width < 16 {
			break
		}
		decoded := make([][4]u8, int(width * height), context.temp_allocator)
		testing.expect_value(t, cn_decompress(.BC7, raw_data(mips[offset:]), width, height, raw_data(decoded)), 0)
		covered := 0
		for p in decoded {
			if f32(p.a) / 255 >= cutoff {
				covered += 1
			}
		}
		append(&coverages, f32(covered) / f32(len(decoded)))
		offset += format.texture_mip_size(blob.format, width, height)
		width, height = max(width / 2, 1), max(height / 2, 1)
	}
	return coverages[:]
}

@(test)
alpha_coverage_holds_down_the_mips_with_the_setting_on :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/off.png.meta", "guid = 00112233445566778899aabbccddee00\nusage = color\n"},
			{"content/on.png.meta", "guid = 00112233445566778899aabbccddee01\nusage = color\nalpha_coverage = true\n"},
			{"content/low.png.meta", "guid = 00112233445566778899aabbccddee02\nusage = color\nalpha_coverage = true\nalpha_cutoff = 0.25\n"},
		},
	)
	defer remove_tree(tree)
	cases := []struct {
		name:   string,
		cutoff: f32,
		kept:   bool,
	}{{"off", 0.5, false}, {"on", 0.5, true}, {"low", 0.25, true}}
	for test in cases {
		write_foliage_image(t, tree, fmt.tprintf("%s.png", test.name), 256)
	}
	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)

	for test in cases {
		data, blob, ok := texture_blob(t, tree, fmt.tprintf("%s.png", test.name))
		if !ok {
			continue
		}
		coverages := mip_coverages(t, data, blob, test.cutoff)
		// 256 to 16.
		testing.expect_value(t, len(coverages), 5)
		first, last := coverages[0], coverages[len(coverages) - 1]
		testing.expectf(t, first > 0.1, "%s: mip 0's coverage is %v", test.name, first)
		if test.kept {
			for coverage, mip in coverages {
				testing.expectf(t, abs(coverage - first) <= 0.02, "%s: mip %d covers %v, and mip 0 %v", test.name, mip, coverage, first)
			}
		} else {
			testing.expectf(t, last < first / 2, "%s: the last mip covers %v, and mip 0 %v", test.name, last, first)
		}
	}
}

@(test)
the_coverage_search_finds_the_scale :: proc(t: ^testing.T) {
	// A ramp of alpha from 0 to 0.5: half of its texels reach 0.25, and at a scale of 2, half reach 0.5.
	ramp := Image{256, 1, make([][4]f32, 256, context.temp_allocator)}
	for &p, i in ramp.pixels {
		p = {0, 0, 0, f32(i) / 512}
	}
	scale := alpha_coverage_scale(ramp, 0.5, 0.5)
	testing.expectf(t, abs(alpha_coverage(ramp, 0.5, scale) - 0.5) <= 1.0 / 256, "a scale of %v covers %v", scale, alpha_coverage(ramp, 0.5, scale))
	testing.expectf(t, abs(scale - 2) < 0.05, "the scale is %v", scale)

	// An opaque image already has its coverage, so its alpha stays.
	opaque := Image{4, 4, make([][4]f32, 16, context.temp_allocator)}
	for &p in opaque.pixels {
		p = {0, 0, 0, 1}
	}
	testing.expect_value(t, alpha_coverage_scale(opaque, 0.5, 1), 1)

	testing.expect_value(t, scale_alpha(ramp, 4).pixels[255].a, 1)
}

@(test)
alpha_coverage_is_only_for_color_textures :: proc(t: ^testing.T) {
	a := Asset_Source {
		meta = {settings = {{"usage", "mask"}, {"alpha_coverage", "true"}, {"alpha_cutoff", "0.25"}}},
	}
	testing.expect_value(t, texture_cook_of(a).coverage_cutoff, 0)
	a.meta.settings[0].value = "color"
	testing.expect_value(t, texture_cook_of(a).coverage_cutoff, 0.25)
}

@(test)
alpha_coverage_settings_are_in_the_key_and_checked :: proc(t: ^testing.T) {
	META :: "guid = 00112233445566778899aabbccddeeff\nusage = color\n"
	tree := make_tree(t, {{"content/leaf.png.meta", META}})
	defer remove_tree(tree)
	write_test_image(t, tree, "leaf.png", 16, 16)
	options := tree_options(tree)
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 1)

	meta_path := fmt.tprintf("%s/content/leaf.png.meta", tree.dir)
	testing.expect(t, os.write_entire_file(meta_path, transmute([]byte)string(META + "alpha_coverage = true\n")) == nil)
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 1)

	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, os.write_entire_file(meta_path, transmute([]byte)string(META + "alpha_cutoff = 2\n")) == nil)
	testing.expect(t, !cook(options, {.Texture}).ok)
	expect_error(t, &errors, "alpha_cutoff must be")
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

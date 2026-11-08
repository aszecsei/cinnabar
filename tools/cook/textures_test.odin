package cook

import "core:fmt"
import "core:math"
import "core:mem"
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

// A distinct color for each of a cube's faces, in the order of its layers.
@(private = "file")
FACE_COLORS := [6][4]u8{{255, 0, 0, 255}, {0, 255, 255, 255}, {0, 255, 0, 255}, {255, 0, 255, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}}

// A .meta file of a texture that keeps its values and its one mip, so a test reads its blob's texels as they are.
@(private = "file")
RAW_SETTINGS :: "usage = data\nmips = false\n"

@(private = "file")
write_pixels :: proc(t: ^testing.T, tree: Tree, path: string, width, height: int, pixels: [][4]u8) {
	full := strings.clone_to_cstring(fmt.tprintf("%s/content/%s", tree.dir, path), context.temp_allocator)
	testing.expectf(t, stbi.write_png(full, i32(width), i32(height), 4, raw_data(pixels), i32(width * 4)) != 0, "cannot write %s", path)
}

@(private = "file")
write_flat :: proc(t: ^testing.T, tree: Tree, path: string, width, height: int, color: [4]u8) {
	pixels := make([][4]u8, width * height, context.temp_allocator)
	for &p in pixels {
		p = color
	}
	write_pixels(t, tree, path, width, height, pixels)
}

// write_cross writes a cross of faces of a size, each flat in its face's color but for a gray top-left texel, in cells
// given by the layer order.
@(private = "file")
write_cross :: proc(t: ^testing.T, tree: Tree, path: string, size, across, down: int, cells: [6][2]int, marks: [6][2]int) {
	pixels := make([][4]u8, size * across * size * down, context.temp_allocator)
	for cell, face in cells {
		for y in 0 ..< size {
			for x in 0 ..< size {
				pixels[(cell.y * size + y) * size * across + cell.x * size + x] = FACE_COLORS[face]
			}
		}
		mark := marks[face]
		pixels[(cell.y * size + mark.y) * size * across + cell.x * size + mark.x] = {128, 128, 128, 255}
	}
	write_pixels(t, tree, path, size * across, size * down, pixels)
}

// layer_pixels is the texels of a raw texture's layer, one mip each.
@(private = "file")
layer_pixels :: proc(data: []byte, blob: ^format.Texture_Blob, layer: int) -> [][4]u8 {
	bytes := format.blob_bytes(data, blob.mips)
	size := int(blob.size.x * blob.size.y) * 4
	return mem.slice_data_cast([][4]u8, bytes[layer * size:][:size])
}

@(test)
a_cross_cooks_into_a_cube_with_its_faces_in_place :: proc(t: ^testing.T) {
	META :: RAW_SETTINGS + "layout = cube_cross\n"
	tree := make_tree(
		t,
		{
			{"content/across.png.meta", "guid = 00112233445566778899aabbccddee10\n" + META},
			{"content/down.png.meta", "guid = 00112233445566778899aabbccddee11\n" + META},
		},
	)
	defer remove_tree(tree)
	SIZE :: 4
	top_left := [6][2]int{}
	// +x, -x, +y, -y, +z, -z. In the vertical cross, -z is below -y, turned by half a turn, so the texel that ends at its
	// top left starts at its bottom right.
	write_cross(t, tree, "across.png", SIZE, 4, 3, {{2, 1}, {0, 1}, {1, 0}, {1, 2}, {1, 1}, {3, 1}}, top_left)
	turned := top_left
	turned[5] = {SIZE - 1, SIZE - 1}
	write_cross(t, tree, "down.png", SIZE, 3, 4, {{2, 1}, {0, 1}, {1, 0}, {1, 2}, {1, 1}, {1, 3}}, turned)
	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)

	for name in ([]string{"across.png", "down.png"}) {
		data, blob, ok := texture_blob(t, tree, name)
		if !ok {
			continue
		}
		testing.expect_value(t, blob.dimension, format.Texture_Dimension.Cube)
		testing.expect_value(t, blob.layer_count, 6)
		testing.expect_value(t, blob.size, [2]u32{SIZE, SIZE})
		for color, face in FACE_COLORS {
			pixels := layer_pixels(data, blob, face)
			testing.expectf(t, pixels[0] == {128, 128, 128, 255}, "%s: face %d's top-left texel is %v", name, face, pixels[0])
			testing.expectf(t, pixels[len(pixels) - 1] == color, "%s: face %d's last texel is %v", name, face, pixels[len(pixels) - 1])
		}
	}
}

@(test)
a_cross_of_the_wrong_shape_fails :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/square.png.meta", "guid = 00112233445566778899aabbccddee12\n" + RAW_SETTINGS + "layout = cube_cross\n"}})
	defer remove_tree(tree)
	write_flat(t, tree, "square.png", 8, 8, {0, 0, 0, 255})
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
	expect_error(t, &errors, "a cross is 4 faces across")
}

@(test)
an_equirectangular_image_cooks_into_a_cube_as_the_sky_maps_it :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/sky.png.meta", "guid = 00112233445566778899aabbccddee13\n" + RAW_SETTINGS + "layout = cube_equirect\n"}})
	defer remove_tree(tree)
	// Each texel in the color of the axis nearest to its direction, by texture_direction in sky_texture.hlsli.
	WIDTH, HEIGHT :: 128, 64
	pixels := make([][4]u8, WIDTH * HEIGHT, context.temp_allocator)
	for &p, i in pixels {
		azimuth := ((f32(i % WIDTH) + 0.5) / WIDTH - 0.5) * 2 * math.PI
		polar := (f32(i / WIDTH) + 0.5) / HEIGHT * math.PI
		d := [3]f32{math.sin(polar) * math.sin(azimuth), math.cos(polar), math.sin(polar) * math.cos(azimuth)}
		axis := 0
		for k in 1 ..< 3 {
			if abs(d[k]) > abs(d[axis]) {
				axis = k
			}
		}
		p = FACE_COLORS[axis * 2 + (d[axis] < 0 ? 1 : 0)]
	}
	write_pixels(t, tree, "sky.png", WIDTH, HEIGHT, pixels)
	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)

	data, blob, ok := texture_blob(t, tree, "sky.png")
	if !ok {
		return
	}
	testing.expect_value(t, blob.dimension, format.Texture_Dimension.Cube)
	testing.expect_value(t, blob.layer_count, 6)
	// A quarter of its width.
	testing.expect_value(t, blob.size, [2]u32{32, 32})
	for color, face in FACE_COLORS {
		middle := layer_pixels(data, blob, face)[16 * 32 + 16]
		testing.expectf(t, middle == color, "face %d's middle is %v, not %v", face, middle, color)
	}
}

@(test)
an_equirectangular_image_is_twice_as_wide_as_it_is_tall :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/sky.png.meta", "guid = 00112233445566778899aabbccddee14\n" + RAW_SETTINGS + "layout = cube_equirect\n"}})
	defer remove_tree(tree)
	write_flat(t, tree, "sky.png", 8, 8, {0, 0, 0, 255})
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
	expect_error(t, &errors, "twice as wide")
}

@(test)
a_strip_cooks_into_an_array :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/strip.png.meta", "guid = 00112233445566778899aabbccddee15\n" + RAW_SETTINGS + "layout = array_strip\n"},
			{"content/uneven.png.meta", "guid = 00112233445566778899aabbccddee16\n" + RAW_SETTINGS + "layout = array_strip\n"},
		},
	)
	defer remove_tree(tree)
	pixels := make([][4]u8, 4 * 12, context.temp_allocator)
	for &p, i in pixels {
		p = FACE_COLORS[i / (4 * 4)]
	}
	write_pixels(t, tree, "strip.png", 4, 12, pixels)
	write_flat(t, tree, "uneven.png", 4, 10, {0, 0, 0, 255})
	errors: Errors
	context.logger = capture_errors(&errors)
	defer release_errors(&errors)
	testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
	expect_error(t, &errors, "a strip is square layers")

	data, blob, ok := texture_blob(t, tree, "strip.png")
	if !ok {
		return
	}
	testing.expect_value(t, blob.dimension, format.Texture_Dimension.D2_Array)
	testing.expect_value(t, blob.layer_count, 3)
	testing.expect_value(t, blob.size, [2]u32{4, 4})
	for layer in 0 ..< 3 {
		testing.expect_value(t, layer_pixels(data, blob, layer)[5], FACE_COLORS[layer])
	}
}

// set_face_tree is a tree with six flat images, one for each of a cube's faces, of GUIDs that end in 0 to 5, and the
// text of a .texture_set that names them.
@(private = "file")
SET_GUIDS := [6]string {
	"aabbccddeeff00112233445566778800",
	"aabbccddeeff00112233445566778801",
	"aabbccddeeff00112233445566778802",
	"aabbccddeeff00112233445566778803",
	"aabbccddeeff00112233445566778804",
	"aabbccddeeff00112233445566778805",
}
@(private = "file")
SET_META :: "guid = aabbccddeeff00112233445566778810\n" + RAW_SETTINGS
@(private = "file")
CUBE_SET :: "# The faces.\npx = $aabbccddeeff00112233445566778800\nnx = $aabbccddeeff00112233445566778801\npy = $aabbccddeeff00112233445566778802\nny = $aabbccddeeff00112233445566778803\n\npz = $aabbccddeeff00112233445566778804\nnz = $aabbccddeeff00112233445566778805\n"

@(private = "file")
write_set_images :: proc(t: ^testing.T, tree: Tree, child_settings: string, size := 4) {
	for guid, i in SET_GUIDS {
		name := fmt.tprintf("face%d.png", i)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/%s.meta", tree.dir, name), transmute([]byte)fmt.tprintf("guid = %s\n%s", guid, child_settings)) == nil)
		write_flat(t, tree, name, size, size, FACE_COLORS[i])
	}
}

@(test)
a_texture_set_cooks_the_images_that_it_names :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/sky.texture_set", CUBE_SET},
			{"content/sky.texture_set.meta", SET_META},
			{"content/row.texture_set", "layer = $aabbccddeeff00112233445566778802\nlayer = $aabbccddeeff00112233445566778800\n"},
			{"content/row.texture_set.meta", "guid = aabbccddeeff00112233445566778811\nusage = data\n"},
		},
	)
	defer remove_tree(tree)
	write_set_images(t, tree, "usage = data\n")
	options := tree_options(tree)
	pass := cook(options, {.Texture})
	testing.expect(t, pass.ok)
	// The six images, which are textures of their own, and the two sets.
	testing.expect_value(t, pass.cooked[.Texture], 8)

	data, blob, ok := texture_blob(t, tree, "sky.texture_set")
	if ok {
		testing.expect_value(t, blob.dimension, format.Texture_Dimension.Cube)
		testing.expect_value(t, blob.layer_count, 6)
		testing.expect_value(t, blob.size, [2]u32{4, 4})
		testing.expect_value(t, format.blob_string(data, blob.source_path), "game/sky.texture_set")
		for color, face in FACE_COLORS {
			testing.expect_value(t, layer_pixels(data, blob, face)[0], color)
		}
	}
	// Each layer has a whole chain of its own: 4x4, 2x2 and 1x1.
	data, blob, ok = texture_blob(t, tree, "row.texture_set")
	if ok {
		testing.expect_value(t, blob.dimension, format.Texture_Dimension.D2_Array)
		testing.expect_value(t, blob.layer_count, 2)
		testing.expect_value(t, blob.mip_count, 3)
		chain := format.texture_chain_size(.RGBA8_Unorm, {4, 4}, 3)
		testing.expect_value(t, chain, (16 + 4 + 1) * 4)
		bytes := format.blob_bytes(data, blob.mips)
		testing.expect_value(t, len(bytes), chain * 2)
		for color, layer in ([2][4]u8{FACE_COLORS[2], FACE_COLORS[0]}) {
			pixels := mem.slice_data_cast([][4]u8, bytes[layer * chain:][:chain])
			for offset in ([]int{0, 16, 20}) {
				testing.expectf(t, pixels[offset] == color, "layer %d at texel %d is %v", layer, offset, pixels[offset])
			}
		}
	}

	// The index says what a set depends on.
	for a in pass.assets {
		if strings.has_suffix(a.path, "row.texture_set") {
			testing.expect_value(t, len(a.dependencies), 2)
		}
	}

	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 0)
	// A new image cooks itself and the sets that name it: face0 is in both.
	write_flat(t, tree, "face0.png", 4, 4, {9, 9, 9, 255})
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 3)
	data, blob, ok = texture_blob(t, tree, "sky.texture_set")
	if ok {
		testing.expect_value(t, layer_pixels(data, blob, 0)[0], [4]u8{9, 9, 9, 255})
	}
	// An image's settings are not the set's, so they do not cook it again.
	face := fmt.tprintf("%s/content/face1.png.meta", tree.dir)
	testing.expect(t, os.write_entire_file(face, transmute([]byte)fmt.tprintf("guid = %s\nusage = data\nmax_size = 256\n", SET_GUIDS[1])) == nil)
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 1)
}

@(test)
a_set_of_hdr_images_is_bc6h_with_a_chain_for_each_face :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/sky.hdr.meta", "guid = 00112233445566778899aabbccddee17\nusage = hdr\nlayout = cube_cross\n"}})
	defer remove_tree(tree)
	write_test_image(t, tree, "sky.hdr", 32, 24)
	testing.expect(t, cook(tree_options(tree), {.Texture}).ok)
	if data, blob, ok := texture_blob(t, tree, "sky.hdr"); ok {
		testing.expect_value(t, blob.format, format.Texture_Format.BC6H_Ufloat)
		testing.expect_value(t, blob.dimension, format.Texture_Dimension.Cube)
		testing.expect_value(t, blob.mip_count, 4)
		testing.expect_value(t, len(format.blob_bytes(data, blob.mips)), format.texture_chain_size(.BC6H_Ufloat, {8, 8}, 4) * 6)
	}
}

@(test)
a_bad_texture_set_says_what_is_wrong :: proc(t: ^testing.T) {
	LAYER :: "layer = $aabbccddeeff00112233445566778800\n"
	cases := []struct {
		text, meta, error: string,
	} {
		{CUBE_SET + LAYER, "", "has both a cube's faces and an array's layers"},
		{"px = $aabbccddeeff00112233445566778800\n", "", "has no nx"},
		{"# Nothing.\n", "", "names no images"},
		{"up = $aabbccddeeff00112233445566778800\n", "", "unknown key \"up\""},
		{"layer\n", "", "needs `key = $guid`"},
		{"layer = aabbccddeeff00112233445566778800\n", "", "GUID after $"},
		{"layer = $aabb\n", "", "32 hex digits"},
		{"layer = $00000000000000000000000000000abc\n", "", "no asset has the GUID"},
		{"layer = $aabbccddeeff00112233445566778810\n", "", "is not an image"},
		{"px = $aabbccddeeff00112233445566778800\npx = $aabbccddeeff00112233445566778800\n", "", "has px twice"},
		{LAYER, "layout = cube_cross\n", "layout is for one image"},
		{LAYER, "standalone = false\n", "standalone cannot be false"},
	}
	for test in cases {
		tree := make_tree(t, {{"content/set.texture_set", test.text}, {"content/set.texture_set.meta", fmt.tprintf("%s%s", SET_META, test.meta)}})
		defer remove_tree(tree)
		write_set_images(t, tree, "usage = data\n")
		errors: Errors
		context.logger = capture_errors(&errors)
		defer release_errors(&errors)
		testing.expectf(t, !cook(tree_options(tree), {.Texture}).ok, "%q cooked", test.text)
		expect_error(t, &errors, test.error)
	}
}

@(test)
a_set_takes_plain_images_of_one_size :: proc(t: ^testing.T) {
	// One image of another size.
	{
		tree := make_tree(t, {{"content/sky.texture_set", CUBE_SET}, {"content/sky.texture_set.meta", SET_META}})
		defer remove_tree(tree)
		write_set_images(t, tree, "usage = data\n")
		write_flat(t, tree, "face3.png", 8, 8, {0, 0, 0, 255})
		errors: Errors
		context.logger = capture_errors(&errors)
		defer release_errors(&errors)
		testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
		expect_error(t, &errors, "a set's images are one size")
	}
	// Faces that are not square. An array's layers can be any one size.
	{
		tree := make_tree(
			t,
			{
				{"content/sky.texture_set", CUBE_SET},
				{"content/sky.texture_set.meta", SET_META},
				{"content/row.texture_set", "layer = $aabbccddeeff00112233445566778800\n"},
				{"content/row.texture_set.meta", "guid = aabbccddeeff00112233445566778811\n" + RAW_SETTINGS},
			},
		)
		defer remove_tree(tree)
		write_set_images(t, tree, "usage = data\n")
		for i in 0 ..< 6 {
			write_flat(t, tree, fmt.tprintf("face%d.png", i), 8, 4, FACE_COLORS[i])
		}
		errors: Errors
		context.logger = capture_errors(&errors)
		defer release_errors(&errors)
		testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
		expect_error(t, &errors, "a cube's faces are square")
		if _, blob, ok := texture_blob(t, tree, "row.texture_set"); ok {
			testing.expect_value(t, blob.size, [2]u32{8, 4})
		}
	}
	// An image that is laid out as layers of its own.
	{
		tree := make_tree(
			t,
			{
				{"content/row.texture_set", "layer = $aabbccddeeff00112233445566778812\n"},
				{"content/row.texture_set.meta", SET_META},
				{"content/strip.png.meta", "guid = aabbccddeeff00112233445566778812\nusage = data\nlayout = array_strip\n"},
			},
		)
		defer remove_tree(tree)
		write_flat(t, tree, "strip.png", 4, 8, {0, 0, 0, 255})
		errors: Errors
		context.logger = capture_errors(&errors)
		defer release_errors(&errors)
		testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
		expect_error(t, &errors, "a set's image is one layer")
	}
}

@(test)
an_image_whose_usage_is_not_its_sets_is_a_warning :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/sky.texture_set", CUBE_SET}, {"content/sky.texture_set.meta", SET_META}})
	defer remove_tree(tree)
	write_set_images(t, tree, "usage = hdr\n")
	pass := cook(tree_options(tree), {.Texture}, log_problems = false)
	testing.expect(t, pass.ok)
	expect_warning(t, pass, "has the usage hdr, and this set cooks it as data")
}

@(private = "file")
expect_warning :: proc(t: ^testing.T, pass: Pass, fragment: string, loc := #caller_location) {
	for p in pass.problems.list {
		if !p.error && strings.contains(p.text, fragment) {
			return
		}
	}
	testing.expectf(t, false, "no warning contains %q: %v", fragment, pass.problems.list, loc = loc)
}

@(test)
an_image_that_is_not_standalone_cooks_only_in_its_set :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/sky.texture_set", CUBE_SET}, {"content/sky.texture_set.meta", SET_META}})
	defer remove_tree(tree)
	write_set_images(t, tree, "usage = data\n")
	options := tree_options(tree)
	// Six images and the set, with a blob each.
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 7)
	blob_of :: proc(tree: Tree, guid_text: string) -> string {
		return fmt.tprintf("%s/cache/%s.blob", tree.dir, guid_text)
	}
	testing.expect(t, os.exists(blob_of(tree, SET_GUIDS[0])))

	// Turning it off deletes the image's blobs, so that none can keep drawing, and the set does not cook again.
	write_set_images(t, tree, "usage = data\nstandalone = false\n")
	pass := cook(options, {.Texture})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Texture], 0)
	// The set, and the six images, which have nothing to cook.
	testing.expect_value(t, pass.current[.Texture], 7)
	for guid in SET_GUIDS {
		testing.expectf(t, !os.exists(blob_of(tree, guid)), "%s kept its blob", guid)
	}
	for a in pass.assets {
		if strings.has_suffix(a.path, ".png") {
			testing.expect_value(t, a.size, [2]u32{})
			testing.expect_value(t, a.result, Asset_Result.Current)
		}
	}
	if data, blob, ok := texture_blob(t, tree, "sky.texture_set"); ok {
		testing.expect_value(t, layer_pixels(data, blob, 2)[0], FACE_COLORS[2])
	}

	// The set still sees its images change.
	write_flat(t, tree, "face2.png", 4, 4, {7, 7, 7, 255})
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 1)
	if data, blob, ok := texture_blob(t, tree, "sky.texture_set"); ok {
		testing.expect_value(t, layer_pixels(data, blob, 2)[0], [4]u8{7, 7, 7, 255})
	}

	// Turning it on again cooks the images.
	write_set_images(t, tree, "usage = data\nstandalone = true\n")
	testing.expect_value(t, cook(options, {.Texture}).cooked[.Texture], 7)
	testing.expect(t, os.exists(blob_of(tree, SET_GUIDS[0])))
}

@(test)
an_image_that_is_not_standalone_and_in_no_set_is_a_warning :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/lost.png.meta", "guid = 00112233445566778899aabbccddee18\nstandalone = false\n"}})
	defer remove_tree(tree)
	write_flat(t, tree, "lost.png", 4, 4, {0, 0, 0, 255})
	pass := cook(tree_options(tree), {.Texture}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Texture], 0)
	expect_warning(t, pass, "no .texture_set names it")
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

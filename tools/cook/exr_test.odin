package cook

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import exr "vendor:OpenEXRCore"

import format "cinnabar:engine/asset/format"

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

@(test)
exr_version_comes_from_the_library :: proc(t: ^testing.T) {
	version := openexr_version()
	testing.expectf(t, strings.has_prefix(version, "3."), "OpenEXRCore's version is %q", version)
}

// Exr_Test_Image describes a file for write_test_exr to write. Channels of the same name hold the same values in every
// layout, so a test can compare any decoded pixel with exr_test_value.
@(private = "file")
Exr_Test_Image :: struct {
	width, height: int,
	channels:      []string,
	type:          exr.pixel_type_t,
	compression:   exr.compression_t,
	// The tiles' side, or 0 for scanlines.
	tile:          int,
	mips:          bool,
	// The corner of the data window.
	origin:        [2]i32,
	// Every channel's subsampling, or 0 for none.
	sampling:      i32,
	// A is half, whatever type the other channels are.
	half_alpha:    bool,
}

// exr_test_value is a smooth ramp, so that lossy compression stays close, and it is different for each channel and
// pixel, so that a misplaced tile shows.
@(private = "file")
exr_test_value :: proc(channel: string, x, y: int) -> f32 {
	switch channel {
	case "R":
		return 0.5 + f32(x) * 0.25
	case "G":
		return 2 + f32(y) * 0.5
	case "B":
		return 1 + f32(x + y) * 0.125
	case "A":
		return 0.25 + f32(y) * 0.0625
	case "Y":
		return 0.75 + f32(x) * 0.125
	}
	return 1000
}

@(private = "file")
exr_check :: proc(t: ^testing.T, result: exr.result_t, loc := #caller_location) {
	testing.expectf(t, result == .SUCCESS, "OpenEXRCore gave %s", exr.get_error_code_as_string(result), loc = loc)
}

// Exr_Test_Writer encodes chunks with one pipeline from a plane of floats for each channel.
@(private = "file")
Exr_Test_Writer :: struct {
	t:        ^testing.T,
	ctx:      exr.context_t,
	image:    Exr_Test_Image,
	planes:   map[string][]f32,
	pipeline: exr.encode_pipeline_t,
	started:  bool,
}

@(private = "file")
exr_write_chunk :: proc(w: ^Exr_Test_Writer, chunk: ^exr.chunk_info_t, x, y: int) {
	if w.started {
		exr_check(w.t, exr.encoding_update(w.ctx, 0, chunk, &w.pipeline))
	} else {
		exr_check(w.t, exr.encoding_initialize(w.ctx, 0, chunk, &w.pipeline))
	}
	for i in 0 ..< w.pipeline.channel_count {
		channel := &w.pipeline.channels[i]
		plane := w.planes[string(channel.channel_name)]
		channel.user_bytes_per_element = size_of(f32)
		channel.user_data_type = u16(exr.pixel_type_t.FLOAT)
		channel.user_pixel_stride = size_of(f32)
		channel.user_line_stride = i32(w.image.width * size_of(f32))
		channel.encode_from_ptr = (^u8)(&plane[y * w.image.width + x])
	}
	if !w.started {
		exr_check(w.t, exr.encoding_choose_default_routines(w.ctx, 0, &w.pipeline))
		w.started = true
	}
	exr_check(w.t, exr.encoding_run(w.ctx, 0, &w.pipeline))
}

// write_test_exr writes the image with OpenEXRCore's encoder. A smaller mip's tiles repeat the top of the image, so a
// decoder that reads them puts the wrong values in place.
@(private = "file")
write_test_exr :: proc(t: ^testing.T, path: string, image: Exr_Test_Image) {
	init := exr.DEFAULT_CONTEXT_INITIALIZER
	init.size = size_of(exr.context_initializer_t)
	w := Exr_Test_Writer {
		t        = t,
		image    = image,
		pipeline = exr.ENCODE_PIPELINE_INITIALIZER,
		planes   = make(map[string][]f32, context.temp_allocator),
	}
	exr_check(t, exr.start_write(&w.ctx, strings.clone_to_cstring(path, context.temp_allocator), .WRITE_FILE_DIRECTLY, &init))
	part: c.int
	exr_check(t, exr.add_part(w.ctx, "image", image.tile > 0 ? .TILED : .SCANLINE, &part))
	exr_check(t, exr.initialize_required_attr_simple(w.ctx, part, i32(image.width), i32(image.height), image.compression))
	if image.origin != {} {
		window := exr.attr_box2i_t {
			min = exr.attr_v2i_t(image.origin),
			max = exr.attr_v2i_t(image.origin + {i32(image.width) - 1, i32(image.height) - 1}),
		}
		exr.set_data_window(w.ctx, part, &window)
	}
	sampling := max(image.sampling, 1)
	for name in image.channels {
		type := image.half_alpha && name == "A" ? exr.pixel_type_t.HALF : image.type
		exr_check(t, exr.add_channel(w.ctx, part, strings.clone_to_cstring(name, context.temp_allocator), type, .LOGARITHMIC, sampling, sampling))
		plane := make([]f32, image.width * image.height, context.temp_allocator)
		for &v, i in plane {
			v = exr_test_value(name, i % image.width, i / image.width)
		}
		w.planes[name] = plane
	}
	if image.tile > 0 {
		exr_check(t, exr.set_tile_descriptor(w.ctx, part, u32(image.tile), u32(image.tile), image.mips ? .MIPMAP_LEVELS : .ONE_LEVEL, .DOWN))
	}
	exr_check(t, exr.write_header(w.ctx))

	chunk: exr.chunk_info_t
	if image.tile > 0 {
		levels_x, levels_y: i32
		exr_check(t, exr.get_tile_levels(w.ctx, part, &levels_x, &levels_y))
		for level in 0 ..< levels_x {
			columns, rows: i32
			exr_check(t, exr.get_tile_counts(w.ctx, part, level, level, &columns, &rows))
			for row in 0 ..< rows {
				for column in 0 ..< columns {
					exr_check(t, exr.write_tile_chunk_info(w.ctx, part, column, row, level, level, &chunk))
					exr_write_chunk(&w, &chunk, int(column) * image.tile, int(row) * image.tile)
				}
			}
		}
	} else {
		lines: i32
		exr_check(t, exr.get_scanlines_per_chunk(w.ctx, part, &lines))
		for line := i32(0); line < i32(image.height); line += lines {
			exr_check(t, exr.write_scanline_chunk_info(w.ctx, part, image.origin.y + line, &chunk))
			exr_write_chunk(&w, &chunk, 0, int(line))
		}
	}
	exr_check(t, exr.encoding_destroy(w.ctx, &w.pipeline))
	exr_check(t, exr.finish(&w.ctx))
}

@(private = "file")
exr_test_tree :: proc(t: ^testing.T) -> Tree {
	tree := make_tree(t, {})
	os.make_directory_all(fmt.tprintf("%s/content", tree.dir))
	return tree
}

@(private = "file")
read_test_file :: proc(t: ^testing.T, path: string) -> []byte {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot read %s", path)
	return data
}

// expect_exr_pixels decodes a file and compares its pixels with the values written, RGB being opaque.
@(private = "file")
expect_exr_pixels :: proc(t: ^testing.T, path: string, image: Exr_Test_Image, tolerance: f32, loc := #caller_location) {
	width, height, pixels, err := decode_exr(read_test_file(t, path))
	testing.expect_value(t, err, "", loc = loc)
	if err != "" {
		return
	}
	testing.expect_value(t, width, image.width, loc = loc)
	testing.expect_value(t, height, image.height, loc = loc)
	has_alpha := slice.contains(image.channels, "A")
	for y in 0 ..< image.height {
		for x in 0 ..< image.width {
			want := [4]f32{exr_test_value("R", x, y), exr_test_value("G", x, y), exr_test_value("B", x, y), has_alpha ? exr_test_value("A", x, y) : 1}
			for got, slot in pixels[y * width + x] {
				if abs(got - want[slot]) > tolerance {
					testing.expectf(t, false, "%s %v: pixel %d, %d channel %d is %f, not %f", image.compression, image.type, x, y, slot, got, want[slot], loc = loc)
					return
				}
			}
		}
	}
}

// Issue #32's own case: a new file becomes usage = hdr, with BC6H and every mip, and values above 1 survive.
@(test)
exr_textures_cook_to_bc6h_with_their_mips :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	write_test_exr(t, fmt.tprintf("%s/content/sky.exr", tree.dir), {width = 16, height = 8, channels = {"R", "G", "B"}, type = .FLOAT, compression = .ZIP})
	options := tree_options(tree)

	pass := cook(options, {.Texture})
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Texture], 1)

	meta := read_test_file(t, fmt.tprintf("%s/content/sky.exr.meta", tree.dir))
	testing.expect(t, strings.contains(string(meta), "usage = hdr"))

	data := tree_blob(t, tree, tree_guid(t, tree, "sky.exr"))
	blob, ok := format.texture_view(data)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, blob.format, format.Texture_Format.BC6H_Ufloat)
		testing.expect_value(t, blob.usage, format.Texture_Usage.HDR)
		testing.expect_value(t, blob.size, [2]u32{16, 8})
		// 16x8, 8x4, 4x2, 2x1, 1x1.
		testing.expect_value(t, blob.mip_count, 5)

		// Green reaches 2 + 7 * 0.5 at the bottom of the image, so mip 0's last block holds it, far past what a color
		// format could. Half floats decode from the blocks.
		pixels := make([][4]u16, 16 * 8, context.temp_allocator)
		testing.expect_value(t, cn_decompress(.BC6H, raw_data(format.blob_bytes(data, blob.mips)), 16, 8, raw_data(pixels)), 0)
		brightest: f32
		for p in pixels {
			brightest = max(brightest, f32(transmute(f16)p.g))
		}
		testing.expectf(t, abs(brightest - 5.5) < 0.5, "the brightest green after BC6H is %f, not about 5.5", brightest)
	}
	testing.expect_value(t, cook(options, {.Texture}).current[.Texture], 1)
}

// The layouts that HDR tools write, through codecs of each kind: none, lossless, and lossy, such as the DWAA of the Intel
// sample's palm trunks.
@(test)
exr_layouts_decode_in_every_compression :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	path := fmt.tprintf("%s/content/image.exr", tree.dir)
	for compression in ([]exr.compression_t{.NONE, .RLE, .ZIPS, .ZIP, .PIZ, .PXR24, .B44, .B44A, .DWAA, .DWAB}) {
		for type in ([]exr.pixel_type_t{.HALF, .FLOAT}) {
			// B44 stores floats raw, so all-float chunks come out exactly as large as uncompressed ones. OpenEXRCore's
			// encoder then keeps them in B44's channel order, which readers take for the uncompressed order, so it writes a
			// file that it cannot read back. exr_mixed_types_decode covers B44's floats.
			if (compression == .B44 || compression == .B44A) && type == .FLOAT {
				continue
			}
			for channels in ([][]string{{"R", "G", "B"}, {"R", "G", "B", "A"}}) {
				image := Exr_Test_Image {
					width       = 64,
					height      = 40,
					channels    = channels,
					type        = type,
					compression = compression,
				}
				write_test_exr(t, path, image)
				// The ramps are exact in half floats, and PXR24's 24 bits hold them. DWA is lossy.
				tolerance: f32 = 0.002
				if compression == .DWAA || compression == .DWAB {
					tolerance = 0.25
				}
				expect_exr_pixels(t, path, image, tolerance)
				testing.expect_value(t, image_undecodable(path), "")
			}
		}
	}
}

// Float color with half alpha decodes in each codec, including the B44 float channels that it stores raw beside its half
// blocks.
@(test)
exr_mixed_types_decode :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	path := fmt.tprintf("%s/content/image.exr", tree.dir)
	for compression in ([]exr.compression_t{.NONE, .ZIP, .PIZ, .PXR24, .B44, .B44A}) {
		image := Exr_Test_Image {
			width       = 64,
			height      = 40,
			channels    = {"R", "G", "B", "A"},
			type        = .FLOAT,
			compression = compression,
			half_alpha  = true,
		}
		write_test_exr(t, path, image)
		expect_exr_pixels(t, path, image, 0.002)
	}
}

@(test)
exr_tiles_and_windows_put_each_pixel_in_place :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	path := fmt.tprintf("%s/content/image.exr", tree.dir)
	rgba := []string{"R", "G", "B", "A"}
	// 37x21 leaves narrow tiles at the right and the bottom, and PIZ compresses each tile on its own.
	for image in ([]Exr_Test_Image {
			{width = 37, height = 21, channels = rgba, type = .HALF, compression = .PIZ, tile = 8},
			{width = 37, height = 21, channels = rgba, type = .FLOAT, compression = .ZIP, tile = 8, mips = true},
			{width = 37, height = 21, channels = rgba, type = .FLOAT, compression = .ZIP, origin = {-5, 300}},
			{width = 37, height = 21, channels = rgba, type = .FLOAT, compression = .NONE, tile = 8, origin = {7, -11}},
		}) {
		write_test_exr(t, path, image)
		expect_exr_pixels(t, path, image, 0.002)
	}
}

// The Intel sample's palm_bark_rough_4k.exr is a single half channel named Y.
@(test)
exr_single_channels_are_gray :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	path := fmt.tprintf("%s/content/rough.exr", tree.dir)
	write_test_exr(t, path, {width = 32, height = 16, channels = {"Y"}, type = .HALF, compression = .ZIP})
	testing.expect_value(t, image_undecodable(path), "")
	width, height, pixels, err := decode_exr(read_test_file(t, path))
	testing.expect_value(t, err, "")
	if err == "" {
		testing.expect_value(t, width, 32)
		testing.expect_value(t, height, 16)
		for y in 0 ..< 16 {
			for x in 0 ..< 32 {
				v := exr_test_value("Y", x, y)
				testing.expect_value(t, pixels[y * 32 + x], [4]f32{v, v, v, 1})
			}
		}
	}
}

@(test)
exr_other_channels_are_ignored :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	path := fmt.tprintf("%s/content/image.exr", tree.dir)
	image := Exr_Test_Image {
		width       = 16,
		height      = 8,
		channels    = {"A", "B", "G", "R", "Z", "diffuse.R"},
		type        = .FLOAT,
		compression = .ZIP,
	}
	write_test_exr(t, path, image)
	expect_exr_pixels(t, path, image, 0)
}

// Each layout that a texture cannot hold says what is wrong with the file, from the pixels' decoder, from a stage's
// check of the header, and from a cook.
@(test)
exr_other_layouts_are_problems_with_the_file :: proc(t: ^testing.T) {
	Case :: struct {
		image: Exr_Test_Image,
		why:   string,
	}
	cases := []Case {
		{{width = 8, height = 8, channels = {"R", "G", "B"}, type = .UINT, compression = .ZIP}, "unsigned integers"},
		{{width = 8, height = 8, channels = {"R", "G"}, type = .FLOAT, compression = .ZIP}, "no R, G and B channels, only G, R"},
		{{width = 8, height = 8, channels = {"diffuse.B", "diffuse.G", "diffuse.R"}, type = .FLOAT, compression = .ZIP}, "only diffuse.B, diffuse.G, diffuse.R"},
		{{width = 8, height = 8, channels = {"R", "G", "B"}, type = .FLOAT, compression = .NONE, sampling = 2}, "subsampled"},
	}
	for test in cases {
		tree := exr_test_tree(t)
		defer remove_tree(tree)
		path := fmt.tprintf("%s/content/image.exr", tree.dir)
		write_test_exr(t, path, test.image)

		testing.expectf(t, strings.contains(image_undecodable(path), test.why), "the header's problem is %q, not %q", image_undecodable(path), test.why)
		_, _, _, err := decode_exr(read_test_file(t, path))
		testing.expectf(t, strings.contains(err, test.why), "decoding's problem is %q, not %q", err, test.why)

		errors: Errors
		logger := context.logger
		context.logger = capture_errors(&errors)
		testing.expect(t, !cook(tree_options(tree), {.Texture}).ok)
		expect_error(t, &errors, "image.exr: cannot decode")
		expect_error(t, &errors, test.why)
		context.logger = logger
		release_errors(&errors)
	}
}

// A file cut among its pixels is an error, not an image with holes: chunk reconstruction would otherwise accept it until
// it read the missing chunks.
@(test)
exr_damaged_files_are_errors :: proc(t: ^testing.T) {
	tree := exr_test_tree(t)
	defer remove_tree(tree)
	path := fmt.tprintf("%s/content/image.exr", tree.dir)
	write_test_exr(t, path, {width = 64, height = 64, channels = {"R", "G", "B"}, type = .FLOAT, compression = .NONE})
	data := read_test_file(t, path)
	_, _, _, whole := decode_exr(data)
	testing.expect_value(t, whole, "")

	_, _, _, cut := decode_exr(data[:len(data) * 3 / 4])
	testing.expect(t, cut != "")

	testing.expect(t, image_undecodable(fmt.tprintf("%s/content/missing.exr", tree.dir)) != "")
	garbage := fmt.tprintf("%s/content/garbage.exr", tree.dir)
	_ = os.write_entire_file(garbage, transmute([]byte)string("not an OpenEXR file"))
	testing.expect(t, image_undecodable(garbage) != "")
}

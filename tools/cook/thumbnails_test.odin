package cook

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"
import stbi "vendor:stb/image"

@(private = "file")
asset_at :: proc(index: ^Index, path: string) -> (entry: cook_link.Asset, found: bool) {
	for _, a in index.assets {
		if a.path == path {
			return a, true
		}
	}
	return
}

// Blobs' keys by GUID, for the keys of thumbnails with no blobs on disk.
@(private = "file")
fake_keys :: proc(sources: map[string]^Asset_Source, blobs: ^map[string]u64) -> Thumbnail_Keys {
	return {
		sources = sources,
		data = blobs,
		blob_key = proc(data: rawptr, guid: string) -> u64 {
			return (^map[string]u64)(data)[guid]
		},
		memo = make(map[string]u64, context.temp_allocator),
		blobs = make(map[string]u64, context.temp_allocator),
	}
}

@(private = "file")
guid_of :: proc(text: string) -> format.Guid {
	guid, _ := format.guid_parse(text)
	return guid
}

@(test)
a_texture_change_changes_its_materials_thumbnail_key :: proc(t: ^testing.T) {
	texture := "11111111111111111111111111111111"
	material := "22222222222222222222222222222222"
	instance := "33333333333333333333333333333333"
	blobs := make(map[string]u64, context.temp_allocator)
	blobs[texture], blobs[material], blobs[instance] = 1, 2, 3
	m := Asset_Source{kind = .Material, dependencies = make([dynamic]format.Guid, context.temp_allocator)}
	append(&m.dependencies, guid_of(texture))
	i := Asset_Source{kind = .Material_Instance, dependencies = make([dynamic]format.Guid, context.temp_allocator)}
	append(&i.dependencies, guid_of(material))
	sources := make(map[string]^Asset_Source, context.temp_allocator)
	sources[material], sources[instance] = &m, &i

	keys := fake_keys(sources, &blobs)
	before_material, before_instance := thumbnail_key(&keys, material), thumbnail_key(&keys, instance)

	// The texture's new blob reaches the material and the instance of it.
	blobs[texture] = 9
	keys = fake_keys(sources, &blobs)
	testing.expect(t, thumbnail_key(&keys, material) != before_material)
	testing.expect(t, thumbnail_key(&keys, instance) != before_instance)

	// With nothing changed, the keys are the same.
	blobs[texture] = 1
	keys = fake_keys(sources, &blobs)
	testing.expect_value(t, thumbnail_key(&keys, material), before_material)
}

@(test)
a_mesh_change_changes_its_prefabs_key :: proc(t: ^testing.T) {
	mesh := "44444444444444444444444444444444"
	script := "55555555555555555555555555555555"
	prefab := "66666666666666666666666666666666"
	blobs := make(map[string]u64, context.temp_allocator)
	blobs[mesh], blobs[script], blobs[prefab] = 1, 2, 3
	p := Asset_Source {
		kind         = .Prefab,
		dependencies = make([dynamic]format.Guid, context.temp_allocator),
		visual       = make([dynamic]format.Guid, context.temp_allocator),
	}
	append(&p.dependencies, guid_of(script))
	append(&p.visual, guid_of(mesh))
	sources := make(map[string]^Asset_Source, context.temp_allocator)
	sources[prefab] = &p

	keys := fake_keys(sources, &blobs)
	before := thumbnail_key(&keys, prefab)

	blobs[mesh] = 9
	keys = fake_keys(sources, &blobs)
	changed := thumbnail_key(&keys, prefab)
	testing.expect(t, changed != before)

	// A prefab's script does not change how it looks.
	blobs[script] = 9
	keys = fake_keys(sources, &blobs)
	testing.expect_value(t, thumbnail_key(&keys, prefab), changed)
}

@(test)
a_thumbnail_key_survives_a_cycle :: proc(t: ^testing.T) {
	a, b := "77777777777777777777777777777777", "88888888888888888888888888888888"
	blobs := make(map[string]u64, context.temp_allocator)
	blobs[a], blobs[b] = 1, 2
	sa := Asset_Source{kind = .Material, dependencies = make([dynamic]format.Guid, context.temp_allocator)}
	sb := Asset_Source{kind = .Material, dependencies = make([dynamic]format.Guid, context.temp_allocator)}
	append(&sa.dependencies, guid_of(b))
	append(&sb.dependencies, guid_of(a))
	sources := make(map[string]^Asset_Source, context.temp_allocator)
	sources[a], sources[b] = &sa, &sb
	keys := fake_keys(sources, &blobs)
	testing.expect(t, thumbnail_key(&keys, a) != 0)
}

@(test)
a_large_picture_fits_and_keeps_its_shape :: proc(t: ^testing.T) {
	pixels := make([]u8, 1024 * 512 * 4, context.temp_allocator)
	// White on the left half, black on the right.
	for y in 0 ..< 512 {
		for x in 0 ..< 512 {
			at := (y * 1024 + x) * 4
			pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3] = 255, 255, 255, 255
		}
	}
	fitted, size := fit_thumbnail(pixels, {1024, 512}, context.temp_allocator)
	testing.expect_value(t, size, [2]int{THUMBNAIL_SIZE, THUMBNAIL_SIZE / 2})
	testing.expect_value(t, fitted[0], 255)
	testing.expect_value(t, fitted[(size.x - 1) * 4], 0)

	// What is small enough stays as it is.
	small := []u8{1, 2, 3, 4}
	same, same_size := fit_thumbnail(small, {1, 1}, context.temp_allocator)
	testing.expect_value(t, same_size, [2]int{1, 1})
	testing.expect_value(t, same[3], 4)
}

@(test)
a_waveform_shows_where_the_sound_is :: proc(t: ^testing.T) {
	// Silent for its first half, then full scale, in two channels.
	samples := make([]i16, 2000, context.temp_allocator)
	for i in 1000 ..< 2000 {
		samples[i] = i % 2 == 0 ? 32767 : -32768
	}
	pixels, size, ok := waveform_thumbnail(samples, 2, context.temp_allocator)
	testing.expect(t, ok)
	covered :: proc(pixels: []u8, size: [2]int, x: int) -> (count: int) {
		for y in 0 ..< size.y {
			count += int(pixels[(y * size.x + x) * 4 + 3] != 0)
		}
		return
	}
	testing.expect(t, covered(pixels, size, 10) <= 3)
	testing.expect_value(t, covered(pixels, size, size.x - 10), size.y)

	_, _, no_channels := waveform_thumbnail(samples, 0, context.temp_allocator)
	testing.expect(t, !no_channels)
}

@(test)
a_png_reads_back :: proc(t: ^testing.T) {
	pixels := []u8{10, 20, 30, 255, 40, 50, 60, 128}
	data := png_encode(pixels, {2, 1}, context.temp_allocator)
	width, height, channels: c.int
	read := stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
	defer stbi.image_free(read)
	testing.expect_value(t, width, 2)
	testing.expect_value(t, height, 1)
	testing.expect_value(t, read[0], 10)
	testing.expect_value(t, read[7], 128)
}

// A 2x2 PNG: red, green, blue and white.
@(private = "file")
PNG_2X2 := #load("testdata/2x2.png", string)

// A part of a prefab has a file with its prefab's name and more, which no index entry names: it goes when its prefab's does.
@(test)
a_parts_picture_goes_with_its_prefabs :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.png", PNG_2X2}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, ALL_KINDS, log_problems = false)
	index: Index
	index_build(&index, pass, options.roots[:])
	defer index_destroy(&index)
	thumbnails_update(&index, &pass, options)
	entry, found := asset_at(&index, "a.png")
	testing.expect(t, found)
	stem := strings.trim_suffix(entry.thumbnail, ".png")
	part := fmt.tprintf("%s.e7e4b781f0a1effe.png", stem)
	testing.expect(t, os.write_entire_file(part, transmute([]byte)string("part")) == nil)
	dir := fmt.tprintf("%s/thumbnails", options.cache)
	other := fmt.tprintf("%s/00000000000000000000000000000000.1111111111111111.e7e4b781f0a1effe.png", dir)
	testing.expect(t, os.write_entire_file(other, transmute([]byte)string("old")) == nil)

	thumbnails_update(&index, &pass, options)

	testing.expect(t, os.exists(part))
	testing.expect(t, !os.exists(other))
}

@(test)
a_stale_thumbnail_is_pruned :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/a.png", PNG_2X2}, {"content/b.luau", "return 1"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, ALL_KINDS, log_problems = false)
	index: Index
	index_build(&index, pass, options.roots[:])
	defer index_destroy(&index)
	dir := fmt.tprintf("%s/thumbnails", options.cache)
	os.make_directory_all(dir)
	stale := fmt.tprintf("%s/00000000000000000000000000000000.1111111111111111.png", dir)
	testing.expect(t, os.write_entire_file(stale, transmute([]byte)string("old")) == nil)

	thumbnails_update(&index, &pass, options)

	testing.expect(t, !os.exists(stale))
	entry, found := asset_at(&index, "a.png")
	testing.expect(t, found)
	testing.expect(t, entry.thumbnail_ready)
	testing.expect(t, strings.has_prefix(entry.thumbnail, dir))
	testing.expect(t, strings.has_suffix(entry.thumbnail, ".png"))
	testing.expect(t, os.exists(entry.thumbnail))
	// A script has none.
	script, _ := asset_at(&index, "b.luau")
	testing.expect_value(t, script.thumbnail, "")

	// A second pass over the same blob keeps the same file.
	path := strings.clone(entry.thumbnail, context.temp_allocator)
	next: Index
	index_build(&next, pass, options.roots[:])
	defer index_destroy(&next)
	thumbnails_update(&next, &pass, options)
	again, _ := asset_at(&next, "a.png")
	testing.expect_value(t, again.thumbnail, path)
	testing.expect(t, again.thumbnail_ready)
}

@(test)
a_thumbnail_that_needs_the_renderer_waits_for_it :: proc(t: ^testing.T) {
	entry_kind := cook_link.Asset_Kind.Material
	testing.expect(t, thumbnail_kind(entry_kind))
	testing.expect(t, thumbnail_kind(.Prefab))
	testing.expect(t, thumbnail_kind(.Mesh))
	testing.expect(t, !thumbnail_kind(.Script))
	testing.expect(t, !thumbnail_kind(.Stage))
}

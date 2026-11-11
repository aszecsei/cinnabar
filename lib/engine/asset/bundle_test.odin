package asset

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

import "cinnabar:core/lz4"
import format "cinnabar:engine/asset/format"

// script_blob is a script blob of a GUID, which a bundle can hold.
@(private = "file")
script_blob :: proc(guid: format.Guid, key: u64) -> []byte {
	return format.script_write({guid = guid, key = key, bytecode = {1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8}, source_path = "x.luau"}, context.temp_allocator)
}

// stored is a blob as a bundle stores it, compressed or not.
@(private = "file")
stored :: proc(blob: []byte, guid: format.Guid, compress: bool) -> format.Bundle_Blob {
	if !compress {
		return {guid = guid, kind = .Script, codec = .None, size = u32(len(blob)), stored = blob}
	}
	block := lz4.compress(blob, make([]byte, lz4.bound(len(blob)), context.temp_allocator))
	return {guid = guid, kind = .Script, codec = .Lz4, size = u32(len(blob)), stored = block}
}

@(private = "file")
write_bundle :: proc(t: ^testing.T, f: ^Fixture, name: string, blobs: []format.Bundle_Blob, dependencies: []string) -> string {
	path := fmt.tprintf("%s/%s%s", f.dir, name, format.BUNDLE_EXTENSION)
	testing.expect(t, os.write_entire_file(path, format.bundle_write(blobs, dependencies, context.temp_allocator)) == nil)
	return path
}

@(private = "file")
level_name :: proc(guid: format.Guid) -> string {
	buffer := new([32]u8, context.temp_allocator)
	return format.guid_format(guid, buffer)
}

@(private = "file")
open_names :: proc(f: ^Fixture) -> []string {
	source := &f.assets.source.(Bundle)
	names := make([]string, source.count, context.temp_allocator)
	for &b, i in source.open[:source.count] {
		names[i] = string(b.name[:b.name_len])
	}
	return names
}

@(test)
bundles_open_after_what_they_depend_on_and_load_by_guid :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	context.logger = capture_errors(f)
	shared, level, in_level := test_guid(1), test_guid(2), test_guid(3)
	write_bundle(t, f, format.GLOBAL_BUNDLE, {stored(script_blob(shared, 1), shared, false)}, nil)
	// The level depends on a bundle that depends on the global one.
	extra := test_guid(4)
	write_bundle(t, f, "extra", {stored(script_blob(extra, 4), extra, true)}, {format.GLOBAL_BUNDLE})
	write_bundle(t, f, level_name(level), {stored(script_blob(level, 2), level, true), stored(script_blob(in_level, 3), in_level, true)}, {"extra"})
	destroy(&f.assets)
	init(&f.assets, &f.platform, bundle(f.dir))
	testing.expect(t, slice.equal(open_names(f), []string{format.GLOBAL_BUNDLE}))

	h, ok := load(&f.assets, shared)
	testing.expect(t, ok)
	testing.expect_value(t, blob_key(f, h), 1)
	// Nothing open has a level's asset until its scene loads, which opens the level's bundle after its dependencies.
	_, ok = load(&f.assets, in_level)
	testing.expect(t, !ok)
	testing.expect_value(t, len(f.errors), 1)
	h, ok = load(&f.assets, level)
	testing.expect(t, ok)
	testing.expect_value(t, blob_key(f, h), 2)
	testing.expect(t, slice.equal(open_names(f), []string{format.GLOBAL_BUNDLE, "extra", level_name(level)}))
	h, ok = load(&f.assets, in_level)
	testing.expect(t, ok)
	blob, _ := data(&f.assets, h)
	testing.expect(t, slice.equal(blob, script_blob(in_level, 3)))

	// Bundles do not change, so there is nothing to poll, and they are current.
	testing.expect(t, poll(&f.assets) == nil)
	testing.expect(t, current(&f.assets))
}

@(test)
a_blob_stored_as_it_is_is_read_at_its_offset :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	raw, packed := test_guid(1), test_guid(2)
	path := write_bundle(t, f, format.GLOBAL_BUNDLE, {stored(script_blob(raw, 1), raw, false), stored(script_blob(packed, 2), packed, true)}, nil)
	destroy(&f.assets)
	init(&f.assets, &f.platform, bundle(f.dir))

	location, ok := blob_location(&f.assets, raw)
	testing.expect(t, ok && location.raw)
	testing.expect_value(t, location.path, path)
	want := script_blob(raw, 1)
	got := make([]byte, len(want), context.temp_allocator)
	testing.expect_value(t, f.platform.file_read_range(location.path, location.offset, got), len(want))
	testing.expect(t, slice.equal(got, want))
	location, ok = blob_location(&f.assets, packed)
	testing.expect(t, ok && !location.raw)
	_, ok = blob_location(&f.assets, test_guid(3))
	testing.expect(t, !ok)

	// read gives a compressed blob whole, without loading it.
	blob, _, read_ok := read(&f.assets, packed)
	testing.expect(t, read_ok)
	testing.expect(t, slice.equal(blob, script_blob(packed, 2)))
	delete(blob, f.platform.asset_allocator)
}

// A bundle of a script, a texture, a mesh and a paged mesh: each loads by its GUID as the blob that was packed, but the
// paged mesh, which the bundle stores as it is, loads its head, and its pages are read from the bundle at its offset.
@(test)
a_bundle_loads_every_asset_in_it_by_guid :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	script_guid, texture_guid, mesh_guid, paged_guid := test_guid(1), test_guid(2), test_guid(3), test_guid(4)
	texture := format.texture_write({guid = texture_guid, key = 2, format = .RGBA8_Unorm, usage = .Color, size = {4, 4}, mip_count = 1, mips = make([]byte, 64, context.temp_allocator), source_path = "game/t.png"}, context.temp_allocator)
	mesh := format.mesh_write({guid = mesh_guid, key = 3, vertex_count = 3, index_count = 3, submeshes = {{name = "s"}}, positions = make([]byte, 36, context.temp_allocator), indices = {0, 0, 1, 0, 2, 0}, name = "m", source_path = "game/m.mesh"}, context.temp_allocator)
	stream := make([]byte, 4096, context.temp_allocator)
	for &b, i in stream {
		b = u8(i)
	}
	paged := format.mesh_write(
		{
			guid = paged_guid,
			key = 4,
			flags = {.Paged},
			vertex_count = 3,
			index_count = 3,
			meshlet_count = 2,
			submeshes = {{name = "s", meshlet_count = 2}},
			pages = {
				{record = {size = 64, meshlet_count = 1, level0_meshlets = 1, vertex_count = 3}, compressed = stream, dependencies = {1}},
				{record = {size = 64, first_meshlet = 1, meshlet_count = 1, flags = {.Root}}, compressed = make([]byte, 48, context.temp_allocator)},
			},
		},
		context.temp_allocator,
	)
	packed := []format.Bundle_Blob {
		stored(script_blob(script_guid, 1), script_guid, true),
		stored(texture, texture_guid, true),
		stored(mesh, mesh_guid, true),
		{guid = paged_guid, kind = .Mesh, codec = .None, size = u32(len(paged)), stored = paged},
	}
	packed[1].kind, packed[2].kind = .Texture, .Mesh
	write_bundle(t, f, format.GLOBAL_BUNDLE, packed, nil)
	destroy(&f.assets)
	init(&f.assets, &f.platform, bundle(f.dir))

	wants := [][]byte{script_blob(script_guid, 1), texture, mesh}
	for guid, i in ([]format.Guid{script_guid, texture_guid, mesh_guid}) {
		h, ok := load(&f.assets, guid)
		testing.expectf(t, ok, "blob %d does not load", i)
		blob, _ := data(&f.assets, h)
		testing.expectf(t, slice.equal(blob, wants[i]), "blob %d is not the blob that was packed", i)
	}
	_, texture_ok := format.texture_view(wants[1])
	testing.expect(t, texture_ok, "the test's texture is a texture blob")

	h, ok := load(&f.assets, paged_guid)
	testing.expect(t, ok)
	head, _ := data(&f.assets, h)
	view, view_ok := format.mesh_view(head)
	testing.expect(t, view_ok, "the head alone is a mesh blob")
	if !view_ok {
		return
	}
	testing.expect_value(t, len(head), int(view.head_size))
	location, found := blob_location(&f.assets, paged_guid)
	testing.expect(t, found && location.raw)
	page := format.mesh_pages(head, view)[0]
	got := make([]byte, page.compressed_size, context.temp_allocator)
	testing.expect_value(t, f.platform.file_read_range(location.path, location.offset + i64(page.offset), got), len(got))
	testing.expect(t, slice.equal(got, stream))
	testing.expect_value(t, modified(&f.assets, h), f.platform.file_modified(location.path))
}

@(test)
a_bundle_cut_short_is_refused :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	context.logger = capture_errors(f)
	write_bundle(t, f, format.GLOBAL_BUNDLE, nil, nil)
	level := test_guid(1)
	path := write_bundle(t, f, level_name(level), {stored(script_blob(level, 1), level, false)}, {format.GLOBAL_BUNDLE})
	whole, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, whole[:len(whole) - 1]) == nil)
	destroy(&f.assets)
	init(&f.assets, &f.platform, bundle(f.dir))

	_, ok := load(&f.assets, level)
	testing.expect(t, !ok)
	testing.expect(t, slice.equal(open_names(f), []string{format.GLOBAL_BUNDLE}))
	testing.expect(t, len(f.errors) >= 1)

	// A bundle of another layout is refused too.
	whole[8] ~= 1
	testing.expect(t, os.write_entire_file(path, whole) == nil)
	_, ok = load(&f.assets, level)
	testing.expect(t, !ok)
}

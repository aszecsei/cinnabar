package asset_format

import "core:slice"
import "core:testing"

@(test)
guids_order_by_their_bytes :: proc(t: ^testing.T) {
	a, b, c := Guid{0 = 1}, Guid{0 = 1, 15 = 2}, Guid{0 = 2}
	testing.expect_value(t, guid_compare(a, b), slice.Ordering.Less)
	testing.expect_value(t, guid_compare(c, b), slice.Ordering.Greater)
	testing.expect_value(t, guid_compare(b, b), slice.Ordering.Equal)
	testing.expect(t, guid_less(a, c) && !guid_less(c, a))
}

@(test)
bundles_round_trip_sorted_by_guid :: proc(t: ^testing.T) {
	first, second := Guid{0 = 9}, Guid{0 = 3}
	blobs := []Bundle_Blob {
		{guid = first, kind = .Texture, codec = .Lz4, size = 100, stored = {1, 2, 3}},
		{guid = second, kind = .Script, codec = .None, size = 5, stored = {4, 5, 6, 7, 8}},
	}
	data := aligned(bundle_write(blobs, {GLOBAL_BUNDLE}, context.temp_allocator))
	head := data[:bundle_head_size(data)]
	header, entries, ok := bundle_view(head, i64(len(data)))
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].guid, second)
	testing.expect_value(t, entries[1].guid, first)
	testing.expect_value(t, bundle_dependency_count(header), 1)
	testing.expect_value(t, bundle_dependency(head, header, 0), GLOBAL_BUNDLE)
	for e in entries {
		testing.expect_value(t, e.offset % BLOB_ALIGN, 0)
	}
	entry, found := bundle_find(entries, first)
	testing.expect(t, found)
	testing.expect_value(t, entry.codec, Bundle_Codec.Lz4)
	testing.expect_value(t, entry.size, 100)
	testing.expect(t, slice.equal(data[entry.offset:][:entry.stored_size], []byte{1, 2, 3}))
	_, found = bundle_find(entries, Guid{0 = 5})
	testing.expect(t, !found)

	// A file shorter or longer than its header says is refused, as is a head of another layout.
	_, _, ok = bundle_view(head, i64(len(data)) - 1)
	testing.expect(t, !ok)
	(^Bundle_Header)(raw_data(head)).layout += 1
	testing.expect_value(t, bundle_head_size(head), 0)
	_, _, ok = bundle_view(head, i64(len(data)))
	testing.expect(t, !ok)
}

@(test)
the_global_scenes_are_guids_between_commas :: proc(t: ^testing.T) {
	scenes, ok := bundle_parse_scenes(" 00112233445566778899aabbccddeeff ,ffeeddccbbaa99887766554433221100", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(scenes), 2)
	testing.expect_value(t, scenes[1][0], 0xff)
	scenes, ok = bundle_parse_scenes("  ", context.temp_allocator)
	testing.expect(t, ok && len(scenes) == 0)
	_, ok = bundle_parse_scenes("00112233445566778899aabbccddeeff,", context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
blobs_name_the_assets_that_they_use :: proc(t: ^testing.T) {
	texture, material, script, required := Guid{0 = 1}, Guid{0 = 2}, Guid{0 = 3}, Guid{0 = 4}

	scene_text := "scene 1\nentity 0000000000000001\ncomponent 1 T\n\tmesh = $02000000000000000000000000000000\n\tnone = $0\n" +
		"behaviour 03000000000000000000000000000000\n\ttarget = $01000000000000000000000000000000\n"
	scene, _, parsed := scene_parse(scene_text, context.temp_allocator)
	testing.expect(t, parsed)
	references, ok := blob_references(aligned(scene_write(scene, {}, 0, allocator = context.temp_allocator)), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(references, []Guid{material, script, texture}))

	textures := []Material_Texture{{offset = 0, guid = texture}, {offset = 4, guid = texture}, {offset = 8}}
	instance := aligned(material_instance_write({guid = Guid{0 = 9}, material = material, block = make([]byte, 16, context.temp_allocator), textures = textures, source_path = "game/a.material_instance"}, context.temp_allocator))
	references, ok = blob_references(instance, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(references, []Guid{material, texture}))

	requires := []Require_Entry{{"./a", required}, {"./b", required}}
	references, ok = blob_references(aligned(script_write({guid = script, requires = requires, source_path = "game/x.luau"}, context.temp_allocator)), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(references, []Guid{required}))

	font := aligned(font_write({guid = Guid{0 = 8}, atlas = texture, atlas_size = {1, 1}, units_per_em = 1000, em_size = 1, range = 1, source_path = "game/f.ttf"}, context.temp_allocator))
	references, ok = blob_references(font, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(references, []Guid{texture}))

	// A blob of a kind that names nothing names nothing, and a blob that does not check fails.
	references, ok = blob_references(aligned(texture_write({guid = texture, format = .RGBA8_Unorm, usage = .Color, size = {1, 1}, mip_count = 1, mips = {0, 0, 0, 0}}, context.temp_allocator)), context.temp_allocator)
	testing.expect(t, ok && len(references) == 0)
	_, ok = blob_references(aligned([]byte{1, 2, 3, 4}), context.temp_allocator)
	testing.expect(t, !ok)
}

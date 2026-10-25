package asset_format

import "core:mem"
import "core:testing"

TEST_GUID :: "00112233445566778899aabbccddeeff"

@(test)
guids_round_trip_through_text :: proc(t: ^testing.T) {
	guid, ok := guid_parse(TEST_GUID)
	testing.expect(t, ok)
	testing.expect_value(t, guid[0], 0x00)
	testing.expect_value(t, guid[15], 0xff)
	buffer: [32]u8
	testing.expect_value(t, guid_format(guid, &buffer), TEST_GUID)
	_, ok = guid_parse("0011")
	testing.expect(t, !ok)
	_, ok = guid_parse("0g112233445566778899aabbccddeeff")
	testing.expect(t, !ok)
}

@(test)
meta_files_hold_a_guid_and_settings :: proc(t: ^testing.T) {
	meta, ok := meta_parse("# a comment\nguid = " + TEST_GUID + "\r\nnative = true\n\n", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, meta.guid, guid_parse(TEST_GUID) or_else {})
	native, found := meta_value(meta, "native")
	testing.expect(t, found)
	testing.expect_value(t, native, "true")
	_, ok = meta_parse("native = true\n", context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = meta_parse("guid " + TEST_GUID + "\n", context.temp_allocator)
	testing.expect(t, !ok)
}

// aligned copies a blob into memory at the runtime's alignment, as the asset runtime loads it.
@(private)
aligned :: proc(data: []byte) -> []byte {
	result, _ := mem.alloc_bytes(len(data), BLOB_ALIGN, context.temp_allocator)
	copy(result, data)
	return result
}

@(test)
script_blobs_round_trip :: proc(t: ^testing.T) {
	a := guid_parse(TEST_GUID) or_else {}
	b := a
	b[0] = 1
	requires := []Require_Entry{{"./a", a}, {"./b", b}, {"@game/c", a}}
	data := aligned(script_write({guid = a, key = 42, flags = {.Native}, bytecode = {1, 2, 3}, requires = requires, source_path = "game/x.luau"}, context.temp_allocator))

	blob, ok := script_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.guid, a)
	testing.expect_value(t, blob.header.key, 42)
	testing.expect_value(t, blob.flags, Script_Flags{.Native})
	testing.expect_value(t, len(blob_bytes(data, blob.bytecode)), 3)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/x.luau")
	for r in requires {
		target, found := script_find_require(data, blob, r.path)
		testing.expect(t, found)
		testing.expect_value(t, target, r.target)
	}
	_, found := script_find_require(data, blob, "./missing")
	testing.expect(t, !found)
}

@(test)
script_view_rejects_bad_blobs :: proc(t: ^testing.T) {
	data := aligned(script_write({bytecode = {1, 2, 3}, source_path = "x.luau"}, context.temp_allocator))
	_, ok := script_view(data[:size_of(Script_Blob) - 1])
	testing.expect(t, !ok)

	(^Script_Blob)(raw_data(data)).bytecode.size = 1 << 20
	_, ok = script_view(data)
	testing.expect(t, !ok)

	other := aligned(script_write({}, context.temp_allocator))
	(^Script_Blob)(raw_data(other)).header.layout += 1
	_, ok = script_view(other)
	testing.expect(t, !ok)
}

@(test)
shader_blobs_round_trip :: proc(t: ^testing.T) {
	guid := guid_parse(TEST_GUID) or_else {}
	entries := []Shader_Code{{.Vertex, .DXIL, {1, 2, 3}}, {.Pixel, .DXIL, {4, 5}}}
	data := aligned(shader_write({guid = guid, key = 7, entries = entries, source_path = "game/x.hlsl"}, context.temp_allocator))

	blob, ok := shader_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.header.guid, guid)
	testing.expect_value(t, blob.header.key, 7)
	testing.expect_value(t, shader_stages(data, blob), Shader_Stages{.Vertex, .Pixel})
	testing.expect_value(t, len(shader_code(data, blob, .Vertex)), 3)
	testing.expect_value(t, shader_code(data, blob, .Pixel)[1], 5)
	testing.expect(t, shader_code(data, blob, .Compute) == nil)
	for e in shader_entries(data, blob) {
		testing.expect_value(t, e.code.offset % BLOB_ALIGN, 0)
	}
	testing.expect_value(t, blob_string(data, blob.source_path), "game/x.hlsl")

	(^Shader_Blob)(raw_data(data)).entries.size = 1 << 20
	_, ok = shader_view(data)
	testing.expect(t, !ok)
}

@(test)
texture_blobs_round_trip :: proc(t: ^testing.T) {
	guid := guid_parse(TEST_GUID) or_else {}
	// 8x4 BC7: two blocks, then 4x2 and 2x1 at one block each.
	mips := make([]byte, texture_chain_size(.BC7_Unorm_Srgb, {8, 4}, 3), context.temp_allocator)
	testing.expect_value(t, len(mips), (2 + 1 + 1) * 16)
	mips[0] = 9
	contents := Texture_Contents{guid = guid, key = 3, format = .BC7_Unorm_Srgb, usage = .Color, size = {8, 4}, mip_count = 3, mips = mips, source_path = "game/a.png"}
	data := aligned(texture_write(contents, context.temp_allocator))

	blob, ok := texture_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.size, [2]u32{8, 4})
	testing.expect_value(t, blob.mips.offset % BLOB_ALIGN, 0)
	testing.expect_value(t, blob_bytes(data, blob.mips)[0], 9)
	testing.expect_value(t, blob_string(data, blob.source_path), "game/a.png")
	testing.expect_value(t, texture_mip_size(.RGBA8_Unorm, 3, 2), 24)

	// Mips of the wrong size are not a texture.
	(^Texture_Blob)(raw_data(data)).mip_count = 2
	_, ok = texture_view(data)
	testing.expect(t, !ok)
}

@(test)
meta_files_name_their_subassets :: proc(t: ^testing.T) {
	other :: "ffeeddccbbaa99887766554433221100"
	meta, ok := meta_parse("guid = " + TEST_GUID + "\ncombine = false\nmesh.Door Frame = " + other + "\n", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(meta.settings), 1)
	testing.expect_value(t, len(meta.subassets), 1)
	guid, found := meta_subasset(meta, "mesh", "Door Frame")
	testing.expect(t, found)
	testing.expect_value(t, guid, guid_parse(other) or_else {})
	_, found = meta_subasset(meta, "texture", "Door Frame")
	testing.expect(t, !found)
	// A sub-asset's value must be a GUID.
	_, ok = meta_parse("guid = " + TEST_GUID + "\nmesh.door = 12\n", context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
mesh_blobs_round_trip :: proc(t: ^testing.T) {
	guid := guid_parse(TEST_GUID) or_else {}
	positions := make([]byte, 3 * 12, context.temp_allocator)
	attributes := make([]byte, 3 * int(mesh_attribute_stride({.Color})), context.temp_allocator)
	indices := []u16{0, 1, 2}
	meshlets := []Meshlet{{vertex_count = 3, triangle_count = 1, radius = 1}}
	contents := Mesh_Contents {
		guid              = guid,
		key               = 5,
		flags             = {.Color},
		vertex_count      = 3,
		index_count       = 3,
		submeshes         = {{name = "stone", index_count = 3, meshlet_count = 1}},
		positions         = positions,
		attributes        = attributes,
		indices           = mem.slice_to_bytes(indices),
		meshlets          = meshlets,
		meshlet_vertices  = mem.slice_to_bytes([]u32{0, 1, 2}),
		meshlet_triangles = {0, 1, 2},
		name              = "Door",
		source_path       = "game/door.glb",
	}
	data := aligned(mesh_write(contents, context.temp_allocator))
	blob, ok := mesh_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, mesh_attribute_stride(blob.flags), 20)
	testing.expect_value(t, blob.positions.offset % BLOB_ALIGN, 0)
	testing.expect_value(t, blob.attributes.offset % BLOB_ALIGN, 0)
	submeshes := mesh_submeshes(data, blob)
	testing.expect_value(t, len(submeshes), 1)
	testing.expect_value(t, blob_string(data, submeshes[0].name), "stone")
	testing.expect_value(t, mesh_meshlets(data, blob)[0].triangle_count, 1)
	testing.expect_value(t, blob_string(data, blob.name), "Door")

	// A submesh past the mesh's indices is not a mesh.
	(^Mesh_Submesh)(&data[blob.submeshes.offset]).index_count = 6
	_, ok = mesh_view(data)
	testing.expect(t, !ok)
}

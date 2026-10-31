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
		submeshes         = {{name = "stone", index_count = 3, meshlet_count = 1, node_count = 1, root_count = 1}},
		positions         = positions,
		attributes        = attributes,
		indices           = mem.slice_to_bytes(indices),
		meshlets          = meshlets,
		meshlet_vertices  = mem.slice_to_bytes([]u32{0, 1, 2}),
		meshlet_triangles = mem.slice_to_bytes([]u32{0 | 1 << 8 | 2 << 16}),
		meshlet_nodes     = []Meshlet_Node{{radius = 1, count = 1 | MESHLET_NODE_LEAF}},
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
	testing.expect_value(t, mesh_meshlet_nodes(data, blob)[0].count, 1 | MESHLET_NODE_LEAF)
	testing.expect_value(t, submeshes[0].root_count, 1)
	testing.expect_value(t, blob_string(data, blob.name), "Door")

	// A submesh past the mesh's indices is not a mesh.
	(^Mesh_Submesh)(&data[blob.submeshes.offset]).index_count = 6
	_, ok = mesh_view(data)
	testing.expect(t, !ok)
	(^Mesh_Submesh)(&data[blob.submeshes.offset]).index_count = 3

	// A leaf past its submesh's meshlets is not a mesh, so a walk of the nodes stays in the submesh.
	node := &mesh_meshlet_nodes(data, blob)[0]
	node.count = 2 | MESHLET_NODE_LEAF
	_, ok = mesh_view(data)
	testing.expect(t, !ok)
	node.count = 1 | MESHLET_NODE_LEAF

	// Meshlet triangles are whole u32s, which shaders load.
	blob.meshlet_triangles.size = 3
	_, ok = mesh_view(data)
	testing.expect(t, !ok)
}

@(test)
material_blobs_round_trip :: proc(t: ^testing.T) {
	guid := guid_parse(TEST_GUID) or_else {}
	block := make([]byte, 32, context.temp_allocator)
	block[0] = 7
	textures := []Material_Texture{{offset = 16, default = .Normal}}
	contents := Material_Contents {
		guid             = guid,
		flags            = {.Two_Sided},
		blend            = .Masked,
		cutoff           = 0.5,
		displacement_bound = 0.25,
		params           = {{"tint", .Color, 0}, {"albedo", .Texture, 16}},
		switches         = {"use_detail"},
		default_switches = 1,
		block            = block,
		textures         = textures,
		variants         = {{1, .Forward, .Vertex, {1, 2}}, {1, .Forward, .Pixel, {3}}},
		source_path      = "game/rock.material",
	}
	data := aligned(material_write(contents, context.temp_allocator))
	blob, ok := material_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, blob.blend, Material_Blend.Masked)
	testing.expect_value(t, blob.displacement_bound, 0.25)
	testing.expect_value(t, blob_string(data, material_params(data, blob)[1].name), "albedo")
	testing.expect_value(t, blob_string(data, material_switches(data, blob)[0]), "use_detail")
	testing.expect_value(t, material_textures(data, blob)[0].default, Material_Texture_Default.Normal)
	testing.expect_value(t, len(material_code(data, blob, 1, .Forward, .Vertex)), 2)
	testing.expect(t, material_code(data, blob, 0, .Forward, .Vertex) == nil)
	testing.expect_value(t, blob_bytes(data, blob.block)[0], 7)

	instance := aligned(material_instance_write({guid = guid, material = guid, switches = 0, block = block, textures = textures, source_path = "game/rock_mossy.material_instance"}, context.temp_allocator))
	view, view_ok := material_instance_view(instance)
	testing.expect(t, view_ok)
	if view_ok {
		testing.expect_value(t, view.material, guid)
		testing.expect_value(t, instance_textures(instance, view)[0].offset, 16)
	}

	// A texture past the block is not a material.
	bad := textures
	bad[0].offset = 32
	contents.textures = bad
	_, ok = material_view(aligned(material_write(contents, context.temp_allocator)))
	testing.expect(t, !ok)
}

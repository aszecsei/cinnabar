package render

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/testlog"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// A fake GPU that counts buffers, and whose transfers are done only when the test says so. Each test has its own,
// in its context's user pointer, so the tests can run at the same time.
@(private = "file")
Fake_GPU :: struct {
	next_buffer:    u32,
	live_buffers:   int,
	next_transfer:  u64,
	done_through:   u64,
	// The last texture that was created, and the size of what streamed into it.
	next_texture:   u32,
	live_textures:  int,
	texture_desc:   gpu.Texture_Desc,
	streamed_bytes: int,
}

@(private = "file")
fake_gpu :: proc() -> ^Fake_GPU {
	return (^Fake_GPU)(context.user_ptr)
}

@(private = "file")
fake_platform :: proc(frame: ^virtual.Arena) -> core.Platform_API {
	return {
		frame_allocator = virtual.arena_allocator(frame),
		asset_allocator = runtime.heap_allocator(),
		heap_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		gpu_create_buffer = proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {
			fake := fake_gpu()
			fake.next_buffer += 1
			fake.live_buffers += 1
			return transmute(gpu.Buffer)[2]u32{fake.next_buffer, 1}
		},
		gpu_destroy_buffer = proc(buffer: gpu.Buffer) {
			if buffer != {} {
				fake_gpu().live_buffers -= 1
			}
		},
		gpu_stream_buffer = proc(buffer: gpu.Buffer, offset: u32, data: []byte) -> gpu.Transfer {
			assert(len(data) % 4 == 0, "a buffer stream is a multiple of 4 bytes")
			fake := fake_gpu()
			fake.next_transfer += 1
			return gpu.Transfer(fake.next_transfer)
		},
		gpu_transfer_done = proc(transfer: gpu.Transfer) -> bool {
			return u64(transfer) <= fake_gpu().done_through
		},
		gpu_create_texture = proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {
			fake := fake_gpu()
			fake.next_texture += 1
			fake.live_textures += 1
			fake.texture_desc = desc
			return transmute(gpu.Texture)[2]u32{fake.next_texture, 1}
		},
		gpu_destroy_texture = proc(texture: gpu.Texture) {
			if texture != {} {
				fake_gpu().live_textures -= 1
			}
		},
		gpu_stream_texture = proc(texture: gpu.Texture, data: []byte) -> gpu.Transfer {
			fake := fake_gpu()
			fake.streamed_bytes = len(data)
			fake.next_transfer += 1
			return gpu.Transfer(fake.next_transfer)
		},
	}
}

@(test)
resident_textures_are_created_as_their_blobs_say :: proc(t: ^testing.T) {
	fake: Fake_GPU
	context.user_ptr = &fake
	frame: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&frame) == nil)
	defer virtual.arena_destroy(&frame)
	platform := fake_platform(&frame)
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)

	write_texture :: proc(t: ^testing.T, dir: string, name: string, dimension: format.Texture_Dimension, layers: u32) -> format.Guid {
		guid := format.guid_parse(name) or_else {}
		chain := format.texture_chain_size(.BC7_Unorm_Srgb, {8, 8}, 4)
		blob := format.texture_write(
			{guid = guid, format = .BC7_Unorm_Srgb, usage = .Color, dimension = dimension, layer_count = layers, size = {8, 8}, mip_count = 4, mips = make([]byte, chain * int(layers), context.temp_allocator)},
			context.temp_allocator,
		)
		buffer: [32]u8
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)), blob) == nil)
		return guid
	}
	chain := format.texture_chain_size(.BC7_Unorm_Srgb, {8, 8}, 4)
	plain := write_texture(t, dir, "00000000000000000000000000000001", .D2, 1)
	cube := write_texture(t, dir, "00000000000000000000000000000002", .Cube, 6)
	array := write_texture(t, dir, "00000000000000000000000000000003", .D2_Array, 3)

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	// A 2D texture has no array view.
	_, ready := resident_texture(r, plain)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.texture_desc.layers, 0)
	testing.expect(t, !fake.texture_desc.cube)
	testing.expect_value(t, fake.streamed_bytes, chain)

	_, ready = resident_texture(r, cube, .Cube)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.texture_desc.layers, 6)
	testing.expect(t, fake.texture_desc.cube)
	testing.expect_value(t, fake.texture_desc.size, [2]u32{8, 8})
	testing.expect_value(t, fake.texture_desc.mip_count, 4)
	testing.expect_value(t, gpu.validate_texture_desc(fake.texture_desc, nil), gpu.Desc_Error.None)
	testing.expect_value(t, fake.streamed_bytes, chain * 6)
	testing.expect_value(t, fake.streamed_bytes, gpu.mip_chain_size(fake.texture_desc))

	_, ready = resident_texture(r, array, .D2_Array)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.texture_desc.layers, 3)
	testing.expect(t, !fake.texture_desc.cube)
	testing.expect_value(t, gpu.validate_texture_desc(fake.texture_desc, nil), gpu.Desc_Error.None)
	testing.expect_value(t, fake.streamed_bytes, chain * 3)

	fake.done_through = fake.next_transfer
	residency_update(r)
	texture, now_ready := resident_texture(r, cube, .Cube)
	testing.expect(t, now_ready)
	testing.expect_value(t, texture.dimension, format.Texture_Dimension.Cube)
	testing.expect_value(t, texture.layer_count, 6)
	_, now_ready = resident_texture(r, array, .D2_Array)
	testing.expect(t, now_ready)
	_, now_ready = resident_texture(r, plain)
	testing.expect(t, now_ready)

	// A reader of another dimension gets its default: a shader that reads a cube as a 2D texture is undefined. It logs
	// that once, which is expected here.
	context.logger = testlog.expected_errors()
	_, now_ready = resident_texture(r, cube)
	testing.expect(t, !now_ready)
	_, now_ready = resident_texture(r, array, .Cube)
	testing.expect(t, !now_ready)
	_, now_ready = resident_texture(r, plain, .Cube)
	testing.expect(t, !now_ready)
	// A reader of either of two dimensions takes either, and no other.
	_, now_ready = resident_texture_of(r, cube, .D2, .Cube)
	testing.expect(t, now_ready)
	_, now_ready = resident_texture_of(r, plain, .D2, .Cube)
	testing.expect(t, now_ready)
	_, now_ready = resident_texture_of(r, array, .D2, .Cube)
	testing.expect(t, !now_ready)
}

// mesh_bytes is a mesh blob of one triangle with vertex_count vertices, at the runtime's alignment, with a hierarchy
// over its one meshlet when nodes, and a skin stream when skinned.
@(private = "file")
mesh_bytes :: proc(guid: format.Guid, vertex_count: u32, nodes := false, skinned := false) -> []byte {
	stride := int(format.mesh_attribute_stride({}))
	indices := []u16{0, 1, 2}
	contents := format.Mesh_Contents {
		guid         = guid,
		vertex_count = vertex_count,
		index_count  = 3,
		submeshes    = {{index_count = 3, meshlet_count = 1}},
		positions    = make([]byte, int(vertex_count) * 12, context.temp_allocator),
		attributes   = make([]byte, int(vertex_count) * stride, context.temp_allocator),
		indices      = mem.slice_to_bytes(indices),
		meshlets     = {{vertex_count = 3, triangle_count = 1}},
		meshlet_vertices = mem.slice_to_bytes([]u32{0, 1, 2}),
		meshlet_triangles = mem.slice_to_bytes([]u32{0 | 1 << 8 | 2 << 16}),
	}
	if skinned {
		contents.flags += {.Skinned}
		contents.skin = make([]format.Mesh_Skin_Vertex, int(vertex_count), context.temp_allocator)
		for &v in contents.skin {
			v.weights[0] = 65535
		}
	}
	if nodes {
		contents.submeshes[0].node_count, contents.submeshes[0].root_count = 1, 1
		contents.meshlet_nodes = {{radius = 1, error = max(f32), count = 1 | format.MESHLET_NODE_LEAF}}
	}
	written := format.mesh_write(contents, context.temp_allocator)
	aligned, _ := mem.alloc_bytes(len(written), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, written)
	return aligned
}

// write_mesh writes a mesh blob of one triangle with vertex_count vertices, and a generation file at modified, as a
// cook does.
@(private = "file")
write_mesh :: proc(t: ^testing.T, dir: string, guid: format.Guid, vertex_count: u32, modified: time.Time) {
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, mesh_bytes(guid, vertex_count)) == nil)
	testing.expect(t, os.change_times(path, modified, modified) == nil)
	generation := fmt.tprintf("%s/%s", dir, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)string("1")) == nil)
	testing.expect(t, os.change_times(generation, modified, modified) == nil)
}

@(test)
resident_meshes_swap_only_when_their_new_data_is_in :: proc(t: ^testing.T) {
	fake: Fake_GPU
	context.user_ptr = &fake
	frame: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&frame) == nil)
	defer virtual.arena_destroy(&frame)
	platform := fake_platform(&frame)
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	start := time.now()
	guid := format.guid_parse("9db8150cc7215ffc2708d20d77cf60bf") or_else {}
	write_mesh(t, dir, guid, 3, start)

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	// The first request streams the mesh, which is not ready until its transfers are done.
	_, ready := resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 6)
	residency_update(r)
	_, ready = resident_mesh(r, guid)
	testing.expect(t, !ready)
	// Every stream must be in, the meshlets' too.
	fake.done_through = fake.next_transfer - 1
	residency_update(r)
	_, ready = resident_mesh(r, guid)
	testing.expect(t, !ready)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, now_ready := resident_mesh(r, guid)
	testing.expect(t, now_ready)
	testing.expect_value(t, mesh.vertex_count, 3)
	testing.expect_value(t, mesh.submesh_count, 1)
	testing.expect_value(t, mesh.index_format, gpu.Index_Format.U16)
	testing.expect_value(t, mesh.submeshes[0].meshlet_count, 1)

	// A new blob streams beside the old, which draws until the new one's transfers are done.
	write_mesh(t, dir, guid, 4, time.time_add(start, time.Second))
	testing.expect_value(t, len(asset.poll(&assets)), 1)
	residency_update(r)
	testing.expect_value(t, fake.live_buffers, 12)
	mesh, ready = resident_mesh(r, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 3)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, ready = resident_mesh(r, guid)
	testing.expect_value(t, mesh.vertex_count, 4)
	// The old buffers are gone.
	testing.expect_value(t, fake.live_buffers, 6)

	// No GUID is no mesh, and a GUID without a blob is never ready.
	_, ready = resident_mesh(r, {})
	testing.expect(t, !ready)
	// It logs that once, which is expected here.
	context.logger = testlog.expected_errors()
	_, ready = resident_mesh(r, format.guid_parse("00112233445566778899aabbccddeeff") or_else {})
	testing.expect(t, !ready)
}

@(test)
a_mesh_with_a_hierarchy_streams_its_nodes :: proc(t: ^testing.T) {
	fake: Fake_GPU
	context.user_ptr = &fake
	frame: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&frame) == nil)
	defer virtual.arena_destroy(&frame)
	platform := fake_platform(&frame)
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	guid := format.guid_parse("4f0c9a6e2b8d47a1b3e5c7d9f1a2b3c4") or_else {}
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)), mesh_bytes(guid, 3, nodes = true)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", dir, format.GENERATION_FILE), transmute([]byte)string("1")) == nil)

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	// The nodes are a seventh stream, which the mesh waits for as it waits for the rest.
	_, ready := resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 7)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, now_ready := resident_mesh(r, guid)
	testing.expect(t, now_ready)
	testing.expect(t, mesh.meshlet_nodes != {})
	testing.expect_value(t, mesh.submeshes[0].node_count, 1)
	testing.expect_value(t, mesh.submeshes[0].root_count, 1)
}

@(test)
live_meshes_draw_from_memory_in_place_of_the_asset :: proc(t: ^testing.T) {
	fake: Fake_GPU
	context.user_ptr = &fake
	frame: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&frame) == nil)
	defer virtual.arena_destroy(&frame)
	platform := fake_platform(&frame)
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	guid := format.guid_parse("9db8150cc7215ffc2708d20d77cf60bf") or_else {}
	write_mesh(t, dir, guid, 3, time.now())

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	// A live blob streams from memory, and the asset's blob is never loaded.
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 4)))
	testing.expect(t, is_live(r, guid))
	_, ready := resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 6)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, now_ready := resident_mesh(r, guid)
	testing.expect(t, now_ready)
	testing.expect_value(t, mesh.vertex_count, 4)

	// A step that arrives while one streams waits for it, and the newest wins: the one between is never streamed.
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 5)))
	testing.expect_value(t, fake.live_buffers, 12)
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 6)))
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 7)))
	testing.expect_value(t, fake.live_buffers, 12)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, _ = resident_mesh(r, guid)
	testing.expect_value(t, mesh.vertex_count, 5)
	testing.expect_value(t, fake.live_buffers, 12)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, _ = resident_mesh(r, guid)
	testing.expect_value(t, mesh.vertex_count, 7)
	testing.expect_value(t, fake.live_buffers, 6)

	// Letting go loads the asset, whose blob draws once it is in. The live mesh draws until then.
	clear_live(r, guid)
	testing.expect(t, !is_live(r, guid))
	residency_update(r)
	mesh, ready = resident_mesh(r, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 7)
	testing.expect_value(t, fake.live_buffers, 12)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, _ = resident_mesh(r, guid)
	testing.expect_value(t, mesh.vertex_count, 3)
	testing.expect_value(t, fake.live_buffers, 6)

	// A live blob over an asset that is resident replaces it, and letting go streams the asset again.
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 8)))
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, _ = resident_mesh(r, guid)
	testing.expect_value(t, mesh.vertex_count, 8)
	clear_live(r, guid)
	residency_update(r)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, _ = resident_mesh(r, guid)
	testing.expect_value(t, mesh.vertex_count, 3)
}

@(test)
a_skinned_mesh_streams_its_skin :: proc(t: ^testing.T) {
	fake: Fake_GPU
	context.user_ptr = &fake
	frame: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&frame) == nil)
	defer virtual.arena_destroy(&frame)
	platform := fake_platform(&frame)
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	guid := format.guid_parse("7a1d3c5e9b2f4086a1b2c3d4e5f60718") or_else {}
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)), mesh_bytes(guid, 3, skinned = true)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", dir, format.GENERATION_FILE), transmute([]byte)string("1")) == nil)

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	// The skin is a stream of its own, which the mesh waits for as it waits for the rest.
	_, ready := resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 7)
	testing.expect_value(t, r.entries[0].transfer_count, 7)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, now_ready := resident_mesh(r, guid)
	testing.expect(t, now_ready)
	testing.expect(t, mesh.skin != {})
	testing.expect(t, .Skinned in mesh.flags)
}

@(test)
skinned_instances_keep_their_buffers_while_their_mesh_stays :: proc(t: ^testing.T) {
	fake: Fake_GPU
	context.user_ptr = &fake
	frame: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&frame) == nil)
	defer virtual.arena_destroy(&frame)
	platform := fake_platform(&frame)
	state: Skin_State
	state.instances = make(map[u32]Skinned_Instance, platform.heap_allocator)
	defer delete(state.instances)
	rest := transmute(gpu.Buffer)[2]u32{100, 1}
	other := transmute(gpu.Buffer)[2]u32{101, 1}
	entity := ecs.Entity(7)

	// The first use makes the three buffers, and starts the pose from rest.
	instance, reset, ok := skin_instance(&state, &platform, 1, 3, entity, rest, 5, 16)
	testing.expect(t, ok && reset)
	testing.expect(t, instance.positions != {} && instance.previous != {} && instance.attributes != {})
	testing.expect_value(t, fake.live_buffers, 3)
	// The next frame uses them as they are: no new buffers, and the pose goes on from last frame's.
	again: Skinned_Instance
	again, reset, ok = skin_instance(&state, &platform, 2, 3, entity, rest, 5, 16)
	testing.expect(t, ok && !reset)
	testing.expect_value(t, again.positions, instance.positions)
	testing.expect_value(t, fake.live_buffers, 3)
	// A frame that no pose used leaves a gap in the previous positions, and another entity in the slot is not the one.
	_, reset, _ = skin_instance(&state, &platform, 4, 3, entity, rest, 5, 16)
	testing.expect(t, reset)
	_, reset, _ = skin_instance(&state, &platform, 5, 3, ecs.Entity(8), rest, 5, 16)
	testing.expect(t, reset)
	testing.expect_value(t, fake.live_buffers, 3)
	// A mesh that streamed anew, with other rest positions, gives new buffers in place of the old.
	again, reset, ok = skin_instance(&state, &platform, 6, 3, ecs.Entity(8), other, 5, 16)
	testing.expect(t, ok && reset)
	testing.expect(t, again.positions != instance.positions)
	testing.expect_value(t, fake.live_buffers, 3)
	// So do another vertex count and another attribute stride.
	_, reset, _ = skin_instance(&state, &platform, 7, 3, ecs.Entity(8), other, 6, 16)
	testing.expect(t, reset)
	_, reset, _ = skin_instance(&state, &platform, 8, 3, ecs.Entity(8), other, 6, 28)
	testing.expect(t, reset)
	testing.expect_value(t, fake.live_buffers, 3)

	// An entity that a frame did not use gives its buffers back, and the one that it used keeps them.
	_, _, _ = skin_instance(&state, &platform, 8, 4, entity, rest, 5, 16)
	testing.expect_value(t, fake.live_buffers, 6)
	sweep_skins(&state, &platform, 9)
	testing.expect_value(t, len(state.instances), 0)
	testing.expect_value(t, fake.live_buffers, 0)
	_, _, _ = skin_instance(&state, &platform, 9, 4, entity, rest, 5, 16)
	_, _, _ = skin_instance(&state, &platform, 9, 3, entity, rest, 5, 16)
	sweep_skins(&state, &platform, 9)
	testing.expect_value(t, len(state.instances), 2)
	for _, &i in state.instances {
		platform.gpu_destroy_buffer(i.positions)
		platform.gpu_destroy_buffer(i.previous)
		platform.gpu_destroy_buffer(i.attributes)
	}
	testing.expect_value(t, fake.live_buffers, 0)
}

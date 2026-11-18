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
	next_accel:     u32,
	live_accels:    int,
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
		gpu_create_accel = proc(desc: gpu.Accel_Struct_Desc) -> gpu.Accel_Struct {
			fake := fake_gpu()
			fake.next_accel += 1
			fake.live_accels += 1
			return transmute(gpu.Accel_Struct)[2]u32{fake.next_accel, 1}
		},
		gpu_destroy_accel = proc(accel: gpu.Accel_Struct) {
			if accel != {} {
				fake_gpu().live_accels -= 1
			}
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

	write_texture :: proc(
		t: ^testing.T,
		dir: string,
		name: string,
		dimension: format.Texture_Dimension,
		layers: u32,
	) -> format.Guid {
		guid := format.guid_parse(name) or_else {}
		chain := format.texture_chain_size(.BC7_Unorm_Srgb, {8, 8}, 4)
		blob := format.texture_write(
			{
				guid = guid,
				format = .BC7_Unorm_Srgb,
				usage = .Color,
				dimension = dimension,
				layer_count = layers,
				size = {8, 8},
				mip_count = 4,
				sampler = {wrap = .Clamp, filter = .Nearest, anisotropy = 4},
				mips = make([]byte, chain * int(layers), context.temp_allocator),
			},
			context.temp_allocator,
		)
		buffer: [32]u8
		testing.expect(
			t,
			os.write_entire_file(
				fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)),
				blob,
			) ==
			nil,
		)
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
	testing.expect_value(
		t,
		texture.sampler,
		format.Texture_Sampler{wrap = .Clamp, filter = .Nearest, anisotropy = 4},
	)
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
@(private)
mesh_bytes :: proc(
	guid: format.Guid,
	vertex_count: u32,
	nodes := false,
	skinned := false,
) -> []byte {
	stride := int(format.mesh_attribute_stride({}))
	indices := []u16{0, 1, 2}
	contents := format.Mesh_Contents {
		guid              = guid,
		vertex_count      = vertex_count,
		index_count       = 3,
		submeshes         = {{index_count = 3, meshlet_count = 1}},
		positions         = make([]byte, int(vertex_count) * 12, context.temp_allocator),
		attributes        = make([]byte, int(vertex_count) * stride, context.temp_allocator),
		indices           = mem.slice_to_bytes(indices),
		meshlets          = {{vertex_count = 3, triangle_count = 1}},
		meshlet_vertices  = mem.slice_to_bytes([]u32{0, 1, 2}),
		meshlet_triangles = []u8{0, 1, 2},
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
		contents.meshlet_nodes = {
			{radius = 1, error = max(f32), count = 1 | format.MESHLET_NODE_LEAF},
		}
	}
	written := format.mesh_write(contents, context.temp_allocator)
	aligned, _ := mem.alloc_bytes(len(written), format.BLOB_ALIGN, context.temp_allocator)
	copy(aligned, written)
	return aligned
}

// write_mesh writes a mesh blob of one triangle with vertex_count vertices, and a generation file at modified, as a
// cook does.
@(private)
write_mesh :: proc(
	t: ^testing.T,
	dir: string,
	guid: format.Guid,
	vertex_count: u32,
	modified: time.Time,
) {
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
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)),
			mesh_bytes(guid, 3, nodes = true),
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s", dir, format.GENERATION_FILE),
			transmute([]byte)string("1"),
		) ==
		nil,
	)

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

// A mesh that the editor made and never saved has no asset, so letting it go leaves nothing to draw.
@(test)
a_live_mesh_with_no_asset_draws_nothing_once_let_go :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
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

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	_, ready := resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 4)))
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh: ^Resident_Mesh
	mesh, ready = resident_mesh(r, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 4)
	testing.expect_value(t, fake.live_buffers, 6)

	// Its buffers go with it.
	clear_live(r, guid)
	residency_update(r)
	_, ready = resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 0)

	// One still streaming when it is let go lands, and then goes the same way.
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 5)))
	clear_live(r, guid)
	fake.done_through = fake.next_transfer
	residency_update(r)
	for _ in 0 ..= RESIDENT_RETRY_FRAMES {
		residency_update(r)
	}
	_, ready = resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 0)

	// The daemon cooks it at last, and the asset draws, as any mesh that was not cooked yet does.
	write_mesh(t, dir, guid, 3, time.now())
	for _ in 0 ..= RESIDENT_RETRY_FRAMES {
		residency_update(r)
	}
	resident_mesh(r, guid)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, ready = resident_mesh(r, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 3)
	testing.expect_value(t, fake.live_buffers, 6)
}

// A mesh whose cooked blob is broken has nothing to draw once its live mesh is let go, though it has an asset.
@(test)
a_live_mesh_over_a_broken_blob_draws_nothing_once_let_go :: proc(t: ^testing.T) {
	context.logger = testlog.expected_errors()
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
	// A blob with only its header loads as the mesh's, but cannot be made resident.
	start := time.now()
	buffer: [32]u8
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)),
			mesh_bytes(guid, 3)[:size_of(format.Blob_Header)],
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s", dir, format.GENERATION_FILE),
			transmute([]byte)string("1"),
		) ==
		nil,
	)

	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Residency)
	defer free(r)
	residency_init(r, &platform, &assets)
	defer residency_destroy(r)

	_, ready := resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect(t, resident_failed(r, guid))
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 4)))
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh: ^Resident_Mesh
	mesh, ready = resident_mesh(r, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 4)
	testing.expect_value(t, fake.live_buffers, 6)

	// Its buffers go with it.
	clear_live(r, guid)
	residency_update(r)
	_, ready = resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 0)

	// One still streaming when it is let go lands, and then goes the same way.
	testing.expect(t, set_live(r, guid, mesh_bytes(guid, 5)))
	clear_live(r, guid)
	fake.done_through = fake.next_transfer
	residency_update(r)
	residency_update(r)
	_, ready = resident_mesh(r, guid)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_buffers, 0)

	// A good cook draws.
	write_mesh(t, dir, guid, 3, time.time_add(start, time.Second))
	testing.expect_value(t, len(asset.poll(&assets)), 1)
	residency_update(r)
	fake.done_through = fake.next_transfer
	residency_update(r)
	mesh, ready = resident_mesh(r, guid)
	testing.expect(t, ready)
	testing.expect_value(t, mesh.vertex_count, 3)
	testing.expect_value(t, fake.live_buffers, 6)
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
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer)),
			mesh_bytes(guid, 3, skinned = true),
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/%s", dir, format.GENERATION_FILE),
			transmute([]byte)string("1"),
		) ==
		nil,
	)

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
	testing.expect_value(t, (r.entries[0].stream.? or_else {}).transfer_count, 7)
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
	testing.expect(
		t,
		instance.positions != {} && instance.previous != {} && instance.attributes != {},
	)
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

// Rig is a residency over a fake GPU, with a directory of blobs. It is on the heap, as the assets point into it.
@(private = "file")
Rig :: struct {
	fake:     Fake_GPU,
	frame:    virtual.Arena,
	platform: core.Platform_API,
	dir:      string,
	assets:   asset.Assets,
	r:        Residency,
}

@(private = "file")
rig_start :: proc(t: ^testing.T, rig: ^Rig) {
	context.user_ptr = &rig.fake
	testing.expect(t, virtual.arena_init_growing(&rig.frame) == nil)
	rig.platform = fake_platform(&rig.frame)
	dir, err := os.make_directory_temp("", "residency_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	rig.dir = fmt.aprintf("%s", dir)
	asset.init(&rig.assets, &rig.platform, asset.loose_cache(rig.dir))
	residency_init(&rig.r, &rig.platform, &rig.assets)
}

@(private = "file")
rig_stop :: proc(rig: ^Rig) {
	context.user_ptr = &rig.fake
	residency_destroy(&rig.r)
	asset.destroy(&rig.assets)
	os.remove_all(rig.dir)
	delete(rig.dir)
	virtual.arena_destroy(&rig.frame)
}

// land makes every transfer that was started done, and updates the residency.
@(private = "file")
land :: proc(rig: ^Rig) {
	rig.fake.done_through = rig.fake.next_transfer
	residency_update(&rig.r)
}

// idle updates the residency for some frames, which nothing asks for.
@(private = "file")
idle :: proc(rig: ^Rig, frames: int) {
	for _ in 0 ..< frames {
		land(rig)
	}
}

// write_texture_blob writes a BC7 texture blob that is not virtual, and a generation file at modified, as a cook does.
@(private)
write_texture_blob :: proc(
	t: ^testing.T,
	dir: string,
	guid: format.Guid,
	size: [2]u32,
	mip_count: u32,
	modified: time.Time,
) {
	chain := format.texture_chain_size(.BC7_Unorm_Srgb, size, mip_count)
	blob := format.texture_write(
		{
			guid = guid,
			format = .BC7_Unorm_Srgb,
			usage = .Color,
			layer_count = 1,
			size = size,
			mip_count = mip_count,
			sampler = {wrap = .Clamp, filter = .Linear, anisotropy = 1},
			mips = make([]byte, chain, context.temp_allocator),
		},
		context.temp_allocator,
	)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", dir, format.guid_format(guid, &buffer))
	testing.expect(t, os.write_entire_file(path, blob) == nil)
	testing.expect(t, os.change_times(path, modified, modified) == nil)
	generation := fmt.tprintf("%s/%s", dir, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)string("1")) == nil)
	testing.expect(t, os.change_times(generation, modified, modified) == nil)
}

@(private)
test_guid :: proc(n: u8) -> format.Guid {
	return {0 = n, 15 = 0x39}
}

// texture_handle is the GPU texture that an entry draws.
@(private = "file")
texture_handle :: proc(r: ^Residency, guid: format.Guid) -> gpu.Texture {
	return r.entries[r.index[{guid, .Texture}]].current.texture.texture
}

// want_virtual asks for a texture as a material that shows pixels across does.
@(private = "file")
want_virtual :: proc(r: ^Residency, guid: format.Guid, pixels: f32) {
	resident_texture_want(r, guid, pixels)
	resident_virtual_texture(r, guid)
}

// The mip that a texture needs is the one whose longer side is about the pixels that it shows across, a mip finer for
// each doubling, and a bias moves it.
@(test)
the_wanted_mip_follows_the_pixels :: proc(t: ^testing.T) {
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 1024, 0), 0)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 5000, 0), 0)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 512, 0), 1)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 600, 0), 0)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 129, 0), 2)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 128, 0), 3)
	// Never past the chain, and a texture that shows less than a pixel wants the last mip.
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 0, 0), 10)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 4, 1, 0), 3)
	testing.expect_value(t, texture_mip_for_pixels({64, 64}, 1, 1, 0), 0)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 512, 1), 2)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, 512, -3), 0)
	testing.expect_value(t, texture_mip_for_pixels({1024, 512}, 11, max(f32), 2), 0)
}

// What nothing asks for in the policy's idle frames is unloaded: its resources and its blob go, and a request streams it
// again.
@(test)
unused_assets_are_unloaded_and_stream_again :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r, fake := &rig.r, &rig.fake
	start := time.now()
	texture, mesh := test_guid(1), test_guid(2)
	write_texture_blob(t, rig.dir, texture, {16, 16}, 5, start)
	write_mesh(t, rig.dir, mesh, 3, start)
	residency_set_policy(r, {idle_frames = 100})

	resident_texture(r, texture)
	resident_mesh(r, mesh)
	land(rig)
	_, ready := resident_texture(r, texture)
	testing.expect(t, ready)
	_, ready = resident_mesh(r, mesh)
	testing.expect(t, ready)
	testing.expect_value(t, fake.live_textures, 1)
	testing.expect_value(t, fake.live_buffers, 6)
	testing.expect(t, residency_stats(r).resident_bytes > 0)

	// Not yet at the edge of the policy, and then past it.
	idle(rig, 99)
	testing.expect_value(t, fake.live_textures, 1)
	idle(rig, 3)
	testing.expect_value(t, fake.live_textures, 0)
	testing.expect_value(t, fake.live_buffers, 0)
	stats := residency_stats(r)
	testing.expect_value(t, stats.resident_bytes, 0)
	testing.expect_value(t, stats.evicted, 2)
	testing.expect_value(t, stats.entries, 0)
	testing.expect_value(t, r.count, 2)

	// A request streams them again, and they are ready once the transfers are done.
	_, ready = resident_texture(r, texture)
	testing.expect(t, !ready)
	_, ready = resident_mesh(r, mesh)
	testing.expect(t, !ready)
	testing.expect_value(t, fake.live_textures, 1)
	land(rig)
	_, ready = resident_texture(r, texture)
	testing.expect(t, ready)
	m, mesh_ready := resident_mesh(r, mesh)
	testing.expect(t, mesh_ready)
	testing.expect_value(t, m.vertex_count, 3)
	testing.expect_value(t, residency_stats(r).entries, 2)
	testing.expect_value(t, r.count, 2)
}

// A live mesh, what streams and what only a thumbnail asked for are never unloaded, however long they go unused.
@(test)
unloading_leaves_live_streaming_and_baked_assets :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r := &rig.r
	start := time.now()
	live, streaming, baked, plain := test_guid(1), test_guid(2), test_guid(3), test_guid(4)
	write_mesh(t, rig.dir, streaming, 3, start)
	write_mesh(t, rig.dir, baked, 3, start)
	write_mesh(t, rig.dir, plain, 3, start)
	residency_set_policy(r, {idle_frames = 10})

	testing.expect(t, set_live(r, live, mesh_bytes(live, 3)))
	resident_mesh(r, plain)
	r.baking = true
	resident_mesh(r, baked)
	r.baking = false
	land(rig)
	testing.expect(t, is_live(r, live))
	// This one's transfers stay unfinished, as the fake says when they are done.
	resident_mesh(r, streaming)
	for _ in 0 ..< 50 {
		residency_update(r)
	}
	_, ready := resident_mesh(r, live)
	testing.expect(t, ready)
	r.baking = true
	_, ready = resident_mesh(r, baked)
	r.baking = false
	testing.expect(t, ready)
	_, evicted := r.entries[r.index[{plain, .Mesh}]].source.(Evicted_Source)
	testing.expect(t, evicted, "an asset that the world uses goes when it is idle")
	testing.expect_value(t, resident_streaming(r), 1)
	// The streaming one lands, and then it goes when it is idle too.
	land(rig)
	idle(rig, 12)
	testing.expect_value(t, residency_baked_count(r), 1)
	testing.expect_value(t, residency_stats(r).evicted, 2)
	_, ready = resident_mesh(r, live)
	testing.expect(t, ready)
	r.baking = true
	_, ready = resident_mesh(r, baked)
	r.baking = false
	testing.expect(t, ready)
}

// The resident bytes stay under the budget while the requests rotate through more textures than fit, as the camera moves
// on: what was used longest ago goes, and what was used in the last RESIDENT_KEEP_FRAMES stays.
@(test)
resident_bytes_stay_under_the_budget_as_requests_rotate :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r := &rig.r
	start := time.now()
	COUNT :: 6
	guids: [COUNT]format.Guid
	for &g, i in guids {
		g = test_guid(u8(i + 1))
		write_texture_blob(t, rig.dir, g, {32, 32}, 6, start)
	}
	one := u64(format.texture_chain_size(.BC7_Unorm_Srgb, {32, 32}, 6))
	budget := one * 3 + one / 2
	residency_set_policy(r, {budget_bytes = budget})

	over := false
	for frame in 0 ..< 400 {
		// Three textures at a time, and the camera moves to the others every 100 frames.
		first := (frame / 100) % 2 * 3
		for g in guids[first:][:3] {
			resident_texture(r, g)
		}
		land(rig)
		bytes := residency_stats(r).resident_bytes
		// The textures of the last phase have been unused for longer than RESIDENT_KEEP_FRAMES by now.
		if frame % 100 > RESIDENT_KEEP_FRAMES + 2 {
			testing.expectf(t, bytes <= budget, "frame %d holds %d of %d", frame, bytes, budget)
		}
		over ||= bytes > budget
	}
	testing.expect(t, over, "what was used a moment ago is kept even when it is over the budget")
	testing.expect(t, residency_stats(r).evicted > 0)
	testing.expect(t, residency_stats(r).resident_bytes > 0)
}

// A texture that a material draws small streams in from the mip that it wants, as a smaller texture, and a finer mip
// streams at once when what draws it grows. A coarser one streams after MIP_DROP_FRAMES. The old texture draws until the
// new one is in.
@(test)
a_materials_texture_streams_the_mips_that_its_size_wants :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r, fake := &rig.r, &rig.fake
	start := time.now()
	small, large := test_guid(1), test_guid(2)
	write_texture_blob(t, rig.dir, small, {64, 64}, 7, start)
	write_texture_blob(t, rig.dir, large, {64, 64}, 7, start)

	// A texture of 64 texels that shows 8 across wants mip 3, which is 8 by 8 with 4 mips, and one that shows 1000 wants all.
	want_virtual(r, small, 8)
	testing.expect_value(t, fake.texture_desc.size, [2]u32{8, 8})
	testing.expect_value(t, fake.texture_desc.mip_count, 4)
	testing.expect_value(
		t,
		fake.streamed_bytes,
		format.texture_chain_size(.BC7_Unorm_Srgb, {8, 8}, 4),
	)
	want_virtual(r, large, 1000)
	testing.expect_value(t, fake.texture_desc.size, [2]u32{64, 64})
	testing.expect_value(t, fake.texture_desc.mip_count, 7)
	land(rig)
	texture, ready := resident_virtual_texture(r, small)
	testing.expect(t, ready)
	testing.expect_value(t, texture.top_mip, 3)
	testing.expect_value(t, texture.size, [2]u32{64, 64})
	testing.expect_value(t, texture.mip_count, 7)
	texture, ready = resident_virtual_texture(r, large)
	testing.expect(t, ready)
	testing.expect_value(t, texture.top_mip, 0)
	// A reader that reads every mip, as a sprite does, waits for them.
	_, ready = resident_texture(r, small)
	testing.expect(t, !ready)
	testing.expect_value(t, residency_stats(r).mip_streams, 0)
	// That reader wants all of the mips, so the texture streams them in the next frames.
	land(rig)
	land(rig)
	_, ready = resident_texture(r, small)
	testing.expect(t, ready)
	testing.expect_value(t, residency_stats(r).mip_streams, 1)

	// It shrinks to show 4 across, which wants mip 4, and the old texture stays for MIP_DROP_FRAMES.
	// The frame moves on, so what asks next is the frame's first.
	residency_update(r)
	textures := fake.next_texture
	old := texture_handle(r, small)
	frames := 0
	for fake.next_texture == textures && frames < 3 * MIP_DROP_FRAMES {
		want_virtual(r, small, 4)
		want_virtual(r, large, 1000)
		fake.done_through = fake.next_transfer
		residency_update(r)
		frames += 1
	}
	testing.expect_value(t, frames, MIP_DROP_FRAMES + 1)
	testing.expect_value(t, fake.texture_desc.mip_count, 3)
	testing.expect_value(t, fake.texture_desc.size, [2]u32{4, 4})
	// The old texture draws until the new one is in.
	testing.expect_value(t, fake.live_textures, 3)
	texture, ready = resident_virtual_texture(r, small)
	testing.expect(t, ready)
	testing.expect_value(t, texture.top_mip, 0)
	testing.expect_value(t, texture.texture, old)
	land(rig)
	texture, _ = resident_virtual_texture(r, small)
	testing.expect_value(t, texture.top_mip, 4)
	testing.expect(t, texture.texture != old)
	testing.expect_value(t, fake.live_textures, 2)

	// It grows to show 64 across again: the finer mip streams at once, and the coarse texture draws until it is in.
	textures = fake.next_texture
	coarse := texture.texture
	want_virtual(r, small, 64)
	want_virtual(r, large, 1000)
	residency_update(r)
	testing.expect_value(t, fake.next_texture, textures + 1)
	testing.expect_value(t, fake.texture_desc.mip_count, 7)
	texture, ready = resident_virtual_texture(r, small)
	testing.expect(t, ready)
	testing.expect_value(t, texture.top_mip, 4)
	testing.expect_value(t, texture.texture, coarse)
	land(rig)
	texture, _ = resident_virtual_texture(r, small)
	testing.expect_value(t, texture.top_mip, 0)
	testing.expect_value(t, fake.live_textures, 2)
}

// At most MIP_STREAMS_PER_FRAME textures start a new mip in a frame.
@(test)
mip_streams_are_limited_each_frame :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r, fake := &rig.r, &rig.fake
	start := time.now()
	COUNT :: MIP_STREAMS_PER_FRAME * 2
	guids: [COUNT]format.Guid
	for &g, i in guids {
		g = test_guid(u8(i + 1))
		write_texture_blob(t, rig.dir, g, {64, 64}, 7, start)
		want_virtual(r, g, 4)
	}
	land(rig)
	for g in guids {
		want_virtual(r, g, 64)
	}
	textures := fake.next_texture
	residency_update(r)
	testing.expect_value(t, fake.next_texture, textures + MIP_STREAMS_PER_FRAME)
	for g in guids {
		want_virtual(r, g, 64)
	}
	land(rig)
	for g in guids {
		want_virtual(r, g, 64)
	}
	residency_update(r)
	testing.expect_value(t, fake.next_texture, textures + COUNT)
}

// A newer blob does nothing for an asset that was unloaded, until something asks for the asset. A newer blob while a mip
// streams comes in after it.
@(test)
a_newer_blob_waits_for_an_unloaded_asset_and_follows_a_mip_stream :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r, fake := &rig.r, &rig.fake
	start := time.now()
	mesh, texture := test_guid(1), test_guid(2)
	write_mesh(t, rig.dir, mesh, 3, start)
	write_texture_blob(t, rig.dir, texture, {64, 64}, 7, start)
	residency_set_policy(r, {idle_frames = 10})
	resident_mesh(r, mesh)
	land(rig)
	idle(rig, 12)
	testing.expect_value(t, fake.live_buffers, 0)

	write_mesh(t, rig.dir, mesh, 4, time.time_add(start, time.Second))
	asset.poll(&rig.assets)
	idle(rig, 3)
	testing.expect_value(t, fake.live_buffers, 0)
	_, ready := resident_mesh(r, mesh)
	testing.expect(t, !ready)
	land(rig)
	m, now_ready := resident_mesh(r, mesh)
	testing.expect(t, now_ready)
	testing.expect_value(t, m.vertex_count, 4)

	// A mip streams, and the blob is replaced while it does.
	residency_set_policy(r, {})
	want_virtual(r, texture, 4)
	land(rig)
	want_virtual(r, texture, 64)
	residency_update(r)
	testing.expect_value(t, resident_streaming(r), 1)
	write_texture_blob(t, rig.dir, texture, {64, 64}, 7, time.time_add(start, 2 * time.Second))
	testing.expect(t, len(asset.poll(&rig.assets)) > 0)
	want_virtual(r, texture, 64)
	land(rig)
	// The mip's texture landed, of the old version, and the new version streams after it.
	testing.expect_value(t, resident_streaming(r), 0)
	want_virtual(r, texture, 64)
	residency_update(r)
	testing.expect_value(t, resident_streaming(r), 1)
	land(rig)
	e := &r.entries[r.index[{texture, .Texture}]]
	testing.expect_value(t, e.version, asset.version(&rig.assets, e.handle))
	testing.expect(t, e.ready)
}

// The acceleration structure of a mesh that was unloaded goes with its buffers, and comes back when it streams again.
@(test)
an_unloaded_mesh_gives_back_its_acceleration_structure :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r, fake := &rig.r, &rig.fake
	write_mesh(t, rig.dir, test_guid(1), 3, time.now())
	residency_enable_accels(r)
	residency_set_policy(r, {idle_frames = 10})
	resident_mesh(r, test_guid(1))
	land(rig)
	mesh, _ := resident_mesh(r, test_guid(1))
	testing.expect(t, mesh.accel != {})
	testing.expect_value(t, fake.live_accels, 1)
	idle(rig, 12)
	testing.expect_value(t, fake.live_accels, 0)
	testing.expect_value(t, len(unbuilt_accels(r)), 0)
	resident_mesh(r, test_guid(1))
	land(rig)
	mesh, _ = resident_mesh(r, test_guid(1))
	testing.expect(t, mesh.accel != {})
	testing.expect_value(t, fake.live_accels, 1)
	testing.expect_value(t, len(unbuilt_accels(r)), 1)
}

// A full table gives the place of the asset that was unloaded longest ago to a new one.
@(test)
a_full_table_reuses_an_unloaded_assets_place :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r := &rig.r
	start := time.now()
	first, second := test_guid(1), test_guid(2)
	write_mesh(t, rig.dir, first, 3, start)
	write_mesh(t, rig.dir, second, 3, start)
	residency_set_policy(r, {idle_frames = 10})
	resident_mesh(r, first)
	land(rig)
	idle(rig, 12)
	// The rest of the table is full of what has no resources.
	for i in 1 ..< MAX_RESIDENT {
		r.entries[i] = {
			guid = {0 = 0xff, 1 = u8(i), 2 = u8(i >> 8)},
			kind = .Mesh,
			source = Asset_Source{},
		}
		r.index[{r.entries[i].guid, .Mesh}] = i
	}
	r.count = MAX_RESIDENT
	defer {
		for i in 1 ..< MAX_RESIDENT {
			delete_key(&r.index, Resident_Key{r.entries[i].guid, .Mesh})
			r.entries[i] = {}
		}
		r.count = 1
	}
	_, found := r.index[{first, .Mesh}]
	testing.expect(t, found)
	_, ready := resident_mesh(r, second)
	testing.expect(t, !ready)
	_, found = r.index[{first, .Mesh}]
	testing.expect(t, !found)
	i, second_found := r.index[{second, .Mesh}]
	testing.expect(t, second_found && i == 0)
}

// An asset whose newest blob is broken goes on drawing the older one: it is not unloaded, which would stream the broken
// blob, and it streams no mips of it.
@(test)
a_broken_newer_blob_leaves_the_older_one_drawing :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	context.user_ptr = &rig.fake
	rig_start(t, rig)
	defer rig_stop(rig)
	r, fake := &rig.r, &rig.fake
	start := time.now()
	guid := test_guid(1)
	write_texture_blob(t, rig.dir, guid, {64, 64}, 7, start)
	residency_set_policy(r, {idle_frames = 10})
	want_virtual(r, guid, 1000)
	land(rig)
	_, ready := resident_virtual_texture(r, guid)
	testing.expect(t, ready)

	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", rig.dir, format.guid_format(guid, &buffer))
	later := time.time_add(start, time.Second)
	// A cooked blob whose mips are not the size that its header says.
	broken := format.texture_write(
		{
			guid = guid,
			format = .BC7_Unorm_Srgb,
			usage = .Color,
			layer_count = 1,
			size = {64, 64},
			mip_count = 7,
			mips = make([]byte, 16, context.temp_allocator),
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(path, broken) == nil)
	testing.expect(t, os.change_times(path, later, later) == nil)
	generation := fmt.tprintf("%s/%s", rig.dir, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)string("2")) == nil)
	testing.expect(t, os.change_times(generation, later, later) == nil)
	testing.expect(t, len(asset.poll(&rig.assets)) > 0)
	context.logger = testlog.expected_errors()
	want_virtual(r, guid, 1000)
	land(rig)
	_, stale := r.entries[r.index[{guid, .Texture}]].source.(Stale_Source)
	testing.expect(t, stale)

	// Nothing asks for it for longer than the idle frames and than MIP_DROP_FRAMES.
	textures := fake.next_texture
	idle(rig, 2 * MIP_DROP_FRAMES)
	testing.expect_value(t, fake.next_texture, textures)
	testing.expect_value(t, fake.live_textures, 1)
	testing.expect_value(t, residency_stats(r).evicted, 0)
	texture, still_ready := resident_virtual_texture(r, guid)
	testing.expect(t, still_ready)
	testing.expect_value(t, texture.top_mip, 0)

	// A newer good blob streams again.
	write_texture_blob(t, rig.dir, guid, {64, 64}, 7, time.time_add(start, 2 * time.Second))
	testing.expect(t, len(asset.poll(&rig.assets)) > 0)
	want_virtual(r, guid, 1000)
	land(rig)
	land(rig)
	_, plain := r.entries[r.index[{guid, .Texture}]].source.(Asset_Source)
	testing.expect(t, plain)
}

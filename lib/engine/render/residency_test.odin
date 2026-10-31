package render

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

// A fake GPU that counts buffers, and whose transfers are done only when the test says so. Each test has its own,
// in its context's user pointer, so the tests can run at the same time.
@(private = "file")
Fake_GPU :: struct {
	next_buffer:    u32,
	live_buffers:   int,
	next_transfer:  u64,
	done_through:   u64,
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
	}
}

// mesh_bytes is a mesh blob of one triangle with vertex_count vertices, at the runtime's alignment, with a hierarchy
// over its one meshlet when nodes.
@(private = "file")
mesh_bytes :: proc(guid: format.Guid, vertex_count: u32, nodes := false) -> []byte {
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
	context.logger = log.nil_logger()
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

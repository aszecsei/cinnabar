package editor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/editor/link"
import "cinnabar:engine/render"

@(private = "file")
BAKE_MESH := [16]u8{0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11}
@(private = "file")
BAKE_PREFAB := [16]u8{0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22}

@(private = "file")
BAKE_PREFAB_TEXT :: `scene 2

entity 0000000000000001
name = "Root"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 33 Mesh_Renderer
	mesh = $11111111111111111111111111111111
`

@(private = "file")
BAKE_MISSING_TEXT :: `
entity 0000000000000002
name = "Missing"
parent = @0000000000000001
component 2 Local_Transform
	offset = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
component 33 Mesh_Renderer
	mesh = $33333333333333333333333333333333
`

@(private = "file")
BAKE_EMPTY_TEXT := `scene 2

entity 0000000000000001
name = "Root"
component 1 Transform
	position = [0, 0, 0]
	rotation = [0, 0, 0, 1]
	scale = [1, 1, 1]
`

// The clock moves only when a test moves it.
@(private = "file", thread_local)
bake_now: f64

// A bake with a renderer whose residency reads a cache of one mesh, on a GPU whose transfers are done at once.
@(private = "file")
Bake_Fixture :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	assets:   asset.Assets,
	renderer: ^render.Renderer,
	editor:   Editor,
	dir:      string,
}

@(private = "file")
bake_setup :: proc(t: ^testing.T) -> ^Bake_Fixture {
	bake_now = 100
	f := new(Bake_Fixture)
	testing.expect(t, virtual.arena_init_growing(&f.arena) == nil)
	f.platform = {
		frame_allocator = virtual.arena_allocator(&f.arena),
		heap_allocator = runtime.heap_allocator(),
		asset_allocator = runtime.heap_allocator(),
		file_read = core.file_read,
		file_modified = core.file_modified,
		time_seconds = proc() -> f64 {return bake_now},
		gpu_create_texture = proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture {return gpu.Texture{index = 1, generation = 1}},
		gpu_destroy_texture = proc(texture: gpu.Texture) {},
		gpu_create_buffer = proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer {return gpu.Buffer{index = 1, generation = 1}},
		gpu_destroy_buffer = proc(buffer: gpu.Buffer) {},
		gpu_stream_buffer = proc(buffer: gpu.Buffer, offset: u32, data: []byte) -> gpu.Transfer {return gpu.Transfer(1)},
		gpu_transfer_done = proc(transfer: gpu.Transfer) -> bool {return true},
		memory_reserve = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit = proc(ptr: rawptr, size: int) -> bool {
			return virtual.commit(ptr, uint(size)) == nil
		},
		memory_release = proc(ptr: rawptr, size: int) {
			virtual.release(ptr, uint(size))
		},
	}
	dir, err := os.make_directory_temp("", "thumbnails_test_*", context.allocator)
	testing.expect(t, err == nil)
	f.dir = dir
	write_mesh(t, f)
	asset.init(&f.assets, &f.platform, asset.loose_cache(dir))
	f.renderer = new(render.Renderer)
	f.renderer.platform = &f.platform
	render.residency_init(&f.renderer.residency, &f.platform, &f.assets)
	init(&f.editor, &f.platform, &f.assets, &f.renderer.residency, f.renderer)
	return f
}

@(private = "file")
bake_teardown :: proc(f: ^Bake_Fixture) {
	close_thumbnail(&f.editor)
	destroy(&f.editor)
	render.residency_destroy(&f.renderer.residency)
	free(f.renderer)
	asset.destroy(&f.assets)
	os.remove_all(f.dir)
	delete(f.dir)
	virtual.arena_destroy(&f.arena)
	free(f)
}

// A mesh blob of one triangle, as the bakes draw.
@(private = "file")
write_mesh :: proc(t: ^testing.T, f: ^Bake_Fixture) {
	stride := int(format.mesh_attribute_stride({}))
	contents := format.Mesh_Contents {
		guid = format.Guid(BAKE_MESH),
		vertex_count = 3,
		index_count = 3,
		bounds = {max = {1, 1, 1}, radius = 1},
		submeshes = {{index_count = 3, meshlet_count = 1}},
		positions = make([]byte, 3 * 12, context.temp_allocator),
		attributes = make([]byte, 3 * stride, context.temp_allocator),
		indices = mem.slice_to_bytes([]u16{0, 1, 2}),
		meshlets = {{vertex_count = 3, triangle_count = 1}},
		meshlet_vertices = mem.slice_to_bytes([]u32{0, 1, 2}),
		meshlet_triangles = mem.slice_to_bytes([]u32{0 | 1 << 8 | 2 << 16}),
	}
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(format.Guid(BAKE_MESH), &buffer))
	testing.expect(t, os.write_entire_file(path, format.mesh_write(contents, context.temp_allocator)) == nil)
}

// What is not in the cache fails, which residency logs. Only that goes quiet: a test's expects report through the logger
// too, and could not fail under a logger that hears nothing.
@(private = "file")
preview_quietly :: proc(f: ^Bake_Fixture, others_waiting: bool) -> (desc: render.Preview_Desc, draw: bool) {
	context.logger = log.nil_logger()
	return thumbnail_preview(&f.editor, others_waiting)
}

// The frames from a bake's start to its first drawing: what it touches streams, and the frame's end finishes that.
@(private = "file")
first_drawing :: proc(f: ^Bake_Fixture) -> (desc: render.Preview_Desc, draw: bool) {
	for _ in 0 ..< 4 {
		desc, draw = preview_quietly(f, false)
		if draw || f.editor.session.thumbnail.phase == .Idle {
			return
		}
		render.residency_update(&f.renderer.residency)
	}
	return
}

@(private = "file")
bake :: proc(f: ^Bake_Fixture, id: u32, kind: link.Thumbnail_Kind, guid: [16]u8) {
	handle_thumbnail_message(&f.editor, link.Bake_Thumbnail{id = id, kind = kind, asset = guid, width = 64, height = 64})
}

@(private = "file")
write_scene :: proc(t: ^testing.T, f: ^Bake_Fixture, guid: [16]u8, text: string) {
	scene, problems, ok := format.scene_parse(text, context.temp_allocator)
	testing.expectf(t, ok, "%v", problems)
	buffer: [32]u8
	path := fmt.tprintf("%s/%s.blob", f.dir, format.guid_format(format.Guid(guid), &buffer))
	testing.expect(t, os.write_entire_file(path, format.scene_write(scene, format.Guid(guid), 1, .Prefab, allocator = context.temp_allocator)) == nil)
}

@(test)
a_bake_captures_once_when_complete :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)

	// With nothing asked for, nothing draws.
	_, draw := preview_quietly(f, false)
	testing.expect(t, !draw)

	bake(f, 7, .Mesh, BAKE_MESH)
	desc: render.Preview_Desc
	desc, draw = first_drawing(f)
	testing.expect(t, draw)
	testing.expect_value(t, desc.capture, 7)
	testing.expect_value(t, desc.size, [2]u32{64, 64})
	testing.expect_value(t, len(desc.items), 1)
	testing.expect(t, desc.target != {})

	// It draws until the renderer says that the picture is complete, and until the backend has taken its copy.
	_, draw = preview_quietly(f, false)
	testing.expect(t, draw)
	desc.complete^ = true
	_, draw = preview_quietly(f, false)
	testing.expect(t, draw)
	desc.captured^ = true
	_, draw = preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.phase, Thumbnail_Phase.Idle)
	_, draw = preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "")
}

@(test)
a_bake_shares_frames_with_a_preview_that_plays :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	bake(f, 1, .Mesh, BAKE_MESH)
	first_drawing(f)
	draws := 0
	for _ in 0 ..< 10 {
		if _, draw := preview_quietly(f, true); draw {
			draws += 1
		}
	}
	testing.expect_value(t, draws, 5)
}

@(test)
a_bake_waits_for_a_new_generation :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)

	// A cook has written its blobs, and the frame's poll has not seen them, so what is loaded is the old picture.
	generation := fmt.tprintf("%s/%s", f.dir, format.GENERATION_FILE)
	testing.expect(t, os.write_entire_file(generation, transmute([]byte)string("1")) == nil)
	testing.expect(t, !asset.current(&f.assets))

	bake(f, 1, .Mesh, BAKE_MESH)
	_, draw := preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.phase, Thumbnail_Phase.Waiting)

	asset.poll(&f.assets)
	testing.expect(t, asset.current(&f.assets))
	_, draw = first_drawing(f)
	testing.expect(t, draw)
}

@(test)
a_bake_that_never_completes_says_why :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	bake(f, 9, .Mesh, BAKE_MESH)
	_, draw := first_drawing(f)
	testing.expect(t, draw)

	bake_now += THUMBNAIL_TIMEOUT_SECONDS
	_, draw = preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.phase, Thumbnail_Phase.Idle)
	testing.expect_value(t, f.editor.session.thumbnail.failed_id, 9)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "it was not ready in time")

	// The editor hears of it once.
	out: [dynamic]byte
	defer delete(out)
	send_thumbnail_failed(&f.editor, &out)
	testing.expect(t, len(out) > 0)
	written := len(out)
	send_thumbnail_failed(&f.editor, &out)
	testing.expect_value(t, len(out), written)
}

@(test)
a_bake_of_what_cannot_be_drawn_says_why :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)

	bake(f, 1, .Prefab, BAKE_PREFAB)
	_, draw := preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "its blob cannot be read")

	write_scene(t, f, BAKE_PREFAB, BAKE_EMPTY_TEXT)
	bake(f, 2, .Prefab, BAKE_PREFAB)
	_, draw = preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "it draws nothing")

	// With nothing that it draws in the cache, there is no picture to keep.
	missing := [16]u8{0 ..< 16 = 0x33}
	bake(f, 3, .Mesh, missing)
	_, draw = first_drawing(f)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.failed_id, 3)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "what it draws could not be loaded")
}

// One mesh that is missing does not cost a prefab its picture.
@(test)
a_bake_draws_what_can_be_loaded :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	write_scene(t, f, BAKE_PREFAB, BAKE_PREFAB_TEXT + BAKE_MISSING_TEXT)
	bake(f, 1, .Prefab, BAKE_PREFAB)
	desc, draw := first_drawing(f)
	testing.expect(t, draw)
	testing.expect_value(t, len(desc.items), 2)
}

@(test)
a_bake_of_a_prefab_does_not_keep_its_blob :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	write_scene(t, f, BAKE_PREFAB, BAKE_PREFAB_TEXT)

	bake(f, 1, .Prefab, BAKE_PREFAB)
	desc, draw := first_drawing(f)
	testing.expect(t, draw)
	testing.expect_value(t, len(desc.items), 1)
	_, loaded := asset.find(&f.assets, format.Guid(BAKE_PREFAB))
	testing.expect(t, !loaded)

	// What the world has loaded stays loaded.
	h, ok := asset.load(&f.assets, format.Guid(BAKE_PREFAB))
	testing.expect(t, ok)
	bake(f, 2, .Prefab, BAKE_PREFAB)
	_, draw = first_drawing(f)
	testing.expect(t, draw)
	found: asset.Handle
	found, loaded = asset.find(&f.assets, format.Guid(BAKE_PREFAB))
	testing.expect(t, loaded)
	testing.expect_value(t, found, h)
}

@(test)
a_bake_leaves_the_world_room_in_the_tables :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	f.renderer.materials.pipeline_count = render.MAX_MATERIAL_PIPELINES - render.PREVIEW_ROOM + 1

	bake(f, 3, .Mesh, BAKE_MESH)
	_, draw := preview_quietly(f, false)
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.failed_id, 3)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "the renderer's tables are nearly full")
	testing.expect_value(t, f.renderer.residency.count, 0)

	f.renderer.materials.pipeline_count = render.MAX_MATERIAL_PIPELINES - render.PREVIEW_ROOM
	bake(f, 4, .Mesh, BAKE_MESH)
	_, draw = first_drawing(f)
	testing.expect(t, draw)
}

@(test)
a_bake_refuses_a_mesh_that_is_being_edited :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	{
		context.logger = log.nil_logger()
		render.resident_mesh(&f.renderer.residency, format.Guid(BAKE_MESH))
		// A blob that cannot stream still makes the mesh live.
		render.set_live(&f.renderer.residency, format.Guid(BAKE_MESH), nil)
	}
	testing.expect(t, render.is_live(&f.renderer.residency, format.Guid(BAKE_MESH)))

	// Its picture would show what is not saved, under the name of what is.
	bake(f, 5, .Mesh, BAKE_MESH)
	_, draw := preview_quietly(f, false)
	render.clear_live(&f.renderer.residency, format.Guid(BAKE_MESH))
	testing.expect(t, !draw)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "a mesh that it draws is being edited")
}

@(test)
a_bake_gives_back_what_many_bakes_loaded :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	f.renderer.residency.baking = true
	{
		context.logger = log.nil_logger()
		for n in 1 ..= THUMBNAIL_BAKED_MOST + 1 {
			guid: format.Guid
			guid[0], guid[1] = u8(n), u8(n >> 8)
			render.resident_mesh(&f.renderer.residency, guid)
		}
	}
	f.renderer.residency.baking = false
	testing.expect_value(t, render.residency_baked_count(&f.renderer.residency), THUMBNAIL_BAKED_MOST + 1)

	// A screen of bakes never leaves the time that releases what they loaded, so a new one does.
	bake(f, 1, .Mesh, BAKE_MESH)
	_, draw := first_drawing(f)
	testing.expect(t, draw)
	testing.expect_value(t, render.residency_baked_count(&f.renderer.residency), 1)
}

@(test)
a_bake_of_a_node_draws_only_what_is_under_it :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	write_scene(t, f, BAKE_PREFAB, BAKE_PREFAB_TEXT + BAKE_MISSING_TEXT)

	handle_thumbnail_message(&f.editor, link.Bake_Thumbnail{id = 1, kind = .Prefab, asset = BAKE_PREFAB, node = 2, width = 64, height = 64})
	preview_quietly(f, false)
	// Its one mesh is the one that is not in the cache, so what it draws is not its prefab's other.
	testing.expect_value(t, f.editor.session.thumbnail.failed, "what it draws could not be loaded")

	handle_thumbnail_message(&f.editor, link.Bake_Thumbnail{id = 2, kind = .Prefab, asset = BAKE_PREFAB, node = 1, width = 64, height = 64})
	desc, draw := first_drawing(f)
	testing.expect(t, draw)
	testing.expect_value(t, len(desc.items), 2)
	free_all(f.platform.frame_allocator)

	handle_thumbnail_message(&f.editor, link.Bake_Thumbnail{id = 3, kind = .Prefab, asset = BAKE_PREFAB, node = 99, width = 64, height = 64})
	preview_quietly(f, false)
	testing.expect_value(t, f.editor.session.thumbnail.failed_id, 3)
	testing.expect_value(t, f.editor.session.thumbnail.failed, "it draws nothing")
}

// What only thumbnails asked for goes a while after the last one, and not before.
@(test)
a_bake_gives_back_what_it_loaded :: proc(t: ^testing.T) {
	f := bake_setup(t)
	defer bake_teardown(f)
	bake(f, 1, .Mesh, BAKE_MESH)
	desc, _ := first_drawing(f)
	desc.complete^, desc.captured^ = true, true
	preview_quietly(f, false)
	testing.expect(t, f.editor.session.thumbnail.baked)

	bake_now += THUMBNAIL_RELEASE_SECONDS - 1
	preview_quietly(f, false)
	testing.expect(t, f.editor.session.thumbnail.baked)
	bake_now += 1
	preview_quietly(f, false)
	testing.expect(t, !f.editor.session.thumbnail.baked)
	testing.expect_value(t, f.renderer.residency.count, 0)
}


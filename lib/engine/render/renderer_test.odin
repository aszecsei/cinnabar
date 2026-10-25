package render

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"

// What the hooks of the test frame saw, and the logged problems other than the shaders that the test cache lacks.
@(private = "file")
Hook_Record :: struct {
	before_world, world_uses, after_world, ui, debug: bool,
	world_pieces:                                       int,
	post:                                               Texture,
	problems:                                           [dynamic]string,
	mutex:                                              sync.Mutex,
}

// record_problems keeps every warning and error, except that a shader is not cooked: the test's cache has none, so
// every pipeline is missing, which the frame must survive.
@(private = "file")
record_problems :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location: runtime.Source_Code_Location) {
	r := (^Hook_Record)(data)
	if level < .Warning || strings.contains(text, "is not cooked") {
		return
	}
	sync.guard(&r.mutex)
	append(&r.problems, strings.clone(text))
}

@(test)
a_frame_runs_every_hook_and_passes_validation :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator              = virtual.arena_allocator(&arena),
		heap_allocator               = runtime.heap_allocator(),
		asset_allocator              = runtime.heap_allocator(),
		file_read                    = core.file_read,
		file_modified                = core.file_modified,
		jobs_run                     = jobs.run,
		jobs_wait                    = jobs.wait,
		memory_reserve               = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit                = proc(ptr: rawptr, size: int) -> bool {return virtual.commit(ptr, uint(size)) == nil},
		memory_release               = proc(ptr: rawptr, size: int) {virtual.release(ptr, uint(size))},
		gpu_frame_target             = null.frame_target,
		gpu_submit                   = null.submit,
		gpu_upload                   = null.upload,
		gpu_create_texture           = null.create_texture,
		gpu_destroy_texture          = null.destroy_texture,
		gpu_destroy_buffer           = null.destroy_buffer,
		gpu_destroy_pipeline         = null.destroy_pipeline,
	}
	record: Hook_Record
	record.problems = make([dynamic]string)
	defer {
		for p in record.problems {
			delete(p)
		}
		delete(record.problems)
	}
	context.logger = {record_problems, &record, .Debug, {}}

	w := new(ecs.World)
	defer free(w)
	testing.expect(t, ecs.init(w, &platform))
	defer ecs.destroy(w)
	ecs.register_engine_components(&w.registry)
	register_components(&w.registry)
	dir, err := os.make_directory_temp("", "renderer_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Renderer)
	defer free(r)
	renderer_init(r, &platform, &assets, w)
	defer renderer_destroy(r)
	debug.line(&r.debug, {}, ecs.position_offset({}, {0, 0, 1}), {1, 0, 0, 1})
	debug.line(&r.debug, {}, ecs.position_offset({}, {0, 1, 0}), {0, 1, 0, 1}, mode = .Overlay)

	desc := Frame_Desc {
		view = {rotation = 1, vertical_fov = 1, near = 0.05},
		size = {64, 32},
		keep_ids = true,
		hooks = {
			data = &record,
			before_world = proc(f: ^Frame) {
				(^Hook_Record)(f.data).before_world = true
			},
			world_uses = proc(f: ^Frame, pass: Pass) {
				(^Hook_Record)(f.data).world_uses = true
			},
			world_draw = proc(f: ^Frame, ctx: ^Pass_Context) {
				rec := (^Hook_Record)(f.data)
				sync.guard(&rec.mutex)
				rec.world_pieces += 1
			},
			world_pieces = 2,
			// A post pass that writes a new scene color, which the output pass then reads.
			after_world = proc(f: ^Frame) {
				rec := (^Hook_Record)(f.data)
				rec.after_world = true
				post := create_texture(f.graph, {size = f.size, format = SCENE_FORMAT, label = "post"})
				p := add_compute_pass(f.graph, "post", proc(_: ^Pass_Context) {}, nil)
				read(f.graph, p, f.scene)
				write(f.graph, p, post)
				f.scene = post
				rec.post = post
			},
			ui = proc(f: ^Frame) {
				(^Hook_Record)(f.data).ui = true
				p := add_render_pass(f.graph, "hud", proc(_: ^Pass_Context) {}, nil)
				color(f.graph, p, f.ui, .Load)
			},
			debug = proc(f: ^Frame) {
				(^Hook_Record)(f.data).debug = f.debug != 0
				// The editor's tools read the IDs and the depth after the debug lines.
				p := add_compute_pass(f.graph, "pick", proc(_: ^Pass_Context) {}, nil)
				read(f.graph, p, f.ids)
				read(f.graph, p, f.depth)
			},
		},
	}
	testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
	testing.expect(t, record.before_world && record.world_uses && record.after_world && record.ui && record.debug)
	testing.expect_value(t, record.world_pieces, 2)
	testing.expect(t, record.post != 0)
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)
	// Lines of this frame only are gone after it.
	testing.expect_value(t, len(debug.frame_lines(&r.debug)), 0)

	// A frame without hooks or lines has no UI or debug layer, and the IDs and the depth are discarded.
	testing.expect(t, draw_frame(r, w, {view = desc.view, size = desc.size}))
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)
}

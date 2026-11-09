package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

// The skinning pass writes the entity's three buffers, and a pass that reads them, as the draws and the hit shading do,
// runs after it: the graph orders them, and the null backend validates the dispatch and the barriers between.
@(test)
the_skinning_pass_poses_the_vertices_before_the_passes_that_read_them :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator             = virtual.arena_allocator(&arena),
		heap_allocator              = runtime.heap_allocator(),
		jobs_run                    = jobs.run,
		jobs_wait                   = jobs.wait,
		gpu_frame_target            = null.frame_target,
		gpu_submit                  = null.submit,
		gpu_upload                  = null.upload,
		gpu_create_texture          = null.create_texture,
		gpu_destroy_texture         = null.destroy_texture,
		gpu_create_buffer           = null.create_buffer,
		gpu_destroy_buffer          = null.destroy_buffer,
		gpu_destroy_pipeline        = null.destroy_pipeline,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	skin_init(&r.scene.skins, &platform)
	defer skin_destroy(&r.scene.skins, &platform)
	r.scene.skins.pipeline.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "skin meshes"})

	rest := Resident_Mesh {
		positions        = platform.gpu_create_buffer({size = 36, label = "positions"}, nil),
		attributes       = platform.gpu_create_buffer({size = 48, label = "attributes"}, nil),
		skin             = platform.gpu_create_buffer({size = 48, label = "skin"}, nil),
		vertex_count     = 3,
		attribute_stride = 16,
	}
	defer {
		platform.gpu_destroy_buffer(rest.positions)
		platform.gpu_destroy_buffer(rest.attributes)
		platform.gpu_destroy_buffer(rest.skin)
	}
	pose := Skin_Pose {
		entity  = ecs.Entity(5),
		palette = make([][3][4]f32, 2, platform.frame_allocator),
		sphere  = {0, 1, 0, 2},
	}
	build := skin_build({pose}, platform.frame_allocator)
	instance, reset, ok := skin_instance(&r.scene.skins, &platform, 1, 0, pose.entity, rest.positions, rest.vertex_count, rest.attribute_stride)
	testing.expect(t, ok && reset)
	skin_add(&build, &rest, instance, 0, build.poses[pose.entity], reset)
	testing.expect_value(t, len(build.palette), 2)
	testing.expect_value(t, build.jobs[0].flags, SKIN_RESET)
	testing.expect_value(t, build.jobs[0].attribute_words, 4)

	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	g := begin(&platform, &cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {renderer = r, state = &r.view, graph = &g, size = {64, 32}}
	f.scene_frame = new(Scene_Frame, platform.frame_allocator)
	testing.expect(t, skin_upload(f, &build))
	add_skinning_pass(f)
	reader := add_compute_pass(&g, "reads skinned vertices", proc(ctx: ^Pass_Context) {}, f)
	declare_skinned_reads(f, reader)
	keep_pass(&g, reader)
	testing.expect_value(t, len(f.scene_frame.skin.buffers), 1)
	testing.expect(t, execute(&g), "the skinning pass did not execute")
}

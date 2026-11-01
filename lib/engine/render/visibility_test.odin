package render

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import format "cinnabar:engine/asset/format"

@(test)
the_shading_stats_are_the_newest_copy_that_came_back :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		heap_allocator     = runtime.heap_allocator(),
		gpu_create_buffer  = null.create_buffer,
		gpu_destroy_buffer = null.destroy_buffer,
		gpu_read_buffer    = null.read_buffer,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	s := &r.shading
	defer shading_destroy(s, &platform)
	for &b in s.stats_copies {
		b = platform.gpu_create_buffer({size = SHADING_STATS_WORDS * 4, usage = {.Readback}, label = "test"}, nil)
	}
	tally :: proc(s: ^Shading, i: int, quads, pixels: u32) {
		data, _ := null.read_buffer(s.stats_copies[i])
		words := mem.slice_data_cast([]u32, data)
		words[0], words[1] = quads, pixels
		s.stats_written[i] = true
	}
	// Two frames' copies, the older first: the newer is the one kept, and both are taken.
	s.stats_next = 1
	tally(s, 1, 10, 30)
	tally(s, 2, 20, 50)
	s.stats_next = 0
	read_shading_stats(r)
	testing.expect_value(t, shading_stats(r), Shading_Stats{forward_quads = 20, forward_pixels = 50})
	testing.expect(t, !s.stats_written[1] && !s.stats_written[2])
	// A copy that has not come back is kept for later.
	read_shading_stats(r)
	testing.expect_value(t, shading_stats(r).forward_quads, 20)
}

// visibility_blob is an opaque material blob of fake bytecode, which the null backend takes: each opaque pass's vertex
// and pixel stages and the mesh shader path's, and the visibility buffer's passes.
@(private = "file")
visibility_blob :: proc() -> []byte {
	code := []byte{1}
	variants := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
		append(&variants, format.Material_Variant_Entry{0, pass, .Vertex, code}, format.Material_Variant_Entry{0, pass, .Pixel, code})
		append(&variants, format.Material_Variant_Entry{0, pass, .Amplification, code}, format.Material_Variant_Entry{0, pass, .Mesh, code})
	}
	append(
		&variants,
		format.Material_Variant_Entry{0, .Visibility, .Amplification, code},
		format.Material_Variant_Entry{0, .Visibility, .Mesh, code},
		format.Material_Variant_Entry{0, .Visibility, .Pixel, code},
		format.Material_Variant_Entry{0, .Shade, .Compute, code},
	)
	contents := format.Material_Contents {
		block       = make([]byte, 16, context.temp_allocator),
		variants    = variants[:],
		source_path = "test.material",
	}
	return format.material_write(contents, context.temp_allocator)
}

@(test)
the_visibility_buffer_draws_its_bins_and_shades_them_before_the_world :: proc(t: ^testing.T) {
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
		jobs_run                     = jobs.run,
		jobs_wait                    = jobs.wait,
		gpu_frame_target             = null.frame_target,
		gpu_submit                   = null.submit,
		gpu_upload                   = null.upload,
		gpu_create_texture           = null.create_texture,
		gpu_destroy_texture          = null.destroy_texture,
		gpu_create_buffer            = null.create_buffer,
		gpu_destroy_buffer           = null.destroy_buffer,
		gpu_create_graphics_pipeline = null.create_graphics_pipeline,
		gpu_update_graphics_pipeline = null.update_graphics_pipeline,
		gpu_create_compute_pipeline  = null.create_compute_pipeline,
		gpu_update_compute_pipeline  = null.update_compute_pipeline,
		gpu_destroy_pipeline         = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.mesh_shaders = true
	defer visibility_destroy(&r.visibility, &platform)

	// Until a frame asks for the visibility buffer, the material has none of its pipelines.
	data := visibility_blob()
	blob, _ := format.material_view(data)
	p := &r.materials.pipelines[0]
	r.materials.pipeline_count = 1
	defer material_pipeline_destroy(p, &platform)
	make_pipelines(r, p, data, blob, 0)
	testing.expect(t, p.mesh_path && p.meshes[.Visibility] == {} && p.shade == {})
	request_visibility(r, true)
	testing.expect(t, r.materials.visibility)
	testing.expect_value(t, p.version, max(u32))
	make_pipelines(r, p, data, blob, 0)
	testing.expect(t, p.meshes[.Visibility] != {} && p.shade != {} && p.pipelines[.Visibility] == {})
	r.visibility.bin_pipeline.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test bins"})

	buffers := []gpu.Buffer {
		platform.gpu_create_buffer({size = 1024, usage = {.Storage, .Indirect}, label = "arguments"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage, .Indirect}, label = "mesh arguments"}, nil),
		platform.gpu_create_buffer({size = 256, usage = {.Storage, .Indirect}, label = "counts"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "draws"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil),
		platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil),
	}
	defer for b in buffers {
		platform.gpu_destroy_buffer(b)
	}
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	g := begin(&platform, &cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {renderer = r, graph = &g, size = {64, 32}, view_projection = 1}
	f.lights = new(Light_Frame, platform.frame_allocator)
	f.shadows = new(Shadow_Frame, platform.frame_allocator)
	f.exposure = import_buffer(&g, buffers[5])
	sf := new(Scene_Frame, platform.frame_allocator)
	f.scene_frame = sf
	sf.items = make([]Cull_Item, 1, platform.frame_allocator)
	sf.items[0].flags = ITEM_MESH_PATH
	sf.bin_pipelines, sf.bin_draws, sf.bin_impostors, sf.bin_particles = {0}, {0}, {false}, {false}
	sf.groups[.Opaque] = {0, 1}
	sf.bin_offsets, sf.bin_counts = {0}, {1}
	sf.view_count, sf.draw_views = FIRST_SHADOW_VIEW + 1, FIRST_SHADOW_VIEW + 1
	sf.view_constants = make([]gpu.Upload, sf.draw_views, platform.frame_allocator)
	for &c in sf.view_constants {
		c, _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
	}
	sf.arguments, sf.mesh_arguments = import_buffer(&g, buffers[0]), import_buffer(&g, buffers[1])
	sf.counts, sf.draws, sf.instances = import_buffer(&g, buffers[2]), import_buffer(&g, buffers[3]), import_buffer(&g, buffers[4])

	// Without the quality's visibility buffer, every bin draws forward.
	begin_visibility(f, false)
	testing.expect(t, f.visibility == nil && !visibility_bin(sf, 0, VIEW_CAMERA))
	// With it, the bin is the visibility buffer's in the camera's view, and the view model's and the shadow map's views
	// draw it as before.
	begin_visibility(f, true)
	testing.expect(t, f.visibility != nil)
	testing.expect(t, visibility_bin(sf, 0, VIEW_CAMERA))
	testing.expect(t, !visibility_bin(sf, 0, VIEW_VIEW_MODEL) && !visibility_bin(sf, 0, FIRST_SHADOW_VIEW))
	if f.visibility != nil {
		testing.expect_value(t, len(f.visibility.pipelines), 1)
	}

	f.scene = create_texture(&g, {size = f.size, format = SCENE_FORMAT, label = "scene"})
	f.ids = create_texture(&g, {size = f.size, format = ID_FORMAT, label = "ids"})
	f.normals = create_texture(&g, {size = f.size, format = NORMAL_FORMAT, label = "normals"})
	f.velocity = create_texture(&g, {size = f.size, format = VELOCITY_FORMAT, label = "velocity"})
	f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
	pass := add_render_pass(&g, "prepass", proc(ctx: ^Pass_Context) {
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_CAMERA, .Prepass)
	}, f)
	color(&g, pass, f.normals, .Clear)
	color(&g, pass, f.velocity, .Clear)
	depth(&g, pass, f.depth, .Clear)
	declare_scene_draws(f, pass)
	add_visibility_pass(f, late = false)
	add_visibility_shading(f, {0, 0, 0, 1})
	pass = add_render_pass(&g, "world", proc(ctx: ^Pass_Context) {
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_CAMERA, .Forward)
	}, f)
	color(&g, pass, f.scene, .Load)
	color(&g, pass, f.ids, .Load)
	depth(&g, pass, f.depth, .Load)
	declare_scene_draws(f, pass)
	declare_lighting(f, pass, opaque = true)
	keep_pass(&g, pass)
	names := make(map[string]int, platform.frame_allocator)
	for node in g.passes {
		names[node.name] += 1
	}
	for name in ([]string{"visibility", "clear scene", "visibility bin count", "visibility bin scatter", "visibility shading"}) {
		testing.expectf(t, names[name] == 1, "the frame has no %s pass", name)
	}
	// The null backend checks the visibility pass's targets against its pipeline's, the shading's dispatches against its
	// indirect arguments, and every barrier between them.
	testing.expect(t, execute(&g), "the visibility buffer's passes did not execute")
}

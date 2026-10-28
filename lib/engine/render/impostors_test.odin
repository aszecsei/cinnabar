package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import format "cinnabar:engine/asset/format"

// impostor_blob is an opaque material blob whose variants are fake bytecode, which the null backend takes: each
// opaque pass's vertex and pixel stages and the mesh shader path's, with the impostor passes' when impostor.
@(private = "file")
impostor_blob :: proc(impostor: bool, flags: format.Material_Flags = {}) -> []byte {
	code := []byte{1}
	variants := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
		append(&variants, format.Material_Variant_Entry{0, pass, .Vertex, code}, format.Material_Variant_Entry{0, pass, .Pixel, code})
		append(&variants, format.Material_Variant_Entry{0, pass, .Amplification, code}, format.Material_Variant_Entry{0, pass, .Mesh, code})
		if impostor {
			impostor_pass := format.material_impostor_pass(pass)
			append(&variants, format.Material_Variant_Entry{0, impostor_pass, .Vertex, code}, format.Material_Variant_Entry{0, impostor_pass, .Pixel, code})
		}
	}
	contents := format.Material_Contents {
		flags       = flags,
		block       = make([]byte, 16, context.temp_allocator),
		variants    = variants[:],
		source_path = "test.material",
	}
	return format.material_write(contents, context.temp_allocator)
}

@(test)
impostors_take_bins_of_their_own_and_draw_with_the_impostor_passes :: proc(t: ^testing.T) {
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
		gpu_destroy_pipeline         = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.mesh_shaders = true

	// A blob from before the impostor passes, and a billboard, which has none, draw no impostors.
	for c in ([]struct {
			impostor:  bool,
			flags:     format.Material_Flags,
			billboard: bool,
		}{{false, {}, false}, {false, {.Billboard, .Billboard_Axis}, true}}) {
		data := impostor_blob(c.impostor, c.flags)
		blob, _ := format.material_view(data)
		p: Material_Pipeline
		make_pipelines(r, &p, data, blob, 0)
		testing.expect(t, !p.impostor_path && p.pipelines[.Impostor_Forward] == {} && p.pipelines[.Forward] != {})
		testing.expect_value(t, p.billboard, c.billboard)
		material_pipeline_destroy(&p, &platform)
	}

	// With the impostor passes, each opaque pass has an impostor pipeline beside it.
	data := impostor_blob(true)
	blob, _ := format.material_view(data)
	make_pipelines(r, &r.materials.pipelines[0], data, blob, 0)
	r.materials.pipeline_count = 1
	p := &r.materials.pipelines[0]
	defer material_pipeline_destroy(p, &platform)
	testing.expect(t, p.impostor_path && p.mesh_path)
	for pass in ([]format.Material_Pass{.Forward, .Prepass, .Depth}) {
		testing.expect(t, p.pipelines[format.material_impostor_pass(pass)] != {})
	}

	// A pipeline's impostors are a bin after its own, and a bin of impostors is marked.
	sorting := []Sort_Item {
		{item = {bin = 1}, group = .Opaque},
		{item = {bin = 0, flags = ITEM_IMPOSTOR}, group = .Opaque},
		{item = {bin = 0, flags = ITEM_HAS_IMPOSTOR}, group = .Opaque},
	}
	items := make([]Cull_Item, len(sorting), context.temp_allocator)
	pipelines, groups := sort_bins(sorting, items, context.temp_allocator)
	testing.expect_value(t, len(pipelines), 3)
	testing.expect(t, pipelines[0] == 0 && pipelines[1] == 0 && pipelines[2] == 1)
	testing.expect_value(t, groups[.Opaque], [2]int{0, 3})
	impostors := bin_impostors(items, len(pipelines), context.temp_allocator)
	testing.expect(t, !impostors[0] && impostors[1] && !impostors[2])
	testing.expect(t, items[1].flags & ITEM_IMPOSTOR != 0 && items[1].bin == 1)

	buffers := []gpu.Buffer {
		platform.gpu_create_buffer({size = 1024, usage = {.Storage, .Indirect}, label = "arguments"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage, .Indirect}, label = "mesh arguments"}, nil),
		platform.gpu_create_buffer({size = 256, usage = {.Storage, .Indirect}, label = "counts"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "draws"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil),
	}
	defer for b in buffers {
		platform.gpu_destroy_buffer(b)
	}
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	g := begin(&platform, &cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {renderer = r, graph = &g, size = {64, 32}}
	sf := new(Scene_Frame, platform.frame_allocator)
	f.scene_frame = sf
	// The material is on the mesh shader path, but its impostors' bin draws quads with vertex pulling.
	sf.items = make([]Cull_Item, 1, platform.frame_allocator)
	sf.items[0].flags = ITEM_IMPOSTOR
	sf.bin_pipelines, sf.bin_draws, sf.bin_impostors, sf.bin_particles = {0}, {0}, {true}, {false}
	sf.groups[.Opaque] = {0, 1}
	sf.bin_offsets, sf.bin_counts = {0}, {1}
	sf.view_count = 1
	sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
	sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
	sf.arguments, sf.mesh_arguments = import_buffer(&g, buffers[0]), import_buffer(&g, buffers[1])
	sf.counts, sf.draws, sf.instances = import_buffer(&g, buffers[2]), import_buffer(&g, buffers[3]), import_buffer(&g, buffers[4])
	normals := create_texture(&g, {size = f.size, format = NORMAL_FORMAT, label = "normals"})
	velocity := create_texture(&g, {size = f.size, format = VELOCITY_FORMAT, label = "velocity"})
	f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
	pass := add_render_pass(&g, "prepass", proc(ctx: ^Pass_Context) {
		draw_scene_view((^Frame)(ctx.data), ctx.cb, VIEW_CAMERA, .Prepass)
	}, f)
	color(&g, pass, normals, .Clear)
	color(&g, pass, velocity, .Clear)
	depth(&g, pass, f.depth, .Clear)
	declare_scene_draws(f, pass)
	keep_pass(&g, pass)
	// The null backend checks that the indirect draw has a vertex pipeline bound, not a mesh one.
	testing.expect(t, execute(&g), "the impostors' prepass did not execute")
}

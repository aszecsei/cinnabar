package render

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import format "cinnabar:engine/asset/format"

@(test)
sorted_items_are_bins_of_their_own_from_back_to_front :: proc(t: ^testing.T) {
	sorting := []Sort_Item {
		{item = {bin = 2}, group = .Opaque},
		{item = {bin = 4, instance = 1}, group = .Sorted, distance = 1},
		{item = {bin = 1}, group = .Moments},
		{item = {bin = 0}, group = .Opaque},
		{item = {bin = 4, instance = 2}, group = .Sorted, distance = 9},
		{item = {bin = 1}, group = .Moments},
		{item = {bin = 3, instance = 3}, group = .Sorted, distance = 4},
		{item = {bin = 2}, group = .Opaque},
	}
	items := make([]Cull_Item, len(sorting), context.temp_allocator)
	pipelines, groups := sort_bins(sorting, items, context.temp_allocator)
	// A bin for each opaque pipeline, one for moment-based transparency's, and one for each sorted item, the farthest
	// first, though two of them share a pipeline.
	testing.expect(t, slice.equal(pipelines, []int{0, 2, 1, 4, 3, 4}))
	testing.expect_value(t, groups, [Bin_Group][2]int{.Opaque = {0, 2}, .Moments = {2, 3}, .Sorted = {3, 6}})
	bins := make([]u32, len(items), context.temp_allocator)
	instances := make([]u32, len(items), context.temp_allocator)
	for item, i in items {
		bins[i], instances[i] = item.bin, item.instance
	}
	testing.expect(t, slice.equal(bins, []u32{0, 1, 1, 2, 2, 3, 4, 5}))
	testing.expect(t, slice.equal(instances[5:], []u32{2, 3, 1}))
}

// transparent_blob is a material blob whose variants are fake bytecode, which the null backend takes, for each
// transparent pass that a blend has.
@(private = "file")
transparent_blob :: proc(blend: format.Material_Blend, flags: format.Material_Flags) -> []byte {
	code := []byte{1}
	variants := make([dynamic]format.Material_Variant_Entry, context.temp_allocator)
	passes := []format.Material_Pass{.Transparent, .Transparent_Ids, .Moments}
	for pass in passes[:blend == .Transparent ? 3 : 2] {
		append(&variants, format.Material_Variant_Entry{0, pass, .Vertex, code}, format.Material_Variant_Entry{0, pass, .Pixel, code})
	}
	contents := format.Material_Contents {
		flags       = flags,
		blend       = blend,
		block       = make([]byte, 16, context.temp_allocator),
		variants    = variants[:],
		source_path = "test.material",
	}
	return format.material_write(contents, context.temp_allocator)
}

@(test)
the_transparent_passes_match_their_pipelines :: proc(t: ^testing.T) {
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
		gpu_destroy_pipeline         = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.materials.defaults[.White] = platform.gpu_create_texture({size = {1, 1}, format = .RGBA8_Unorm, usage = {.Sampled}, label = "white"}, {255, 255, 255, 255})
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test composite"})
	fake_sprite_pipelines(r)
	defer sprites_destroy(&r.sprites, &platform)
	// A moment-based material, a sorted two-sided one, and an additive one.
	blobs := [][]byte{transparent_blob(.Transparent, {}), transparent_blob(.Transparent, {.Sorted, .Two_Sided}), transparent_blob(.Additive, {})}
	for data, i in blobs {
		blob, ok := format.material_view(data)
		testing.expect(t, ok)
		make_pipelines(r, &r.materials.pipelines[i], data, blob, 0)
	}
	r.materials.pipeline_count = len(blobs)
	defer for &p in r.materials.pipelines[:r.materials.pipeline_count] {
		material_pipeline_destroy(&p, &platform)
	}
	moments, sorted, additive := &r.materials.pipelines[0], &r.materials.pipelines[1], &r.materials.pipelines[2]
	testing.expect_value(t, material_group(moments), Bin_Group.Moments)
	testing.expect_value(t, material_group(sorted), Bin_Group.Sorted)
	testing.expect_value(t, material_group(additive), Bin_Group.Sorted)
	// Only moment-based transparency adds up its transparent pass; the others blend over the scene, a two-sided
	// material's back faces first.
	testing.expect(t, moments.pipelines[.Transparent] != {} && moments.over[0] == {} && moments.over[1] != {})
	testing.expect(t, sorted.pipelines[.Transparent] == {} && sorted.over[0] != {} && sorted.pipelines[.Moments] != {})
	testing.expect(t, additive.pipelines[.Moments] == {} && additive.over[1] != {})

	buffers := []gpu.Buffer {
		platform.gpu_create_buffer({size = 1024, usage = {.Storage, .Indirect}, label = "arguments"}, nil),
		platform.gpu_create_buffer({size = 256, usage = {.Storage, .Indirect}, label = "counts"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "draws"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil),
		platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage, .Indirect}, label = "mesh arguments"}, nil),
	}
	defer for b in buffers {
		platform.gpu_destroy_buffer(b)
	}
	defer platform.gpu_destroy_texture(r.materials.defaults[.White])
	for view in ([]Debug_View{.Lit, .Transparent_Overdraw}) {
		cache: Texture_Cache
		defer cache_destroy(&cache, &platform)
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, graph = &g, size = {64, 32}, debug_view = view}
		f.lights = new(Light_Frame, platform.frame_allocator)
		f.shadows = new(Shadow_Frame, platform.frame_allocator)
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sorting := []Sort_Item{{item = {bin = 0}, group = .Moments}, {item = {bin = 1}, group = .Sorted, distance = 4}, {item = {bin = 2}, group = .Sorted, distance = 1}}
		sf.items = make([]Cull_Item, len(sorting), platform.frame_allocator)
		sf.bin_pipelines, sf.groups = sort_bins(sorting, sf.items, platform.frame_allocator)
		sf.bin_draws = sf.bin_pipelines
		sf.bin_impostors = bin_impostors(sf.items, len(sf.bin_pipelines), platform.frame_allocator)
		sf.bin_offsets = {0, 1, 2}
		sf.bin_counts = {1, 1, 1}
		sf.view_count = 2
		sf.view_constants = make([]gpu.Upload, 2, platform.frame_allocator)
		for &c in sf.view_constants {
			c, _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		}
		sf.arguments, sf.counts = import_buffer(&g, buffers[0]), import_buffer(&g, buffers[1])
		sf.draws, sf.instances = import_buffer(&g, buffers[2]), import_buffer(&g, buffers[3])
		f.exposure = import_buffer(&g, buffers[4])
		sf.mesh_arguments = import_buffer(&g, buffers[5])
		f.scene = create_texture(&g, {size = f.size, format = SCENE_FORMAT, label = "scene"})
		f.ids = create_texture(&g, {size = f.size, format = ID_FORMAT, label = "ids"})
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		p := add_render_pass(&g, "world", proc(_: ^Pass_Context) {}, f)
		color(&g, p, f.scene, .Clear)
		color(&g, p, f.ids, .Clear)
		depth(&g, p, f.depth, .Clear)

		// Sprites draw among the moment-based surfaces.
		begin_sprites(f, {{size = 1, color = {1, 1, 1, 0.5}}}, &r.sprites.main)
		testing.expect(t, f.sprites != nil)
		add_transparency_passes(f)
		add_transparent_id_pass(f, keep_ids = true)
		testing.expect_value(t, f.moments_zeroth != 0, true)
		p = add_render_pass(&g, "output", proc(_: ^Pass_Context) {}, f)
		read(&g, p, f.scene)
		read(&g, p, f.ids)
		if view == .Transparent_Overdraw {
			read(&g, p, f.moments_zeroth)
		}
		color(&g, p, import_texture(&g, null.frame_target(), .Color), .Discard)
		// The null backend checks that each pipeline's targets are its pass's, and every barrier.
		testing.expectf(t, execute(&g), "the %v frame did not execute", view)
		null.begin_frame({64, 32})
	}
}

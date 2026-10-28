package render

import "base:runtime"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

@(test)
the_particle_pool_gives_and_takes_back_ranges :: proc(t: ^testing.T) {
	p := new(Particles)
	defer free(p)
	p.free[0], p.free_count = {0, 100}, 1
	a, ok_a := allocate_particles(p, 30)
	b, ok_b := allocate_particles(p, 30)
	c, ok_c := allocate_particles(p, 30)
	testing.expect(t, ok_a && ok_b && ok_c)
	testing.expect_value(t, a, Particle_Range{0, 30})
	testing.expect_value(t, c, Particle_Range{60, 30})
	_, ok := allocate_particles(p, 20)
	testing.expect(t, !ok)
	// A freed range in the middle is a range of its own, until those beside it join it.
	free_particles(p, b)
	testing.expect_value(t, p.free_count, 2)
	free_particles(p, a)
	testing.expect_value(t, p.free_count, 2)
	testing.expect_value(t, p.free[0], Particle_Range{0, 60})
	free_particles(p, c)
	testing.expect_value(t, p.free_count, 1)
	testing.expect_value(t, p.free[0], Particle_Range{0, 100})
	big, ok_big := allocate_particles(p, 100)
	testing.expect(t, ok_big && big == Particle_Range{0, 100} && p.free_count == 0)
	free_particles(p, big)
	testing.expect_value(t, p.free[0], Particle_Range{0, 100})
}

@(test)
the_particle_passes_append_sprites :: proc(t: ^testing.T) {
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
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.materials.defaults[.White] = platform.gpu_create_texture({size = {1, 1}, format = .RGBA8_Unorm, usage = {.Sampled}, label = "white"}, {255, 255, 255, 255})
	defer platform.gpu_destroy_texture(r.materials.defaults[.White])
	exposure := platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil)
	defer platform.gpu_destroy_buffer(exposure)
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test composite"})
	defer destroy_shader_pipeline(&r.transparency_composite, &platform)
	fake_sprite_pipelines(r)
	defer sprites_destroy(&r.sprites, &platform)
	p := &r.particles
	p.update.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test particle update"})
	p.history.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test particle history"})
	p.pool = platform.gpu_create_buffer({size = 1024 * PARTICLE_SIZE, usage = {.Storage}, label = "particles"}, nil)
	p.counters = platform.gpu_create_buffer({size = 64, usage = {.Storage}, label = "particle counters"}, nil)
	defer particles_destroy(p, &platform)

	// Two frames: the second reads the history that the first wrote.
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	for frame in 0 ..< 2 {
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, graph = &g, size = {64, 32}}
		f.lights = new(Light_Frame, platform.frame_allocator)
		f.shadows = new(Shadow_Frame, platform.frame_allocator)
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_count = 1
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		f.exposure = import_buffer(&g, exposure)
		begin_sprites(f, nil, &r.sprites.main)
		testing.expect(t, f.sprites != nil)

		// An emitter of 100 particles, as begin_particles writes it.
		target, reserved := reserve_sprites(f, 100)
		testing.expect(t, reserved)
		pf := new(Particle_Frame, platform.frame_allocator)
		pf.target, pf.count, pf.has_previous = target, 1, frame > 0
		record := Emitter_Record{capacity = 100, spawn = 10, reset = u32(frame == 0), lifetime = {1, 1}, curves = 0}
		pf.emitters, _ = upload_bytes(&platform, ([^]byte)(&record)[:size_of(record)])
		pf.modules, _ = platform.gpu_upload(size_of(format.Effect_Module), 16)
		pf.curves, _ = platform.gpu_upload(len(format.Effect_Curve) * size_of(format.Effect_Curve_Row), 16)
		pf.zeros, _ = platform.gpu_upload(4, 4)
		pf.constants, _ = platform.gpu_upload(size_of(Particle_Constants), gpu.PASS_CONSTANTS_ALIGN)
		f.particles = pf
		add_particle_passes(f)
		testing.expect(t, pf.history.current != 0)
		testing.expect_value(t, pf.history.valid, frame > 0)
		testing.expect_value(t, f.sprites.capacity, 100)

		f.scene = create_texture(&g, {size = f.size, format = SCENE_FORMAT, label = "scene"})
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		f.normals = create_texture(&g, {size = f.size, format = NORMAL_FORMAT, label = "normals"})
		pass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, f)
		color(&g, pass, f.normals, .Clear)
		depth(&g, pass, f.depth, .Clear)
		add_particle_history_pass(f)
		pass = add_render_pass(&g, "world", proc(_: ^Pass_Context) {}, f)
		color(&g, pass, f.scene, .Clear)
		depth(&g, pass, f.depth, .Load)
		add_transparency_passes(f)
		pass = add_render_pass(&g, "output", proc(_: ^Pass_Context) {}, f)
		read(&g, pass, f.scene)
		color(&g, pass, import_texture(&g, null.frame_target(), .Color), .Discard)
		// The null backend checks every pipeline and barrier, the history's included.
		testing.expectf(t, execute(&g), "frame %d did not execute", frame)
		null.begin_frame({64, 32})
	}
}

@(test)
an_effect_preview_plays_on_a_frame_of_its_own :: proc(t: ^testing.T) {
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
		asset_allocator             = runtime.heap_allocator(),
		file_read                   = core.file_read,
		file_modified               = core.file_modified,
		jobs_run                    = jobs.run,
		jobs_wait                   = jobs.wait,
		gpu_frame_target            = null.frame_target,
		gpu_submit                  = null.submit,
		gpu_upload                  = null.upload,
		gpu_create_texture          = null.create_texture,
		gpu_destroy_texture         = null.destroy_texture,
		gpu_create_buffer           = null.create_buffer,
		gpu_destroy_buffer          = null.destroy_buffer,
		gpu_create_sampler          = null.create_sampler,
		gpu_destroy_sampler         = null.destroy_sampler,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	// An empty cache: the preview's ground never becomes resident, so the effect plays over the background.
	dir, err := os.make_directory_temp("", "preview_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	residency_init(&r.residency, &platform, &assets)
	defer residency_destroy(&r.residency)
	materials_init(&r.materials, &platform)
	defer materials_destroy(&r.materials, &platform)
	previews_init(&r.previews, r)
	defer previews_destroy(&r.previews, r)
	r.post.unit_exposure = platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "unit exposure"}, nil)
	defer platform.gpu_destroy_buffer(r.post.unit_exposure)
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test composite"})
	defer destroy_shader_pipeline(&r.transparency_composite, &platform)
	fake_sprite_pipelines(r)
	defer sprites_destroy(&r.sprites, &platform)
	p := &r.particles
	p.update.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test particle update"})
	p.history.pipeline = platform.gpu_create_compute_pipeline({compute = {1}, label = "test particle history"})
	defer particles_destroy(p, &platform)
	target := platform.gpu_create_texture({size = {32, 32}, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "preview target"}, nil)
	defer platform.gpu_destroy_texture(target)

	// The editor's unsaved effect: one emitter of 64 particles.
	effect := format.guid_parse("00112233445566778899aabbccddeeff") or_else {}
	data := format.effect_write({guid = effect, emitters = {{emitter = {capacity = 64, rate = 100, lifetime = {1, 1}, flipbook = {1, 1}}, name = "puffs"}}}, context.temp_allocator)
	blob, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(blob, data)

	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	for frame in 0 ..< 2 {
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, graph = &g, size = {64, 32}}
		f.lut = create_texture(&g, {size = {16, 16}, format = .RGBA16_Float, label = "lut"})
		pass := add_render_pass(&g, "lut", proc(_: ^Pass_Context) {}, f)
		color(&g, pass, f.lut, .Clear)
		desc := Preview_Desc {
			target   = target,
			size     = {32, 32},
			id       = 1,
			material = effect,
			effect   = true,
			data     = blob,
			version  = 1,
			rotation = 1,
			distance = 4,
		}
		{
			// The ground's mesh and material are not cooked, which residency logs.
			context.logger = log.nil_logger()
			add_preview_passes(f, &desc)
		}
		// The effect's emitter took its range of the pool, and the preview's frame reserved its sprites.
		testing.expect(t, p.previews[1].started && p.previews[1].ranges[0].count == 64)
		testing.expect_value(t, p.preview_cameras[1].valid, true)
		testing.expectf(t, execute(&g), "preview frame %d did not execute", frame)
		null.begin_frame({64, 32})
	}
}

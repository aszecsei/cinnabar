package render

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
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
import "cinnabar:engine/ecs"

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
	r.materials.defaults[.White] = platform.gpu_create_texture(
		{size = {1, 1}, format = .RGBA8_Unorm, usage = {.Sampled}, label = "white"},
		{255, 255, 255, 255},
	)
	defer platform.gpu_destroy_texture(r.materials.defaults[.White])
	exposure := platform.gpu_create_buffer(
		{size = 16, usage = {.Storage}, label = "exposure"},
		nil,
	)
	defer platform.gpu_destroy_buffer(exposure)
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test composite"},
	)
	defer destroy_shader_pipeline(&r.transparency_composite, &platform)
	fake_sprite_pipelines(r)
	defer sprites_destroy(&r.sprites, &platform)
	p := &r.particles
	p.update.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test particle update"},
	)
	p.history.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test particle history"},
	)
	p.pool = platform.gpu_create_buffer(
		{size = 1024 * PARTICLE_SIZE, usage = {.Storage}, label = "particles"},
		nil,
	)
	p.counters = platform.gpu_create_buffer(
		{size = MAX_FRAME_EMITTERS * 2 * 4, usage = {.Storage}, label = "particle counters"},
		nil,
	)
	defer particles_destroy(p, &platform)

	// Two frames: the second reads the history that the first wrote.
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	for frame in 0 ..< 2 {
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		f.lights = new(Light_Frame, platform.frame_allocator)
		f.shadows = new(Shadow_Frame, platform.frame_allocator)
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_count = 1
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(
			size_of(Frame_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		f.exposure = import_buffer(&g, exposure)
		begin_sprites(f, nil, &r.sprites.main)
		testing.expect(t, f.sprites != nil)

		// An emitter of 100 particles, as begin_particles writes it.
		target, reserved := reserve_sprites(f, 100)
		testing.expect(t, reserved)
		pf := new(Particle_Frame, platform.frame_allocator)
		pf.target, pf.count, pf.has_previous = target, 1, frame > 0
		record := Emitter_Record {
			capacity = 100,
			spawn    = 10,
			reset    = u32(frame == 0),
			lifetime = {1, 1},
			curves   = 0,
		}
		pf.emitters, _ = upload_bytes(&platform, ([^]byte)(&record)[:size_of(record)])
		pf.modules, _ = platform.gpu_upload(size_of(format.Effect_Module), 16)
		pf.curves, _ = platform.gpu_upload(
			len(format.Effect_Curve) * size_of(format.Effect_Curve_Row),
			16,
		)
		pf.zeros, _ = platform.gpu_upload(4, 4)
		pf.constants, _ = platform.gpu_upload(
			size_of(Particle_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
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
	draw_effect_previews(t, 1, {32, 32})
}

@(test)
a_frame_with_four_previews_shares_their_targets :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	one := draw_effect_previews(t, 1, {32, 32})
	four := draw_effect_previews(t, gpu.MAX_PREVIEW_TARGETS, {32, 32})
	// The previews draw one after another, so each takes the textures of the one before it: four take what one does.
	testing.expect_value(t, four.textures, 1 + gpu.MAX_PREVIEW_TARGETS * (one.textures - 1))
	testing.expect_value(t, four.taken, one.taken)
	testing.expect_value(t, four.taken_bytes, one.taken_bytes)
	// At a size that the editor's panels draw them at.
	four = draw_effect_previews(t, gpu.MAX_PREVIEW_TARGETS, {512, 512})
	log.infof(
		"four previews at 512x512: %d transient textures, %.1f MiB; they take %d, %.1f MiB",
		four.textures,
		f64(four.bytes) / (1 << 20),
		four.taken,
		f64(four.taken_bytes) / (1 << 20),
	)
}

// draw_effect_previews draws two frames with count previews of an unsaved effect at one size, each into a target of its
// own, as the editor's previews draw, and returns what the last frame's transient textures took.
@(private = "file")
draw_effect_previews :: proc(t: ^testing.T, count: int, size: [2]u32) -> (stats: Transient_Stats) {
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
	r.post.unit_exposure = platform.gpu_create_buffer(
		{size = 16, usage = {.Storage}, label = "unit exposure"},
		nil,
	)
	defer platform.gpu_destroy_buffer(r.post.unit_exposure)
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test composite"},
	)
	defer destroy_shader_pipeline(&r.transparency_composite, &platform)
	fake_sprite_pipelines(r)
	defer sprites_destroy(&r.sprites, &platform)
	p := &r.particles
	p.update.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test particle update"},
	)
	p.history.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test particle history"},
	)
	defer particles_destroy(p, &platform)
	targets: [gpu.MAX_PREVIEW_TARGETS]gpu.Texture
	for &target in targets[:count] {
		target = platform.gpu_create_texture(
			{
				size = size,
				format = gpu.FRAME_TARGET_FORMAT,
				usage = {.Render_Target},
				label = "preview target",
			},
			nil,
		)
	}
	defer for target in targets[:count] {
		platform.gpu_destroy_texture(target)
	}

	// The editor's unsaved effect: one emitter of 64 particles.
	effect := format.guid_parse("00112233445566778899aabbccddeeff") or_else {}
	data := format.effect_write(
		{
			guid = effect,
			emitters = {
				{
					emitter = {capacity = 64, rate = 100, lifetime = {1, 1}, flipbook = {1, 1}},
					name = "puffs",
				},
			},
		},
		context.temp_allocator,
	)
	blob, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(blob, data)

	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)
	for frame in 0 ..< 2 {
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		f.lut = create_texture(&g, {size = {16, 16}, format = .RGBA16_Float, label = "lut"})
		pass := add_render_pass(&g, "lut", proc(_: ^Pass_Context) {}, f)
		color(&g, pass, f.lut, .Clear)
		for target, id in targets[:count] {
			desc := Preview_Desc {
				target   = target,
				size     = size,
				id       = id,
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
			testing.expect(t, p.previews[id].started && p.previews[id].ranges[0].count == 64)
			testing.expect_value(t, p.preview_cameras[id].valid, true)
		}
		testing.expectf(t, execute(&g), "preview frame %d did not execute", frame)
		stats = g.transients
		null.begin_frame({64, 32})
	}
	return
}

@(test)
ribbons_build_and_take_their_draws :: proc(t: ^testing.T) {
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
	p := &r.particles
	p.ribbon.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test ribbon build"},
	)
	p.pool = platform.gpu_create_buffer(
		{size = 1024 * PARTICLE_SIZE, usage = {.Storage}, label = "particles"},
		nil,
	)
	p.ribbon_vertices = platform.gpu_create_buffer(
		{size = 2048 * RIBBON_VERTEX_SIZE, usage = {.Storage}, label = "ribbon vertices"},
		nil,
	)
	defer particles_destroy(p, &platform)
	scene_buffers := []gpu.Buffer {
		platform.gpu_create_buffer(
			{size = 1024, usage = {.Storage, .Indirect}, label = "arguments"},
			nil,
		),
		platform.gpu_create_buffer({size = 256, usage = {.Storage}, label = "counts"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "draws"}, nil),
	}
	defer for b in scene_buffers {
		platform.gpu_destroy_buffer(b)
	}

	for stepped in ([]bool{false, true}) {
		cache: Texture_Cache
		defer cache_destroy(&cache, &platform)
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.items = make([]Cull_Item, 1, platform.frame_allocator)
		sf.items[0] = {
			flags = ITEM_RIBBON,
		}
		sf.ribbons = make([]Ribbon_Entry, 1, platform.frame_allocator)
		// A ribbon draws only once its system stepped, with its emitter's record.
		sf.ribbons[0] = {
			emitter      = 0,
			item         = 0,
			first_vertex = 0,
			record       = 0,
			stepped      = stepped,
		}
		sf.cull_constants, _ = platform.gpu_upload(
			size_of(Cull_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		sf.arguments, sf.counts, sf.draws =
			import_buffer(&g, scene_buffers[0]),
			import_buffer(&g, scene_buffers[1]),
			import_buffer(&g, scene_buffers[2])
		pf := new(Particle_Frame, platform.frame_allocator)
		pf.constants, _ = platform.gpu_upload(
			size_of(Particle_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		pf.pool = import_buffer(&g, p.pool)
		f.particles = pf
		pass := add_compute_pass(&g, "update", proc(_: ^Pass_Context) {}, f)
		write(&g, pass, pf.pool)
		write(&g, pass, sf.counts)
		add_ribbon_pass(f)
		pass = add_compute_pass(&g, "draw", proc(_: ^Pass_Context) {}, f)
		indirect_buffer(&g, pass, sf.arguments)
		read(&g, pass, sf.counts)
		read(&g, pass, sf.draws)
		keep_pass(&g, pass)
		testing.expect_value(t, len(g.passes), stepped ? 3 : 2)
		testing.expectf(
			t,
			execute(&g),
			"the frame with a ribbon stepped %v did not execute",
			stepped,
		)
		null.begin_frame({64, 32})
	}
}

@(test)
mesh_particles_take_their_draws :: proc(t: ^testing.T) {
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
	p := &r.particles
	p.meshes.pipeline = platform.gpu_create_compute_pipeline(
		{compute = {1}, label = "test particle meshes"},
	)
	p.counters = platform.gpu_create_buffer(
		{size = MAX_FRAME_EMITTERS * 2 * 4, usage = {.Storage}, label = "particle counters"},
		nil,
	)
	p.mesh_instances = platform.gpu_create_buffer(
		{size = 64 * size_of(Instance_Record), usage = {.Storage}, label = "particle instances"},
		nil,
	)
	defer particles_destroy(p, &platform)
	scene_buffers := []gpu.Buffer {
		platform.gpu_create_buffer(
			{size = 1024, usage = {.Storage, .Indirect}, label = "arguments"},
			nil,
		),
		platform.gpu_create_buffer({size = 256, usage = {.Storage}, label = "counts"}, nil),
		platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "draws"}, nil),
	}
	defer for b in scene_buffers {
		platform.gpu_destroy_buffer(b)
	}

	for stepped in ([]bool{false, true}) {
		cache: Texture_Cache
		defer cache_destroy(&cache, &platform)
		g := begin(&platform, &cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.items = make([]Cull_Item, 1, platform.frame_allocator)
		sf.items[0] = {
			flags = ITEM_PARTICLES,
		}
		sf.view_count = 3
		sf.mesh_particles = make([]Mesh_Particle_Entry, 1, platform.frame_allocator)
		// An emitter's items draw only once its system stepped, with its emitter's record.
		sf.mesh_particles[0] = {
			emitter = 0,
			item    = 0,
			record  = 0,
			stepped = stepped,
		}
		sf.cull_constants, _ = platform.gpu_upload(
			size_of(Cull_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		sf.arguments, sf.counts, sf.draws =
			import_buffer(&g, scene_buffers[0]),
			import_buffer(&g, scene_buffers[1]),
			import_buffer(&g, scene_buffers[2])
		pf := new(Particle_Frame, platform.frame_allocator)
		pf.constants, _ = platform.gpu_upload(
			size_of(Particle_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		pf.counters = import_buffer(&g, p.counters)
		pf.instances = import_buffer(&g, p.mesh_instances)
		sf.particle_instances = pf.instances
		f.particles = pf
		pass := add_compute_pass(&g, "update", proc(_: ^Pass_Context) {}, f)
		write(&g, pass, pf.counters)
		write(&g, pass, pf.instances)
		write(&g, pass, sf.counts)
		add_particle_mesh_pass(f)
		pass = add_compute_pass(&g, "draw", proc(_: ^Pass_Context) {}, f)
		indirect_buffer(&g, pass, sf.arguments)
		read(&g, pass, sf.counts)
		read(&g, pass, sf.draws)
		read(&g, pass, sf.particle_instances)
		keep_pass(&g, pass)
		testing.expect_value(t, len(g.passes), stepped ? 3 : 2)
		testing.expectf(
			t,
			execute(&g),
			"the frame with mesh particles stepped %v did not execute",
			stepped,
		)
		null.begin_frame({64, 32})
	}
}

// A mesh particles' item has a bin of its own after its material's, which draws with vertex pulling, as an impostor's
// does.
@(test)
mesh_particles_have_bins_of_their_own :: proc(t: ^testing.T) {
	items := []Cull_Item {
		{bin = 0, flags = ITEM_PARTICLES},
		{bin = 0},
		{bin = 0, flags = ITEM_MESH_PATH},
	}
	sorting := make([]Sort_Item, len(items), context.temp_allocator)
	for item, i in items {
		sorting[i] = {
			item = item,
		}
	}
	pipelines, groups := sort_bins(sorting, items, context.temp_allocator)
	testing.expect_value(t, len(pipelines), 2)
	testing.expect_value(t, groups[.Opaque], [2]int{0, 2})
	particles := bin_particles(items, len(pipelines), context.temp_allocator)
	testing.expect_value(t, particles[0], false)
	testing.expect_value(t, particles[1], true)
	testing.expect_value(t, items[2].flags & ITEM_PARTICLES, ITEM_PARTICLES)
	testing.expect_value(t, items[2].bin, 1)
}

// reach_random steps a test generator, and gives a number in [0, 1).
@(private = "file")
reach_random :: proc(state: ^u32) -> f32 {
	state^ = state^ * 1664525 + 1013904223
	return f32(state^ >> 8) / f32(1 << 24)
}

// A mesh emitter's sphere holds every particle of a system that moves while it spawns them, which a CPU copy of the
// update's steps moves with gravity, drag and noise (see particle_update.hlsl).
@(test)
a_mesh_particles_sphere_holds_the_particles_that_move :: proc(t: ^testing.T) {
	shapes := [?]format.Effect_Shape{.Point, .Sphere, .Box, .Cone}
	for shape in shapes {
		em := format.Effect_Emitter {
			lifetime   = {1, 2},
			speed      = {-1, 4},
			shape      = shape,
			shape_size = {0.5, 0.25, 0.75},
		}
		modules := []format.Effect_Module {
			{kind = .Gravity, values = {0, -9.8, 2, 0}},
			{kind = .Drag, values = {0.5, 0, 0, 0}},
			{kind = .Noise, values = {6, 1.5, 0, 0}},
		}
		size: format.Effect_Curve_Row
		for &sample in size {
			sample = {1.5, 0, 0, 0}
		}
		mesh := [4]f32{0.25, 0, 0, 0.5}
		slot := Particle_Slot {
			started    = true,
			reach_span = 2.0 / PARTICLE_REACH_SPANS,
		}
		Particle :: struct {
			position, velocity: [3]f32,
			age, lifetime:      f32,
			seed:               u32,
		}
		particles: [dynamic]Particle
		defer delete(particles)
		state := u32(7)
		dt: f32 = 1.0 / 60
		worst: f32
		for frame in 0 ..< 600 {
			// The system moves along x, then turns back, and grows.
			pose := ecs.Transform {
				position = ecs.position_offset(
					{},
					{f32(frame) * 0.05 if frame < 300 else 30 - f32(frame - 300) * 0.1, 0, 0},
				),
				rotation = 1,
				scale    = {1 + f32(frame) * 0.002, 1, 1},
			}
			particle_reach_sample(&slot, pose)
			sphere := particle_sphere(&slot, em, modules, size, mesh)
			testing.expect(t, sphere.w >= 0)
			// The update: the particles that live step, and new ones start in the shape.
			for i := len(particles) - 1; i >= 0; i -= 1 {
				p := &particles[i]
				p.age += dt
				if p.age >= p.lifetime {
					unordered_remove(&particles, i)
					continue
				}
				p.velocity += [3]f32{0, -9.8, 2} * dt
				p.velocity *= math.exp(-0.5 * dt)
				q := p.position * 1.5 + f32(p.seed & 255) * 0.01
				field := [3]f32 {
					math.sin(q.y) + math.cos(q.z),
					math.sin(q.z) + math.cos(q.x),
					math.sin(q.x) + math.cos(q.y),
				}
				p.velocity += field * 6 * dt
				p.position += p.velocity * dt
			}
			for _ in 0 ..< 4 {
				z := reach_random(&state) * 2 - 1
				phi := reach_random(&state) * math.TAU
				r := math.sqrt(1 - z * z)
				direction := [3]f32{r * math.cos(phi), z, r * math.sin(phi)}
				local: [3]f32
				switch shape {
				case .Point:
				case .Sphere:
					local = direction * 0.5 * math.pow(reach_random(&state), 1.0 / 3.0)
				case .Box:
					local =
						([3]f32{reach_random(&state), reach_random(&state), reach_random(&state)} *
								2 -
							1) *
						[3]f32{0.5, 0.25, 0.75}
				case .Cone:
					local = {0.5, 0, 0} * math.sqrt(reach_random(&state))
					direction = {0, 1, 0}
				}
				// The pose's offset from the anchor, which scales the shape along x.
				offset := ecs.position_sub(pose.position, slot.anchor)
				p := Particle {
					position = offset + local * pose.scale,
					velocity = direction * (-1 + 5 * reach_random(&state)),
					lifetime = 1 + reach_random(&state),
					seed     = u32(frame),
				}
				p.age = reach_random(&state) * dt
				p.position += p.velocity * p.age
				append(&particles, p)
			}
			for p in particles {
				// The mesh's sphere turns about the particle's position, scaled by the size curve.
				far := linalg.length(p.position) + (linalg.length(mesh.xyz) + mesh.w) * 1.5
				worst = max(worst, far)
				testing.expectf(
					t,
					far <= sphere.w + linalg.length(mesh.xyz),
					"%v: a particle at %v reaches %v, past the sphere's %v",
					shape,
					p.position,
					far,
					sphere.w,
				)
			}
			slot.age += dt
		}
		testing.expectf(t, worst > 5, "%v: the particles did not move far (%v)", shape, worst)
	}
}

// An emitter whose modules do not bound its particles, a collision or a drag that speeds them up, gives a sphere with no
// radius.
@(test)
a_mesh_particles_sphere_is_unbounded_without_a_bound :: proc(t: ^testing.T) {
	slot := Particle_Slot {
		started    = true,
		reach_span = 0.25,
	}
	em := format.Effect_Emitter {
		lifetime = {1, 2},
		speed    = {1, 2},
	}
	size: format.Effect_Curve_Row
	for kind in ([]format.Effect_Module_Kind{.Collide, .Drag}) {
		modules := []format.Effect_Module{{kind = kind, values = {-1, 0.5, 0, 0}}}
		sphere := particle_sphere(&slot, em, modules, size, {1, 2, 3, 1})
		testing.expect(t, sphere.w < 0, "the sphere has a radius")
		testing.expect_value(t, sphere.xyz, [3]f32{1, 2, 3})
	}
	// A drag that slows them down bounds them.
	modules := []format.Effect_Module{{kind = .Drag, values = {1, 0, 0, 0}}}
	testing.expect(t, particle_sphere(&slot, em, modules, size, {1, 2, 3, 1}).w >= 0)
}

// A system's reach keeps the spans of its time that its particles live in, and drops the ones before them.
@(test)
a_systems_reach_forgets_the_spans_before_its_particles :: proc(t: ^testing.T) {
	slot := Particle_Slot {
		started    = true,
		reach_span = 1,
	}
	far := ecs.Transform {
		position = ecs.position_offset({}, {10, 0, 0}),
		rotation = 1,
		scale    = 1,
	}
	near := ecs.Transform {
		rotation = 1,
		scale    = 1,
	}
	particle_reach_sample(&slot, far)
	em := format.Effect_Emitter {
		lifetime = {1, 1},
	}
	size: format.Effect_Curve_Row
	held := particle_sphere(&slot, em, nil, size, {})
	testing.expect_value(t, held.w, f32(10))
	slot.age = PARTICLE_REACH_SPANS - 1
	particle_reach_sample(&slot, near)
	testing.expect_value(t, particle_sphere(&slot, em, nil, size, {}).w, f32(10))
	slot.age = PARTICLE_REACH_SPANS + 1
	particle_reach_sample(&slot, near)
	testing.expect_value(t, particle_sphere(&slot, em, nil, size, {}).w, f32(0))
}

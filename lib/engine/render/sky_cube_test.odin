package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import core "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"

// Each level's cubemap goes down to faces 4 wide, and its mips' roughness from a mirror at mip 0 to 1 at the last.
@(test)
the_sky_cubes_mips_run_from_a_mirror_to_roughness_one :: proc(t: ^testing.T) {
	testing.expect_value(t, sky_cube_mips(SKY_CUBE_PARAMS[.Low].face), 5)
	testing.expect_value(t, sky_cube_mips(SKY_CUBE_PARAMS[.High].face), 6)
	testing.expect_value(t, sky_cube_mips(SKY_CUBE_PARAMS[.Ultra].face), 7)
	testing.expect_value(t, sky_cube_mips(4), 1)
	testing.expect_value(t, sky_cube_mips(1 << 12), SKY_CUBE_MAX_MIPS)
	testing.expect_value(t, sky_cube_roughness(0, 6), 0)
	testing.expect_value(t, sky_cube_roughness(5, 6), 1)
	testing.expect_value(t, sky_cube_roughness(2, 5), 0.5)
	testing.expect_value(t, sky_cube_roughness(0, 1), 0)
	for params in SKY_CUBE_PARAMS {
		testing.expect(t, params.format == .RGBA16_Float || params.format == .RG11B10_Float)
		testing.expect(t, params.samples > 0)
	}
}

// What one frame of the sky's cubemap did: its passes and its work.
@(private = "file")
Sky_Cube_Run :: struct {
	passes:    map[string]int,
	reads:     Sky_Cube_Reads,
	capture:   bool,
	source:    Sky_Cube_Source,
	first_mip: u32,
	mip_count: u32,
}

@(private = "file")
run_sky_cube_frame :: proc(
	t: ^testing.T,
	r: ^Renderer,
	cache: ^Texture_Cache,
	s: Sky_Settings,
	level: Quality_Level,
	ambient: Ambient,
) -> (
	run: Sky_Cube_Run,
) {
	platform := r.platform
	g := begin(platform, cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {
		renderer = r, state = &r.view,
		graph    = &g,
		size     = {64, 32},
	}
	// An atmosphere's tables, of which the capture reads the sky view.
	if s.mode == .Atmosphere {
		f.sky = new(Sky_Frame, platform.frame_allocator)
		f.sky.upload, _ = platform.gpu_upload(256, gpu.PASS_CONSTANTS_ALIGN)
		f.sky.view = create_texture(
			&g,
			{size = SKY_VIEW_SIZE, format = SKY_FORMAT, label = "sky view"},
		)
		p := add_compute_pass(&g, "sky view", proc(_: ^Pass_Context) {}, nil)
		write(&g, p, f.sky.view)
	}
	begin_sky_cube(f, s, level, ambient)
	add_sky_cube_passes(f)
	p := add_compute_pass(&g, "forward", proc(_: ^Pass_Context) {}, nil)
	declare_sky_cube_reads(f, p)
	keep_pass(&g, p)
	if cf := f.sky_cube; cf != nil {
		run.reads, run.capture, run.source, run.first_mip, run.mip_count =
			cf.reads, cf.capture, cf.source, cf.first_mip, cf.mip_count
	}
	testing.expect(t, execute(&g), "the frame did not execute")
	// The graph culls the passes as it executes.
	run.passes = make(map[string]int, platform.frame_allocator)
	for node in g.passes {
		if node.live {
			run.passes[node.name] += 1
		}
	}
	return
}

// The first frame makes every mip and the readers sample it from the next. A sky that changes builds the next cube a
// mip a frame, then turns the ring, and the new cube blends in over as many frames. A sky that stays the same costs no
// passes, and a level of another size starts over.
@(test)
the_sky_cube_builds_a_mip_a_frame_and_blends_in :: proc(t: ^testing.T) {
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
		gpu_create_texture_view     = null.create_texture_view,
		gpu_destroy_texture         = null.destroy_texture,
		gpu_create_buffer           = null.create_buffer,
		gpu_destroy_buffer          = null.destroy_buffer,
		gpu_create_sampler          = null.create_sampler,
		gpu_destroy_sampler         = null.destroy_sampler,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	c := &r.sky.cube
	for p in ([]^Shader_Pipeline{&c.capture, &c.atmosphere, &c.prefilter}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test"})
	}
	defer sky_cube_destroy(c, r)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	flat := Sky_Settings {
		mode              = .Flat,
		sky               = {0.4, 0.5, 0.9},
		ground            = {0.2, 0.1, 0.05},
		ambient_intensity = 1,
	}
	day := flat_ambient(flat.sky, flat.ground)
	mips := sky_cube_mips(SKY_CUBE_PARAMS[.High].face)

	run := run_sky_cube_frame(t, r, &cache, flat, .High, day)
	testing.expect_value(t, run.reads.mips, 0)
	testing.expect(t, run.capture && run.source == .Ambient)
	testing.expect_value(t, run.mip_count, mips)
	testing.expect_value(t, run.passes["sky cube capture"], 1)
	testing.expect_value(t, run.passes["sky cube prefilter"], 1)
	free_all(platform.frame_allocator)

	run = run_sky_cube_frame(t, r, &cache, flat, .High, day)
	testing.expect_value(t, run.reads.mips, f32(mips))
	testing.expect_value(t, run.reads.blend, 1)
	testing.expect_value(t, run.reads.previous, run.reads.current)
	testing.expect_value(t, run.mip_count, 0)
	testing.expect_value(t, run.passes["sky cube capture"], 0)
	testing.expect_value(t, run.passes["sky cube prefilter"], 0)
	first := run.reads.current
	free_all(platform.frame_allocator)

	// A new color: the first frame captures and prefilters mip 0, then one mip a frame, and the old cube stays.
	dusk := flat_ambient({0.8, 0.4, 0.2}, flat.ground)
	for frame in 0 ..< mips {
		run = run_sky_cube_frame(t, r, &cache, flat, .High, dusk)
		testing.expect_value(t, run.reads.current, first)
		testing.expect_value(t, run.capture, frame == 0)
		testing.expect_value(t, run.passes["sky cube capture"], frame == 0 ? 1 : 0)
		testing.expect_value(t, run.first_mip, u32(frame))
		testing.expect_value(t, run.mip_count, 1)
		free_all(platform.frame_allocator)
	}
	// The ring turned: the new cube blends in over the old one.
	for frame in 0 ..< mips {
		run = run_sky_cube_frame(t, r, &cache, flat, .High, dusk)
		testing.expect(t, run.reads.current != first)
		testing.expect_value(t, run.reads.previous, first)
		testing.expect_value(t, run.reads.blend, f32(frame + 1) / f32(mips))
		testing.expect_value(t, run.mip_count, 0)
		free_all(platform.frame_allocator)
	}
	testing.expect_value(t, run.reads.blend, 1)
	second := run.reads.current

	// A sky that changes every frame starts each build when the last one ends, so the blend never stops.
	for frame in 0 ..< 2 * mips {
		sky := flat_ambient({0.1 * f32(frame), 0.4, 0.2}, flat.ground)
		run = run_sky_cube_frame(t, r, &cache, flat, .High, sky)
		testing.expect_value(t, run.capture, frame % mips == 0)
		testing.expect_value(t, run.mip_count, 1)
		if frame == mips {
			testing.expect_value(t, run.reads.previous, second)
			testing.expect_value(t, run.reads.blend, 1 / f32(mips))
		}
		free_all(platform.frame_allocator)
	}

	// The atmosphere captures from its sky view table.
	atmosphere := flat
	atmosphere.mode = .Atmosphere
	for _ in 0 ..< mips + 1 {
		run = run_sky_cube_frame(t, r, &cache, atmosphere, .High, day)
		free_all(platform.frame_allocator)
	}
	testing.expect(t, c.ring.key.source == .Atmosphere || c.ring.build_key.source == .Atmosphere)
	// A texture sky whose texture is not resident takes the ambient light.
	texture := flat
	texture.mode, texture.texture_intensity = .Texture, 1
	for _ in 0 ..< 2 * mips + 1 {
		run = run_sky_cube_frame(t, r, &cache, texture, .High, day)
		free_all(platform.frame_allocator)
	}
	testing.expect_value(t, c.ring.key.source, Sky_Cube_Source.Ambient)
	testing.expect(t, c.ring.key.ambient == day)

	// Another level's size starts over: every mip, at once.
	run = run_sky_cube_frame(t, r, &cache, flat, .Low, day)
	testing.expect_value(t, run.reads.mips, 0)
	testing.expect_value(t, run.mip_count, sky_cube_mips(SKY_CUBE_PARAMS[.Low].face))
	testing.expect_value(t, c.params, SKY_CUBE_PARAMS[.Low])
	free_all(platform.frame_allocator)
	run = run_sky_cube_frame(t, r, &cache, flat, .Low, day)
	testing.expect_value(t, run.reads.mips, f32(sky_cube_mips(SKY_CUBE_PARAMS[.Low].face)))
	free_all(platform.frame_allocator)
}

// The atmosphere's capture needs its tables, which a frame without its pipelines does not make: it then takes the
// ambient light, which is the atmosphere's too.
@(test)
an_atmosphere_without_its_tables_captures_the_ambient_light :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := core.Platform_API {
		frame_allocator             = virtual.arena_allocator(&arena),
		heap_allocator              = runtime.heap_allocator(),
		gpu_create_texture          = null.create_texture,
		gpu_create_texture_view     = null.create_texture_view,
		gpu_destroy_texture         = null.destroy_texture,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	c := &r.sky.cube
	for p in ([]^Shader_Pipeline{&c.capture, &c.atmosphere, &c.prefilter}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test"})
	}
	defer sky_cube_destroy(c, r)
	g := Graph {
		commits = make([dynamic]Commit, platform.frame_allocator),
	}
	f := Frame {
		renderer = r, state = &r.view,
		graph    = &g,
	}
	s := Sky_Settings {
		mode              = .Atmosphere,
		ambient_intensity = 1,
	}
	ambient := Ambient {
		constant = {0.3, 0.4, 0.6},
	}
	begin_sky_cube(&f, s, .Medium, ambient)
	testing.expect(t, f.sky_cube != nil && f.sky_cube.capture)
	testing.expect_value(t, f.sky_cube.source, Sky_Cube_Source.Ambient)
	// The ring takes the capture's key only when the frame executes.
	testing.expect(t, f.sky_cube.next.key.ambient == ambient)
	testing.expect(t, !c.ring.valid)
}

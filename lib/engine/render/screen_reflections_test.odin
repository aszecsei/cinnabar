package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"

// Each level of the depth pyramid is half the one before, rounded up, down to a texel.
@(test)
the_depth_pyramid_halves_and_rounds_up :: proc(t: ^testing.T) {
	size := [2]u32{1279, 721}
	before := size
	for level in 0 ..< SSR_DEPTH_LEVELS {
		s := ssr_level_size(size, level)
		if level == 0 {
			testing.expect_value(t, s, size)
		} else {
			testing.expect_value(t, s, (before + 1) / 2)
		}
		before = s
	}
	testing.expect_value(t, ssr_level_size(size, 8), [2]u32{5, 3})
	testing.expect_value(t, ssr_level_size({1, 1}, 8), [2]u32{1, 1})
}

@(test)
the_screen_reflections_run_on_the_compute_queue_and_skip_without_their_technique :: proc(t: ^testing.T) {
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
		gpu_create_sampler          = null.create_sampler,
		gpu_destroy_sampler         = null.destroy_sampler,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	code := []byte{1}
	s := &r.ssr
	for p in ([]^Shader_Pipeline{&s.depth, &s.trace, &s.resolve, &s.temporal, &s.lit}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	defer screen_reflections_destroy(s, &platform)
	// No GUID, so the residency is never asked: the test's texture is the noise.
	r.blue_noise.texture = platform.gpu_create_texture({size = {BLUE_NOISE_SIZE, BLUE_NOISE_SIZE}, layers = BLUE_NOISE_SLICES, format = .RGBA8_Unorm, usage = {.Sampled, .Storage}, label = "noise"}, nil)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	exposure := platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil)
	defer platform.gpu_destroy_buffer(exposure)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	Result :: struct {
		passes:      map[string]int,
		reflections: bool,
		valid:       bool,
		shares_lit:  bool,
	}
	run_frame :: proc(t: ^testing.T, r: ^Renderer, cache: ^Texture_Cache, exposure: gpu.Buffer, settings: Reflection_Settings, gi_lit := false) -> (result: Result) {
		platform := r.platform
		g := begin(platform, cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, graph = &g, size = {64, 32}}
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		f.normals = create_texture(&g, {size = f.size, format = NORMAL_FORMAT, label = "normals"})
		f.velocity = create_texture(&g, {size = f.size, format = VELOCITY_FORMAT, label = "velocity"})
		f.roughness = create_texture(&g, {size = f.size, format = ROUGHNESS_FORMAT, label = "roughness"})
		f.scene = create_texture(&g, {size = f.size, format = SCENE_FORMAT, label = "scene"})
		f.exposure = import_buffer(&g, exposure)
		prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
		depth(&g, prepass, f.depth, .Clear)
		color(&g, prepass, f.normals, .Clear)
		color(&g, prepass, f.velocity, .Clear)
		color(&g, prepass, f.roughness, .Clear)
		// The global illumination's lit scene, as begin_gi keeps it.
		if gi_lit {
			f.gi = new(Gi_Frame, platform.frame_allocator)
			f.gi.lit_size = (f.size + 1) / 2
			f.gi.lit = history_texture(&g, {size = f.gi.lit_size, format = GI_FORMAT, label = "gi lit scene"})
		}
		begin_screen_reflections(f, settings)
		add_screen_reflection_passes(f)
		world := add_render_pass(&g, "world", proc(_: ^Pass_Context) {}, nil)
		color(&g, world, f.scene, .Clear)
		if f.reflections != 0 {
			read(&g, world, f.reflections)
		}
		if gi_lit {
			p := add_compute_pass(&g, "gi lit scene", proc(_: ^Pass_Context) {}, nil)
			read(&g, p, f.scene)
			write(&g, p, f.gi.lit.current)
		}
		add_screen_reflection_lit(f)
		keep_pass(&g, world)
		result.passes = make(map[string]int, platform.frame_allocator)
		for node in g.passes {
			result.passes[node.name] += 1
			switch node.name {
			case "reflections depth", "reflections trace", "reflections resolve", "reflections temporal":
				testing.expectf(t, node.queue == .Compute, "%s is on the %v queue", node.name, node.queue)
			case "reflections lit scene":
				testing.expectf(t, node.queue == .Graphics, "%s is on the %v queue", node.name, node.queue)
			}
		}
		result.reflections = f.reflections != 0
		if f.ssr != nil {
			result.valid = f.ssr.history.valid
			result.shares_lit = f.ssr.shares_lit
			testing.expect(t, f.reflections == f.ssr.history.current)
		}
		testing.expect(t, execute(&g), "the frame did not execute")
		return
	}

	for level in Quality_Level {
		for frame in 0 ..< 2 {
			res := run_frame(t, r, &cache, exposure, {technique = .Screen, level = level})
			testing.expectf(t, res.reflections, "%v: no reflections", level)
			testing.expect_value(t, res.passes["reflections depth"], 2)
			testing.expect_value(t, res.passes["reflections trace"], 1)
			testing.expect_value(t, res.passes["reflections resolve"], 1)
			testing.expect_value(t, res.passes["reflections temporal"], 1)
			testing.expect_value(t, res.passes["reflections lit scene"], 1)
			// The history is at the scene's size at every level, so it carries over from every frame but the first.
			first := level == .Low && frame == 0
			testing.expectf(t, res.valid == !first, "%v, frame %d: the history's validity is %v", level, frame, res.valid)
			free_all(platform.frame_allocator)
		}
	}

	// At half resolution, the global illumination's lit scene serves, and the reflections keep none.
	res := run_frame(t, r, &cache, exposure, {technique = .Screen, level = .Medium}, gi_lit = true)
	testing.expect(t, res.reflections && res.shares_lit)
	testing.expect_value(t, res.passes["reflections lit scene"], 0)
	testing.expect_value(t, res.passes["reflections trace"], 1)
	free_all(platform.frame_allocator)
	// At full resolution, it does not.
	res = run_frame(t, r, &cache, exposure, {technique = .Screen, level = .High}, gi_lit = true)
	testing.expect(t, res.reflections && !res.shares_lit)
	testing.expect_value(t, res.passes["reflections lit scene"], 1)
	free_all(platform.frame_allocator)

	// Off, the probes alone, or off by a volume: no texture and no pass.
	for settings in ([]Reflection_Settings{{technique = .Off}, {technique = .Probes, level = .High}, {off = true, technique = .Screen, level = .High}}) {
		res = run_frame(t, r, &cache, exposure, settings)
		testing.expectf(t, !res.reflections, "%v has reflections", settings)
		for name in ([]string{"reflections depth", "reflections trace", "reflections resolve", "reflections temporal", "reflections lit scene"}) {
			testing.expectf(t, res.passes[name] == 0, "%v has %s", settings, name)
		}
		free_all(platform.frame_allocator)
	}

	// Without a pipeline, or without the noise, nothing runs either.
	trace := s.trace.pipeline
	s.trace.pipeline = {}
	res = run_frame(t, r, &cache, exposure, {technique = .Screen, level = .High})
	testing.expect(t, !res.reflections && res.passes["reflections depth"] == 0)
	free_all(platform.frame_allocator)
	s.trace.pipeline = trace
	noise := r.blue_noise.texture
	r.blue_noise.texture = {}
	res = run_frame(t, r, &cache, exposure, {technique = .Screen, level = .High})
	testing.expect(t, !res.reflections && res.passes["reflections depth"] == 0)
	free_all(platform.frame_allocator)
	r.blue_noise.texture = noise
}

package render

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"

// The traced reflections' passes, by name, on the compute queue.
@(private = "file")
TRACED_PASSES :: [?]string {
	"reflections ray trace",
	"reflections clear hit bins",
	"reflections count hit bins",
	"reflections place hit bins",
	"reflections scatter hit bins",
	"reflections hit shading",
	"reflections hit light",
	"reflections hit screen",
	"reflections ray light",
	"reflections resolve",
	"reflections temporal",
}

@(test)
the_traced_reflections_shade_one_batch_and_fall_back_to_the_screen :: proc(t: ^testing.T) {
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
		gpu_create_accel            = null.create_accel,
		gpu_destroy_accel           = null.destroy_accel,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.ray_query = true
	code := []byte{1}
	s := &r.ssr
	pipelines := []^Shader_Pipeline{&s.depth, &s.trace, &s.resolve, &s.temporal, &s.lit, &r.rtr.trace, &r.rtr.light, &r.ray_scene.bin_pipeline, &r.ray_scene.fallback, &r.gi.probes.light, &r.gi.probes.screen}
	for p in pipelines {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	defer screen_reflections_destroy(s, &platform)
	defer traced_reflections_destroy(&r.rtr, &platform)
	defer gi_destroy(&r.gi, &platform)
	r.ray_scene.accel = platform.gpu_create_accel({kind = .Top, max_instances = 4, label = "test scene"})
	defer ray_scene_destroy(&r.ray_scene, &platform)
	// No GUID, so the residency is never asked: the test's texture is the noise.
	r.blue_noise.texture = platform.gpu_create_texture({size = {BLUE_NOISE_SIZE, BLUE_NOISE_SIZE}, layers = BLUE_NOISE_SLICES, format = .RGBA8_Unorm, usage = {.Sampled, .Storage}, label = "noise"}, nil)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	instances := platform.gpu_create_buffer({size = 1024, usage = {.Storage}, label = "instances"}, nil)
	defer platform.gpu_destroy_buffer(instances)
	exposure := platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil)
	defer platform.gpu_destroy_buffer(exposure)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	Options :: struct {
		// The frame has no hit table, its hit shading's batches are taken, or its traced reflections march no steps.
		no_hit_table: bool,
		batches_full: bool,
		no_march:     bool,
	}
	Result :: struct {
		passes:      map[string]int,
		reflections: bool,
		traced:      bool,
		batches:     int,
		// The frame's trace as it ran, copied out of frame memory.
		ssr:         Ssr_Frame,
	}
	run_frame :: proc(t: ^testing.T, r: ^Renderer, cache: ^Texture_Cache, instances, exposure: gpu.Buffer, settings: Reflection_Settings, options: Options = {}) -> (result: Result) {
		platform := r.platform
		g := begin(platform, cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {renderer = r, state = &r.view, graph = &g, size = {64, 32}}
		f.lights = new(Light_Frame, platform.frame_allocator)
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
		// The scene as build_scene leaves it, with a hit table once the ray scene is requested.
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.items = make([]Cull_Item, 1, platform.frame_allocator)
		if !options.no_hit_table {
			sf.hit_instances, _ = platform.gpu_upload(size_of(Hit_Instance), 16)
			sf.hit_submeshes, _ = platform.gpu_upload(size_of(Hit_Submesh), 16)
			sf.hit_instance_count = 1
			sf.hit_bins = {0}
		}
		begin_screen_reflections(f, settings)
		// The ray scene's build, and the scene's constants and instances, which add_scene_passes writes.
		if f.ray_scene != nil {
			f.ray_scene.accel = import_accel(&g, r.ray_scene.accel)
			if options.batches_full {
				f.ray_scene.batches = MAX_HIT_BATCHES
			}
		}
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(size_of(Frame_Constants), gpu.PASS_CONSTANTS_ALIGN)
		sf.instances = import_buffer(&g, instances)
		if options.no_march && f.ssr != nil {
			f.ssr.constants.steps = 0
		}
		add_screen_reflection_passes(f)
		world := add_render_pass(&g, "world", proc(_: ^Pass_Context) {}, nil)
		color(&g, world, f.scene, .Clear)
		if f.reflections != 0 {
			read(&g, world, f.reflections)
		}
		add_screen_reflection_lit(f)
		keep_pass(&g, world)
		result.passes = make(map[string]int, platform.frame_allocator)
		for node in g.passes {
			result.passes[node.name] += 1
			for name in TRACED_PASSES {
				if node.name == name {
					testing.expectf(t, node.queue == .Compute, "%s is on the %v queue", node.name, node.queue)
				}
			}
		}
		result.reflections = f.reflections != 0
		result.traced = f.ssr != nil && f.ssr.traced != nil
		if f.ssr != nil {
			result.ssr = f.ssr^
		}
		if f.ray_scene != nil {
			result.batches = f.ray_scene.batches
		}
		testing.expect(t, execute(&g), "the frame did not execute")
		return
	}

	// At every level, the rays trace the ray scene, as a batch of hit shading of their own, and the screen-space
	// reflections' trace does not run. The hits that the screen shows take the lit scene once it has a frame: Low and
	// Medium keep it at half the size, High and Ultra at the whole size, which starts again.
	for level in Quality_Level {
		for frame in 0 ..< 2 {
			res := run_frame(t, r, &cache, instances, exposure, {technique = .Ray_Traced, level = level})
			testing.expectf(t, res.reflections && res.traced, "%v: not traced", level)
			testing.expect_value(t, res.batches, 1)
			testing.expect_value(t, res.passes["reflections trace"], 0)
			testing.expect_value(t, res.passes["reflections depth"], 2)
			for name in TRACED_PASSES {
				first_lit := frame == 0 && (level == .Low || level == .High)
				want := name == "reflections hit screen" && first_lit ? 0 : 1
				testing.expectf(t, res.passes[name] == want, "%v, frame %d: %s ran %d times", level, frame, name, res.passes[name])
			}
			free_all(platform.frame_allocator)
		}
	}
	testing.expect(t, r.rtr.capacity >= 64 * 32, "the rays' buffers do not hold every pixel's ray at Ultra")

	// Without a march on the screen first, the frame builds no depth pyramid.
	res := run_frame(t, r, &cache, instances, exposure, {technique = .Ray_Traced, level = .High}, {no_march = true})
	testing.expect(t, res.traced)
	testing.expect_value(t, res.passes["reflections depth"], 0)
	testing.expect_value(t, res.passes["reflections ray trace"], 1)
	free_all(platform.frame_allocator)

	// A frame that cannot trace takes the screen-space reflections at the same level: without a hit table, without
	// Ray_Query, without the traced pipelines, or when hit shading has no batch left by the time the passes are added.
	expect_screen :: proc(t: ^testing.T, res: Result, what: string) {
		testing.expectf(t, res.reflections && !res.traced, "%s: reflections %v, traced %v", what, res.reflections, res.traced)
		testing.expectf(t, res.passes["reflections trace"] == 1 && res.passes["reflections depth"] == 2, "%s: no screen-space trace", what)
		testing.expectf(t, res.passes["reflections ray trace"] == 0 && res.passes["reflections hit shading"] == 0, "%s: traced", what)
	}
	settings := Reflection_Settings{technique = .Ray_Traced, level = .Ultra}
	expect_screen(t, run_frame(t, r, &cache, instances, exposure, settings, {no_hit_table = true}), "no hit table")
	free_all(platform.frame_allocator)
	expect_screen(t, run_frame(t, r, &cache, instances, exposure, settings, {batches_full = true}), "no batch left")
	free_all(platform.frame_allocator)
	// A frame that falls back once its passes are added runs the screen-space trace at the same level, as one with the
	// Screen technique does: at High, where the traced reflections trace a pixel of each 2x1 block, it traces each pixel.
	for level in Quality_Level {
		late := run_frame(t, r, &cache, instances, exposure, {technique = .Ray_Traced, level = level}, {batches_full = true})
		expect_screen(t, late, "no batch left")
		free_all(platform.frame_allocator)
		screen := run_frame(t, r, &cache, instances, exposure, {technique = .Screen, level = level})
		free_all(platform.frame_allocator)
		testing.expectf(t, late.ssr.technique == .Screen, "%v: the fallback is %v", level, late.ssr.technique)
		testing.expectf(t, late.ssr.stride == screen.ssr.stride && late.ssr.trace_size == screen.ssr.trace_size, "%v: the fallback traces at a stride of %v, the screen-space trace at %v", level, late.ssr.stride, screen.ssr.stride)
		testing.expectf(t, late.ssr.params == screen.ssr.params, "%v: the fallback keeps the traced params", level)
		lc, sc := late.ssr.constants, screen.ssr.constants
		testing.expectf(t, lc.trace_size == sc.trace_size && lc.stride == sc.stride && lc.ray_count == sc.ray_count && lc.steps == sc.steps && lc.cutoff == sc.cutoff && lc.reach == sc.reach, "%v: the fallback's constants are not the screen-space trace's", level)
	}
	r.caps.ray_query = false
	expect_screen(t, run_frame(t, r, &cache, instances, exposure, settings), "no Ray_Query")
	free_all(platform.frame_allocator)
	r.caps.ray_query = true
	light := r.rtr.light.pipeline
	r.rtr.light.pipeline = {}
	expect_screen(t, run_frame(t, r, &cache, instances, exposure, settings), "no pipeline")
	free_all(platform.frame_allocator)
	r.rtr.light.pipeline = light

	// The Screen technique never traces, even where it could.
	expect_screen(t, run_frame(t, r, &cache, instances, exposure, {technique = .Screen, level = .Ultra}), "Screen")
	free_all(platform.frame_allocator)
}

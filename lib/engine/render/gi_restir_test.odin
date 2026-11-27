package render

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"

// Every view's rays fit in one batch of hit shading: the tile widens past the batch's limit, and not before it.
@(test)
the_restir_fit_keeps_every_view_within_a_hit_batch :: proc(t: ^testing.T) {
	sizes := [][2]u32 {
		{1, 1},
		{1280, 720},
		{1920, 1080},
		{2560, 1440},
		{3840, 2160},
		{5120, 2880},
		{7680, 4320},
	}
	for size in sizes {
		for level in Quality_Level {
			params := GI_RESTIR_PARAMS[level]
			tile, reservoirs := restir_fit(size, params)
			testing.expectf(
				t,
				reservoirs.x * reservoirs.y <= MAX_HIT_RAYS,
				"%v at %v: %v reservoirs",
				size,
				level,
				reservoirs,
			)
			testing.expect_value(t, reservoirs, (size + tile - 1) / tile)
			testing.expect(t, tile.x >= params.tile.x && tile.y >= params.tile.y)
		}
	}
	fit :: proc(size: [2]u32) -> [2]u32 {
		tile, _ := restir_fit(size, GI_RESTIR_PARAMS[.Ultra])
		return tile
	}
	testing.expect_value(t, fit({2560, 1440}), [2]u32{1, 1})
	testing.expect_value(t, fit({3840, 2160}), [2]u32{2, 1})
	testing.expect_value(t, fit({7680, 4320}), [2]u32{4, 2})
	// Ultra's reservoirs at 1080p: both halves of the history and the spatial pass's.
	testing.expect_value(
		t,
		restir_bytes({1920, 1080}, GI_RESTIR_PARAMS[.Ultra]),
		1920 * 1080 * RESTIR_RESERVOIR_SIZE * 3,
	)
}

// A sample reused at its own surface keeps its solid angle, the change back is the reciprocal of the change there, and
// a sample at infinity keeps its solid angle wherever it is reused.
@(test)
a_restir_jacobian_is_one_for_the_same_receiver_and_reciprocal_when_swapped :: proc(t: ^testing.T) {
	sample := [3]f32{0, 2, 0}
	normal := [3]f32{0, -1, 0}
	a := [3]f32{0, 0, 0}
	b := [3]f32{1.5, 0.2, 0.5}
	testing.expect(t, abs(restir_jacobian(a, a, sample, normal, false) - 1) < 1e-5)
	ab := restir_jacobian(a, b, sample, normal, false)
	ba := restir_jacobian(b, a, sample, normal, false)
	testing.expect(t, abs(ab * ba - 1) < 1e-4)
	testing.expect(t, abs(ab - 1) > 0.1)
	testing.expect_value(t, restir_jacobian(a, b, sample, normal, true), 1)
	// A receiver at half the neighbour's distance from a sample straight above both sees it in four times the solid
	// angle, so a reused W, a density in the neighbour's solid angle, grows four times.
	near := restir_jacobian({0, 1, 0}, {0, 0, 0}, {0, 2, 0}, {0, -1, 0}, false)
	testing.expect(t, abs(near - 4) < 1e-4)
}

// One cosine-sampled sample, alone in its reservoir, gives back its own light as the diffuse light: its weight is its
// target over its pdf, and its light times its cosine times its W, over pi, is the light, as the temporal pass and the
// resolve compute them.
@(test)
one_cosine_sampled_candidate_estimates_its_own_radiance :: proc(t: ^testing.T) {
	light := f32(3)
	for cosine in ([]f32{1, 0.5, 0.1}) {
		target := light * cosine
		pdf := cosine / math.PI
		weight := target / pdf
		M := f32(1)
		W := weight / (M * target)
		diffuse := light * cosine * W / math.PI
		testing.expect(t, abs(diffuse - light) < 1e-4)
	}
}

@(test)
restir_gi_runs_on_the_compute_queue_and_passes_validation :: proc(t: ^testing.T) {
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
		gpu_create_accel            = null.create_accel,
		gpu_destroy_accel           = null.destroy_accel,
		gpu_create_compute_pipeline = null.create_compute_pipeline,
		gpu_destroy_pipeline        = null.destroy_pipeline,
		gpu_create_sampler          = null.create_sampler,
		gpu_destroy_sampler         = null.destroy_sampler,
	}
	r := new(Renderer)
	defer free(r)
	r.platform = &platform
	r.caps.ray_query = true
	code := []byte{1}
	gi := &r.gi
	restir := &gi.restir
	split := &gi.split
	pipelines := []^Shader_Pipeline {
		&r.ray_scene.bin_pipeline,
		&r.ray_scene.fallback,
		&gi.trace,
		&gi.merge,
		&gi.gather,
		&gi.lit,
		&gi.probes.reset,
		&gi.probes.trace,
		&gi.probes.light,
		&gi.probes.screen,
		&gi.probes.update,
		&split.table,
		&split.trace,
		&split.deposit,
		&split.merge,
		&split.gather,
		&restir.trace,
		&restir.temporal,
		&restir.spatial,
		&restir.resolve,
		&restir.filter,
	}
	for p in pipelines {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	r.ray_scene.accel = platform.gpu_create_accel(
		{kind = .Top, max_instances = 4, label = "test scene"},
	)
	defer ray_scene_destroy(&r.ray_scene, &platform)
	defer gi_destroy(gi, &platform)
	defer gi_state_destroy(&r.view.gi, &platform)
	instances := platform.gpu_create_buffer(
		{size = 1024, usage = {.Storage}, label = "instances"},
		nil,
	)
	defer platform.gpu_destroy_buffer(instances)
	exposure := platform.gpu_create_buffer(
		{size = 16, usage = {.Storage}, label = "exposure"},
		nil,
	)
	defer platform.gpu_destroy_buffer(exposure)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	Run :: struct {
		passes:  map[string]int,
		batches: int,
		// Whether hit shading had room left after the global illumination, for the traced reflections.
		room:    bool,
		ran:     bool,
		valid:   bool,
	}
	run_frame :: proc(
		t: ^testing.T,
		r: ^Renderer,
		cache: ^Texture_Cache,
		instances, exposure: gpu.Buffer,
		settings: Gi_Settings,
	) -> (
		run: Run,
	) {
		platform := r.platform
		g := begin(platform, cache)
		f := new(Frame, platform.frame_allocator)
		f^ = {
			renderer = r,
			state    = &r.view,
			graph    = &g,
			size     = {64, 32},
		}
		f.lights = new(Light_Frame, platform.frame_allocator)
		f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
		f.normals = create_texture(&g, {size = f.size, format = .RG16_Float, label = "normals"})
		f.velocity = create_texture(&g, {size = f.size, format = .RG16_Float, label = "velocity"})
		f.roughness = create_texture(
			&g,
			{size = f.size, format = ROUGHNESS_FORMAT, label = "roughness"},
		)
		prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
		depth(&g, prepass, f.depth, .Clear)
		color(&g, prepass, f.normals, .Clear)
		color(&g, prepass, f.velocity, .Clear)
		color(&g, prepass, f.roughness, .Clear)
		f.exposure = import_buffer(&g, exposure)
		sf := new(Scene_Frame, platform.frame_allocator)
		f.scene_frame = sf
		sf.view_constants = make([]gpu.Upload, 1, platform.frame_allocator)
		sf.view_constants[0], _ = platform.gpu_upload(
			size_of(Frame_Constants),
			gpu.PASS_CONSTANTS_ALIGN,
		)
		sf.instances = import_buffer(&g, instances)
		sf.hit_instances, _ = platform.gpu_upload(size_of(Hit_Instance), 16)
		sf.hit_submeshes, _ = platform.gpu_upload(size_of(Hit_Submesh), 16)
		sf.hit_instance_count = 1
		sf.hit_bins = {0}
		begin_gi(f, settings, {})
		testing.expect(t, f.gi != nil)
		if f.gi == nil {
			return
		}
		f.ray_scene.accel = import_accel(&g, r.ray_scene.accel)
		add_gi_world_probes(f)
		add_gi_passes(f)
		// The forward pass reads the light on the graphics queue.
		p := add_compute_pass(&g, "forward", proc(_: ^Pass_Context) {}, nil)
		read(&g, p, f.gi_diffuse)
		read(&g, p, f.gi_specular)
		keep_pass(&g, p)
		run.passes = make(map[string]int, platform.frame_allocator)
		for node in g.passes {
			run.passes[node.name] += 1
		}
		run.batches = f.ray_scene.batches
		run.room = hit_shading_ready(f)
		if f.gi.restir != nil {
			run.ran, run.valid = true, f.gi.restir.grid.history_valid != 0
		}
		testing.expect(t, execute(&g), "the frame did not execute")
		return
	}

	settings := Gi_Settings {
		technique = .Restir,
		level     = .Low,
	}
	names := []string {
		"gi restir trace",
		"gi restir light",
		"gi restir temporal",
		"gi restir spatial",
		"gi restir resolve",
	}
	for frame in 0 ..< 3 {
		run := run_frame(t, r, &cache, instances, exposure, settings)
		testing.expectf(t, run.ran, "frame %d did not run ReSTIR GI", frame)
		for name in names {
			testing.expectf(
				t,
				run.passes[name] == 1,
				"frame %d: %s ran %d times",
				frame,
				name,
				run.passes[name],
			)
		}
		testing.expect_value(
			t,
			run.passes["gi restir filter"],
			int(GI_RESTIR_PARAMS[.Low].filter_passes),
		)
		// The world probes run with it, and neither the split cascades nor the screen cascades do.
		testing.expect_value(t, run.passes["gi probe update"], 1)
		testing.expect_value(t, run.passes["gi split gather"], 0)
		testing.expect_value(t, run.passes["gi trace"], 0)
		// It takes one batch of hit shading, beside the world probes', and leaves room for the traced reflections.
		testing.expect_value(t, run.batches, 2)
		testing.expect(t, run.room)
		// The reservoirs are last frame's from the second frame on.
		testing.expect_value(t, run.valid, frame > 0)
		free_all(platform.frame_allocator)
	}
	testing.expect_value(t, r.view.gi.restir.frame, 3)

	// Another level's reservoirs are of another size, and start over.
	settings.level = .Ultra
	run := run_frame(t, r, &cache, instances, exposure, settings)
	testing.expect(t, run.ran && !run.valid)
	testing.expect_value(
		t,
		run.passes["gi restir filter"],
		int(GI_RESTIR_PARAMS[.Ultra].filter_passes),
	)
	free_all(platform.frame_allocator)

	// Without its pipelines, the frame takes the screen cascades, and makes none of the split cascades' storage.
	destroy_shader_pipeline(&restir.resolve, &platform)
	run = run_frame(t, r, &cache, instances, exposure, settings)
	testing.expect(t, !run.ran)
	testing.expect_value(t, run.passes["gi restir trace"], 0)
	testing.expect_value(t, run.passes["gi split gather"], 0)
	testing.expect_value(t, run.passes["gi trace"], 1)
	testing.expect_value(t, r.view.gi.split.slots, gpu.Buffer{})
	free_all(platform.frame_allocator)
}

@(test)
a_frame_that_loses_restir_gi_warns_once :: proc(t: ^testing.T) {
	Warnings :: struct {
		count: int,
		text:  string,
	}
	warnings: Warnings
	defer delete(warnings.text)
	runner := context.logger
	context.logger = {
		procedure = proc(
			data: rawptr,
			level: runtime.Logger_Level,
			text: string,
			_: runtime.Logger_Options,
			_ := #caller_location,
		) {
			w := (^Warnings)(data)
			if level == .Warning {
				w.count += 1
				// The text is in the logger's temporary buffer, which the test's own formatting reuses.
				delete(w.text)
				w.text = strings.clone(text)
			}
		},
		data = &warnings,
		lowest_level = .Warning,
	}
	r := new(Renderer)
	defer free(r)
	f := Frame {
		renderer = r,
		state    = &r.view,
		gi       = &Gi_Frame{settings = {technique = .Restir}},
	}
	// Waiting for its first frame is not losing it.
	note_restir_fallback(&f, false)
	count_while_waiting := warnings.count
	note_restir_fallback(&f, true)
	note_restir_fallback(&f, false)
	count_after_loss := warnings.count
	reason := warnings.text
	note_restir_fallback(&f, false)
	count_later := warnings.count
	// A frame that asks for another technique has not lost anything.
	note_restir_fallback(&f, true)
	f.gi.settings.technique = .Split_Cascades
	note_restir_fallback(&f, false)
	count_by_choice := warnings.count
	context.logger = runner
	testing.expect_value(t, count_while_waiting, 0)
	testing.expect_value(t, count_after_loss, 1)
	testing.expect_value(
		t,
		reason,
		"gi: ReSTIR GI gave way to the screen cascades: the world probes did not run",
	)
	testing.expect_value(t, count_later, 1)
	testing.expect_value(t, count_by_choice, 1)
}

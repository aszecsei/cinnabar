package render

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"
import "cinnabar:engine/volume"

// What the hooks of the test frame saw, and the logged problems other than the shaders that the test cache lacks.
@(private = "file")
Hook_Record :: struct {
	before_world, world_uses, after_world, before_post, ui, debug: bool,
	// What the debug hook, which runs after post-processing, saw.
	bloom, history_valid, occlusion, fog, gi, sky:      bool,
	// The exposure's histogram counts the background, which the sky drew.
	sky_background:                                     bool,
	temporal, upscaled, display:                        bool,
	size, output_size, scene_size:                      [2]u32,
	world_pieces:                                       int,
	shadow_views:                                       int,
	post:                                               Texture,
	problems:                                           [dynamic]string,
	mutex:                                              sync.Mutex,
}

// record_problems keeps every warning and error, except that a shader is not cooked: the test's cache has none, so
// every pipeline is missing, which the frame must survive.
@(private = "file")
record_problems :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location: runtime.Source_Code_Location) {
	r := (^Hook_Record)(data)
	if level < .Warning || strings.contains(text, "is not cooked") {
		return
	}
	sync.guard(&r.mutex)
	append(&r.problems, strings.clone(text))
}

@(test)
a_frame_runs_every_hook_and_passes_validation :: proc(t: ^testing.T) {
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
		asset_allocator              = runtime.heap_allocator(),
		file_read                    = core.file_read,
		file_modified                = core.file_modified,
		jobs_run                     = jobs.run,
		jobs_wait                    = jobs.wait,
		memory_reserve               = proc(size: int) -> rawptr {
			data, err := virtual.reserve(uint(size))
			return err == nil ? raw_data(data) : nil
		},
		memory_commit                = proc(ptr: rawptr, size: int) -> bool {return virtual.commit(ptr, uint(size)) == nil},
		memory_release               = proc(ptr: rawptr, size: int) {virtual.release(ptr, uint(size))},
		gpu_features                 = null.features,
		gpu_create_accel             = null.create_accel,
		gpu_destroy_accel            = null.destroy_accel,
		gpu_accel_reference          = null.accel_reference,
		gpu_upscalers                = null.upscalers,
		gpu_create_upscaler          = null.create_upscaler,
		gpu_destroy_upscaler         = null.destroy_upscaler,
		gpu_frame_target             = null.frame_target,
		gpu_output                   = null.output,
		gpu_request_output           = null.request_output,
		gpu_submit                   = null.submit,
		gpu_upload                   = null.upload,
		gpu_create_texture           = null.create_texture,
		gpu_destroy_texture          = null.destroy_texture,
		gpu_destroy_buffer           = null.destroy_buffer,
		gpu_destroy_pipeline         = null.destroy_pipeline,
		gpu_create_buffer            = null.create_buffer,
		gpu_create_sampler           = null.create_sampler,
		gpu_destroy_sampler          = null.destroy_sampler,
		gpu_create_graphics_pipeline = null.create_graphics_pipeline,
		gpu_update_graphics_pipeline = null.update_graphics_pipeline,
		gpu_create_compute_pipeline  = null.create_compute_pipeline,
		gpu_update_compute_pipeline  = null.update_compute_pipeline,
	}
	record: Hook_Record
	record.problems = make([dynamic]string)
	defer {
		for p in record.problems {
			delete(p)
		}
		delete(record.problems)
	}
	context.logger = {record_problems, &record, .Debug, {}}

	w := new(ecs.World)
	defer free(w)
	testing.expect(t, ecs.init(w, &platform))
	defer ecs.destroy(w)
	ecs.register_engine_components(&w.registry)
	volume.register_components(&w.registry)
	register_components(&w.registry)
	dir, err := os.make_directory_temp("", "renderer_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	assets: asset.Assets
	asset.init(&assets, &platform, asset.loose_cache(dir))
	defer asset.destroy(&assets)
	r := new(Renderer)
	defer free(r)
	renderer_init(r, &platform, &assets, w)
	defer renderer_destroy(r)
	// Lights that cast shadows. The test's cache has no shaders, so there is no mask to trace into, and they take
	// shadow maps: the sun's cascades and the lamp's six faces.
	sun := ecs.spawn(w)
	ecs.add(w, sun, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, sun, Directional_Light{intensity = 1, cast_shadows = true})
	lamp := ecs.spawn(w)
	ecs.add(w, lamp, ecs.Transform{position = ecs.position_offset({}, {0, 0, 2}), rotation = 1, scale = 1})
	ecs.add(w, lamp, Point_Light{intensity = 1, cast_shadows = true})
	// A patch surface, whose material the test's cache cannot cook, so it has a slot and no item.
	pond := ecs.spawn(w)
	ecs.add(w, pond, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, pond, Surface_Renderer{size = {64, 64}, cell = 1, height_range = {-1, 1}, cast_shadows = true})
	mist := ecs.spawn(w)
	ecs.add(w, mist, ecs.TRANSFORM_IDENTITY)
	// The fog is a setting of the volume around the camera.
	ecs.add(w, mist, volume.Volume{shape = .Global})
	ecs.add(w, mist, Fog{density = {true, 0.05}, height_falloff = {true, 0.5}})
	// So is the sky, whose sun is the directional light.
	environment := DEFAULT_ENVIRONMENT
	environment.mode = {true, .Atmosphere}
	environment.sun = {true, sun}
	environment.night.star_intensity = {true, 1}
	ecs.add(w, mist, environment)
	debug.line(&r.debug, {}, ecs.position_offset({}, {0, 0, 1}), {1, 0, 0, 1})
	debug.line(&r.debug, {}, ecs.position_offset({}, {0, 1, 0}), {0, 1, 0, 1}, mode = .Overlay)

	desc := Frame_Desc {
		view = {rotation = 1, vertical_fov = 1, near = 0.05},
		size = {64, 32},
		keep_ids = true,
		hooks = {
			data = &record,
			before_world = proc(f: ^Frame) {
				(^Hook_Record)(f.data).before_world = true
				(^Hook_Record)(f.data).shadow_views = len(f.shadows.views)
			},
			world_uses = proc(f: ^Frame, pass: Pass) {
				(^Hook_Record)(f.data).world_uses = true
			},
			world_draw = proc(f: ^Frame, ctx: ^Pass_Context) {
				rec := (^Hook_Record)(f.data)
				sync.guard(&rec.mutex)
				rec.world_pieces += 1
			},
			world_pieces = 2,
			// A post pass that writes a new scene color, which the output pass then reads.
			after_world = proc(f: ^Frame) {
				rec := (^Hook_Record)(f.data)
				rec.after_world = true
				post := create_texture(f.graph, {size = f.size, format = SCENE_FORMAT, label = "post"})
				p := add_compute_pass(f.graph, "post", proc(_: ^Pass_Context) {}, nil)
				read(f.graph, p, f.scene)
				write(f.graph, p, post)
				f.scene = post
				rec.post = post
			},
			before_post = proc(f: ^Frame) {
				(^Hook_Record)(f.data).before_post = true
			},
			ui = proc(f: ^Frame) {
				(^Hook_Record)(f.data).ui = true
				p := add_render_pass(f.graph, "hud", proc(_: ^Pass_Context) {}, nil)
				color(f.graph, p, f.ui, .Load)
			},
			debug = proc(f: ^Frame) {
				rec := (^Hook_Record)(f.data)
				rec.debug = f.debug != 0
				rec.bloom, rec.history_valid = f.bloom != 0, f.post.history.valid
				rec.occlusion, rec.fog, rec.gi = f.ambient_occlusion != 0, f.fog_volume != 0, f.gi_diffuse != 0
				rec.sky, rec.sky_background = f.sky != nil, f.post.background
				rec.temporal, rec.upscaled, rec.display = f.post.temporal, f.post.upscaler != {}, f.display != 0
				rec.size, rec.output_size, rec.scene_size = f.size, f.output_size, f.scene_size
				// The editor's tools read the IDs and the depth after the debug lines.
				p := add_compute_pass(f.graph, "pick", proc(_: ^Pass_Context) {}, nil)
				read(f.graph, p, f.ids)
				read(f.graph, p, f.depth)
			},
		},
	}
	testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
	testing.expect(t, record.before_world && record.world_uses && record.after_world && record.before_post && record.ui && record.debug)
	testing.expect_value(t, record.world_pieces, 2)
	testing.expect_value(t, record.shadow_views, SHADOW_CASCADES + 6)
	testing.expect(t, record.post != 0)
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)
	// Lines of this frame only are gone after it.
	testing.expect_value(t, len(debug.frame_lines(&r.debug)), 0)

	// A frame without hooks or lines has no UI or debug layer, and the IDs and the depth are discarded.
	testing.expect(t, draw_frame(r, w, {view = desc.view, size = desc.size}))
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// A frame with no_debug, as the editor's in Play, draws its lines nowhere and still drops them, and runs the debug
	// hook without a layer, so the editor's picks still read the IDs and the depth.
	debug.line(&r.debug, {}, ecs.position_offset({}, {0, 0, 1}), {1, 0, 0, 1})
	record.debug = true
	no_debug := desc
	no_debug.no_debug = true
	no_debug.hooks.debug = proc(f: ^Frame) {
		(^Hook_Record)(f.data).debug = f.debug != 0
		p := add_compute_pass(f.graph, "pick", proc(_: ^Pass_Context) {}, nil)
		read(f.graph, p, f.ids)
		read(f.graph, p, f.depth)
	}
	testing.expect(t, draw_frame(r, w, no_debug), "the frame without a debug layer did not execute")
	testing.expect(t, !record.debug, "the debug hook saw a debug layer")
	testing.expect_value(t, len(debug.frame_lines(&r.debug)), 0)
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// With the pipelines of post-processing, the ambient occlusion, the global illumination, the fog and the sky, which the
	// test's cache cannot cook, every pass runs: the frames after the first read their histories, and the lookup table
	// bakes once. The ambient occlusion and the global illumination run on the compute queue. The null backend checks every barrier and wait.
	code := []byte{1}
	compute := []^Shader_Pipeline {
		&r.post.temporal_aa,
		&r.post.bloom,
		&r.post.histogram,
		&r.post.adapt,
		&r.post.tone_lut,
		&r.ao.depth,
		&r.ao.searches[.Gtao],
		&r.ao.searches[.Ssao],
		&r.ao.searches[.Hbao],
		&r.ao.denoise,
		&r.gi.trace,
		&r.gi.merge,
		&r.gi.gather,
		&r.gi.lit,
		&r.fog.inject,
		&r.fog.integrate,
		&r.fog.background,
		&r.sky.transmittance,
		&r.sky.multiscatter,
		&r.sky.view,
		&r.sky.background,
		&r.post.upscalers.motion,
		&r.scene.select_pipeline,
		&r.scene.cull_patches_pipeline,
		// The traced shadows, so the lights trace their mask, and the frame builds the ray scene before it.
		&r.shadows.mask_pipeline,
		&r.ray_scene.bin_pipeline,
		&r.ray_scene.fallback,
		// The world probes, which the quality's World_Probes runs on the traced scene.
		&r.gi.probes.reset,
		&r.gi.probes.trace,
		&r.gi.probes.light,
		&r.gi.probes.screen,
		&r.gi.probes.update,
	}
	for p in compute {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	for i in 0 ..< 3 {
		testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
		testing.expect(t, record.bloom && record.occlusion && record.fog && record.gi && record.sky)
		testing.expect(t, record.sky_background, "the histogram does not count the sky")
		testing.expect_value(t, record.history_valid, i > 0)
		testing.expect(t, r.post.lut_baked)
		testing.expect(t, r.ray_scene.accel != {} && r.residency.accels, "the traced shadows did not request the ray scene")
	}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// A Flat background is the clear color, which is not pre-exposed, so the histogram does not count it.
	ecs.get(w, mist, Environment).mode = {true, .Flat}
	testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
	testing.expect(t, !record.sky && !record.sky_background, "the histogram counts a Flat background")
	ecs.get(w, mist, Environment).mode = {true, .Atmosphere}

	// Each ambient occlusion technique that the quality chooses draws the occlusion, and Off draws none.
	for technique in Ao_Technique {
		q := r.quality
		q.ao.technique = technique
		desc.quality = &q
		testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
		testing.expectf(t, record.occlusion == (technique != .Off), "%v: occlusion %v", technique, record.occlusion)
	}
	desc.quality = nil
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// Each anti-aliasing technique: temporal AA in the scene, FXAA and SMAA into Frame.display, which the output pass
	// reads tone mapped, FSR's upscale in temporal AA's place, and Off none. A volume or the editor that turns the
	// anti-aliasing off turns every technique off.
	r.post.spatial.tone_map.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	r.post.spatial.fxaa.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	smaa := [?]struct {
		pipeline: ^Shader_Pipeline,
		format:   gpu.Format,
	}{{&r.post.spatial.smaa_edges, SMAA_EDGES_FORMAT}, {&r.post.spatial.smaa_weights, SMAA_WEIGHTS_FORMAT}, {&r.post.spatial.smaa_blend, DISPLAY_FORMAT}}
	for s in smaa {
		s.pipeline.pipeline = platform.gpu_create_graphics_pipeline({vertex = code, pixel = code, colors = {{format = s.format}}, label = "test smaa"})
	}
	for technique in Aa_Technique {
		q := r.quality
		q.aa = technique
		desc.quality = &q
		for disable in ([]Features{{}, {.Temporal_Aa}}) {
			desc.disable = disable
			testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
			on := disable == {}
			testing.expectf(t, record.temporal == (on && technique == .Taa), "%v: temporal %v", technique, record.temporal)
			testing.expectf(t, record.upscaled == (on && technique == .Fsr), "%v: upscaled %v", technique, record.upscaled)
			testing.expectf(t, record.display == (on && (technique == .Fxaa || technique == .Smaa)), "%v: display %v", technique, record.display)
		}
	}
	desc.quality, desc.disable = nil, {}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// At half the frame's size, the scene and the debug layer are half its size and the UI is the frame's: temporal AA
	// and FSR upscale the scene to the frame's size, and with the other techniques it stays small for the output pass.
	for technique in Aa_Technique {
		q := r.quality
		q.aa, q.render_scale = technique, 0.5
		desc.quality = &q
		for _ in 0 ..< 2 {
			testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
		}
		testing.expect_value(t, record.size, desc.size / 2)
		testing.expect_value(t, record.output_size, desc.size)
		upscales := technique == .Taa || technique == .Fsr
		testing.expectf(t, record.scene_size == (upscales ? desc.size : desc.size / 2), "%v: scene size %v", technique, record.scene_size)
		testing.expect_value(t, record.temporal, technique == .Taa)
		testing.expect_value(t, record.upscaled, technique == .Fsr)
	}
	desc.quality = nil
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// HDR output: the frame target changes its format, the output pass draws with the pipeline of that format, and the
	// lookup table bakes again for HDR, with the default paper white and peak, since the null backend has no display.
	for mode in gpu.Output_Mode {
		r.output_pipelines[mode].pipeline = platform.gpu_create_graphics_pipeline(
			{vertex = code, pixel = code, colors = {{format = gpu.output_format(mode)}}, label = "test output"},
		)
	}
	for request in ([]gpu.Output_Request{.Hdr10, .Scrgb, .Auto}) {
		platform.gpu_request_output(request)
		null.begin_frame({64, 32})
		mode := gpu.output_mode(request, {})
		testing.expect_value(t, platform.gpu_output().format, gpu.output_format(mode))
		testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
		testing.expect_value(t, r.post.lut_grading.hdr, mode != .Sdr)
		testing.expect_value(t, r.post.lut_grading.paper_white, mode != .Sdr ? DEFAULT_PAPER_WHITE : 0)
		testing.expect_value(t, r.post.lut_grading.peak, mode != .Sdr ? DEFAULT_PEAK : 0)
	}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// Every debug view draws, and a view that is not shaded has no bloom. So does every feature turned off.
	r.debug_view.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test debug view"})
	for view in Debug_View {
		desc.debug_view = view
		testing.expectf(t, draw_frame(r, w, desc), "the frame with the %v view did not execute", view)
		testing.expectf(t, !record.bloom || view == .Lit, "the %v view has bloom", view)
	}
	desc.debug_view = .Lit
	desc.disable = ~Features{}
	testing.expect(t, draw_frame(r, w, desc), "the frame without its features did not execute")
	testing.expect(t, !record.bloom && !record.occlusion && !record.fog && !record.gi)
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)
	// The jitter cycles inside the pixel.
	for n in u32(1) ..= JITTER_SAMPLES {
		testing.expect(t, halton(n, 2) > 0 && halton(n, 2) < 1 && halton(n, 3) > 0 && halton(n, 3) < 1)
	}
}

@(test)
ids_keep_the_entity_and_the_submesh :: proc(t: ^testing.T) {
	last := ecs.MAX_ENTITIES - 1
	id := u32(last + 1) | ID_MAX_SUBMESH << ID_ENTITY_BITS
	testing.expect_value(t, id_entity(id), u32(last + 1))
	testing.expect_value(t, id_submesh(id), ID_MAX_SUBMESH)
	testing.expect_value(t, id_entity(5 | 3 << ID_ENTITY_BITS), 5)
	testing.expect_value(t, id_submesh(5), 0)
}

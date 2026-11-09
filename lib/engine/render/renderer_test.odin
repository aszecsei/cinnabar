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
	runner:   log.Logger,
	before_world, world_uses, after_world, before_post, ui, debug: bool,
	// What the debug hook, which runs after post-processing, saw.
	bloom, history_valid, occlusion, fog, gi, sky:      bool,
	// The reflections, and whether they traced the ray scene.
	reflections, traced:                                bool,
	// A reflection probe's capture's faces' own voxel cones' light, and their own ambient occlusion.
	capture_gi, capture_occlusion:                      bool,
	// The clouds, and their shadow map.
	clouds, cloud_shadow:                               bool,
	// The exposure's histogram counts the background, which the sky drew.
	sky_background:                                     bool,
	temporal, upscaled, display:                        bool,
	// The frame bakes the lookup table, and the sky's cubemap captures.
	baked, sky_capture:                                 bool,
	size, output_size, scene_size:                      [2]u32,
	world_pieces:                                       int,
	shadow_views:                                       int,
	post:                                               Texture,
	problems:                                           [dynamic]string,
	mutex:                                              sync.Mutex,
}

// record_problems keeps every warning and error, except that a shader is not cooked or has no blob: the test's cache
// has none, so every pipeline is missing, which the frame must survive.
@(private = "file")
record_problems :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location: runtime.Source_Code_Location) {
	r := (^Hook_Record)(data)
	// testing.expect reports a failure as an error log from the test file. It must reach the test runner.
	if strings.has_suffix(location.file_path, "_test.odin") {
		r.runner.procedure(r.runner.data, level, text, options, location)
		return
	}
	if level < .Warning || strings.contains(text, "is not cooked") || strings.contains(text, "no blob for") {
		return
	}
	sync.guard(&r.mutex)
	append(&r.problems, strings.clone(text))
}

// The platform of a test's frames, over the null backend.
@(private = "file")
test_platform :: proc(arena: ^virtual.Arena) -> core.Platform_API {
	return {
		frame_allocator              = virtual.arena_allocator(arena),
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
		gpu_create_texture_view      = null.create_texture_view,
		gpu_destroy_texture          = null.destroy_texture,
		gpu_destroy_buffer           = null.destroy_buffer,
		gpu_destroy_pipeline         = null.destroy_pipeline,
		gpu_create_buffer            = null.create_buffer,
		gpu_read_buffer              = null.read_buffer,
		gpu_create_sampler           = null.create_sampler,
		gpu_destroy_sampler          = null.destroy_sampler,
		gpu_create_graphics_pipeline = null.create_graphics_pipeline,
		gpu_update_graphics_pipeline = null.update_graphics_pipeline,
		gpu_create_compute_pipeline  = null.create_compute_pipeline,
		gpu_update_compute_pipeline  = null.update_compute_pipeline,
	}
}

// enable_pipelines gives the renderer a pipeline for every compute pass of the frame, with the code of a shader that does
// nothing, which the null backend accepts, and a texture for the blue noise. The test's cache cannot cook any shader.
@(private = "file")
enable_pipelines :: proc(r: ^Renderer) {
	platform := r.platform
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
		// The sky's cubemap, which the atmosphere captures from its tables.
		&r.sky.cube.capture,
		&r.sky.cube.atmosphere,
		&r.sky.cube.prefilter,
		// The clouds, which bake their noise in the first frame that executes and cast their shadow from the sun.
		&r.clouds.noise,
		&r.clouds.shadow,
		&r.clouds.march,
		&r.clouds.temporal,
		&r.clouds.composite,
		&r.post.upscalers.motion,
		&r.scene.select_pipeline,
		&r.scene.cull_patches_pipeline,
		// The traced shadows, so the lights trace their mask, and the frame builds the ray scene before it.
		&r.shadows.mask_pipeline,
		&r.ray_scene.bin_pipeline,
		&r.ray_scene.fallback,
		// The world probes, which the quality's Split_Cascades runs on the traced scene.
		&r.gi.probes.reset,
		&r.gi.probes.trace,
		&r.gi.probes.light,
		&r.gi.probes.screen,
		&r.gi.probes.update,
		// The split cascades, which take the screen cascades' place with the world probes.
		&r.gi.split.table,
		&r.gi.split.trace,
		&r.gi.split.deposit,
		&r.gi.split.merge,
		&r.gi.split.gather,
		// The voxel cones, which a quality may choose in the cascades' place.
		&r.gi.voxel.clear,
		&r.gi.voxel.inject,
		&r.gi.voxel.filter,
		&r.gi.voxel.gather,
		// The screen-space reflections, which the default quality takes.
		&r.ssr.depth,
		&r.ssr.trace,
		&r.ssr.resolve,
		&r.ssr.temporal,
		&r.ssr.lit,
		// The traced reflections, which the default quality takes with ray queries.
		&r.rtr.trace,
		&r.rtr.light,
	}
	for p in compute {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
	// The test's cache has no textures, so the ambient occlusion and the screen-space reflections take this one as
	// their blue noise.
	r.blue_noise.texture = platform.gpu_create_texture({size = {BLUE_NOISE_SIZE, BLUE_NOISE_SIZE}, layers = BLUE_NOISE_SLICES, format = .RGBA8_Unorm, usage = {.Sampled, .Storage}, label = "noise"}, nil)
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
	platform := test_platform(&arena)
	record: Hook_Record
	record.problems = make([dynamic]string)
	defer {
		for p in record.problems {
			delete(p)
		}
		delete(record.problems)
	}
	record.runner = context.logger
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
	// And the clouds, whose shadow the sun casts.
	ecs.add(w, mist, Clouds{density = {true, 1}})
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
				rec.reflections, rec.traced = f.reflections != 0, f.ssr != nil && f.ssr.traced != nil
				pf := f.reflection_probes
				if pf != nil {
					_, rec.capture_gi = pf.face_light.(Reflection_Probe_Voxel_Light)
					_, rec.capture_occlusion = pf.face_light.(Reflection_Probe_Occlusion)
				} else {
					rec.capture_gi, rec.capture_occlusion = false, false
				}
				rec.clouds, rec.cloud_shadow = f.clouds != nil, f.clouds != nil && f.clouds.shadow != 0
				rec.sky, rec.sky_background = f.sky != nil, f.post.background
				rec.temporal, rec.upscaled, rec.display = f.post.temporal, f.post.upscaler != {}, f.display != 0
				rec.baked, rec.sky_capture = f.post.baked, f.sky_cube != nil && f.sky_cube.capture
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
	enable_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	// A frame that does not execute changes nothing that its GPU work would have: the lookup table is not baked, the
	// exposure has not adapted, the sky's cubemap and the split cascades' storage are as new, and the frames after
	// start over as if it had not been.
	platform.gpu_submit = fail_submit
	testing.expect(t, !draw_frame(r, w, desc), "the frame executed with a submit that fails")
	platform.gpu_submit = null.submit
	testing.expect(t, record.baked && record.sky_capture, "the failed frame had no work to lose")
	testing.expect(t, r.post.lut_bake == nil, "the failed frame baked the lookup table")
	testing.expect(t, !r.post.adapted, "the failed frame adapted the exposure")
	testing.expect(t, !r.sky.cube.ring.valid, "the failed frame made the sky's cubemap")
	testing.expect(t, r.gi.split.slots == {} || r.gi.split.fresh, "the failed frame cleared the split cascades' storage")
	testing.expect(t, record.clouds && r.clouds.noise_state == .Pending, "the failed frame baked the clouds' noise")
	for i in 0 ..< 3 {
		testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
		testing.expect(t, record.bloom && record.occlusion && record.fog && record.gi && record.sky && record.reflections)
		testing.expect(t, record.clouds && record.cloud_shadow, "the frame has no clouds or no cloud shadow")
		testing.expect_value(t, r.clouds.noise_state, Cloud_Noise_State.Ready)
		testing.expect(t, record.sky_background, "the histogram does not count the sky")
		testing.expect_value(t, record.history_valid, i > 0)
		testing.expect_value(t, record.baked, i == 0)
		testing.expect_value(t, record.sky_capture, i == 0)
		testing.expect(t, r.post.lut_bake != nil && r.post.adapted)
		testing.expect(t, r.ray_scene.accel != {} && r.residency.accels, "the traced shadows did not request the ray scene")
		// The first frame makes the sky's whole cubemap, from the atmosphere's tables.
		testing.expect(t, r.sky.cube.ring.valid && r.sky.cube.ring.key.source == .Atmosphere)
	}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// With the virtual shadow map's pipelines, a frame without traced shadows draws its passes in place of the cascades,
	// and the null backend validates its pass with no attachments. Low keeps the cascades, and turning the option off does too.
	r.shadows.virtual.mark_pipeline.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	r.shadows.virtual.allocate_pipeline.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	{
		q := r.quality
		q.shadows = {level = .High, virtual = true}
		desc.quality = &q
		testing.expect(t, draw_frame(r, w, desc), "the virtual shadow map's frame did not execute")
		testing.expect_value(t, record.shadow_views, SHADOW_PARAMS[.High].virtual_levels + 6)
		testing.expect(t, r.shadows.virtual.pool != {})
		testing.expect_value(t, r.shadows.virtual.pool_pages, SHADOW_PARAMS[.High].pool_pages)
		// A level with another pool remakes it.
		q.shadows.level = .Ultra
		testing.expect(t, draw_frame(r, w, desc), "the virtual shadow map's frame did not execute")
		testing.expect_value(t, r.shadows.virtual.pool_pages, SHADOW_PARAMS[.Ultra].pool_pages)
		// A frame that records the stats' copy and then fails writes no copy and does not move on, so its stats show none.
		next := r.shadows.virtual.stats_ring.next
		platform.gpu_submit = fail_submit
		testing.expect(t, !draw_frame(r, w, desc), "the frame executed with a submit that fails")
		platform.gpu_submit = null.submit
		testing.expect_value(t, r.shadows.virtual.stats_ring.next, next)
		testing.expect_value(t, virtual_shadow_stats(r), Virtual_Shadow_Stats{})
		q.shadows = {level = .Low, virtual = true}
		testing.expect(t, draw_frame(r, w, desc), "the cascades' frame did not execute")
		testing.expect_value(t, record.shadow_views, SHADOW_PARAMS[.Low].cascades + 6)
		// The cascades' frame copies no virtual stats, so none are written, and none show.
		testing.expect_value(t, r.shadows.virtual.stats_ring.written, [READBACK_COPIES]bool{})
		testing.expect_value(t, virtual_shadow_stats(r), Virtual_Shadow_Stats{})
		q.shadows = {level = .High, virtual = false}
		testing.expect(t, draw_frame(r, w, desc), "the cascades' frame did not execute")
		testing.expect_value(t, record.shadow_views, SHADOW_CASCADES + 6)
		desc.quality = nil
	}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// The voxel cones, which need no ray queries: the views of the levels that voxelize draw the scene with no
	// attachments after the shadow views, and the null backend validates their passes.
	{
		q := r.quality
		q.gi = {technique = .Voxel_Cones, level = .Low}
		desc.quality = &q
		for _ in 0 ..< 2 {
			testing.expect(t, draw_frame(r, w, desc), "the voxel cones' frame did not execute")
			testing.expect(t, record.gi)
		}
		testing.expect(t, r.gi.voxel.running, "the voxel cones did not run")
		testing.expect(t, r.gi.voxel.boxes[0].voxelized)
		desc.quality = nil
	}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// The reflection probes: a probe's capture draws its faces as views of the scene, with their own clusters and the
	// probe's own shadow view, after the others, and the null backend validates their passes. Once captured, the clusters
	// bin it and the forward pass reads its cube.
	{
		probe := ecs.spawn(w)
		ecs.add(w, probe, ecs.Transform{position = ecs.position_offset({}, {0, 1, 3}), rotation = 1, scale = 1})
		ecs.add(w, probe, Reflection_Probe{extent = {2, 1, 2}, box_projection = true})
		rp := &r.reflection_probes
		for p in ([]^Shader_Pipeline{&rp.face, &rp.downsample, &r.lights.pipeline}) {
			p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
		}
		q := r.quality
		q.reflections = {technique = .Probes, level = .Medium}
		desc.quality = &q
		for k in 0 ..< 4 {
			testing.expect(t, draw_frame(r, w, desc), "the reflection probes' frame did not execute")
			stats := reflection_probe_stats(r)
			testing.expect_value(t, stats.probes, 1)
			testing.expect_value(t, stats.faces, k < 3 ? 2 : 0)
			// The lights trace their shadows into the mask, which the faces cannot read, so while it captures, the probe has
			// a shadow view of its own of the sun.
			testing.expect_value(t, record.shadow_views, k < 3 ? 1 : 0)
			// The screen cascades are the camera's screen, so the faces take the ambient occlusion of their own depth.
			testing.expect_value(t, record.capture_occlusion, k < 3)
			testing.expect(t, !record.capture_gi)
		}
		testing.expect_value(t, reflection_probe_stats(r).slots, 1)
		// A capture with the voxel cones gathers them at each face, between its prepass and its forward pass.
		q.gi = {technique = .Voxel_Cones, level = .Low}
		testing.expect(t, capture_reflection_probe(r, probe))
		testing.expect(t, draw_frame(r, w, desc), "the reflection probes' frame with the voxel cones did not execute")
		testing.expect_value(t, reflection_probe_stats(r).faces, 6)
		testing.expect(t, record.capture_gi && !record.capture_occlusion)
		q.gi = r.quality.gi
		desc.debug_view = .Reflection_Probes
		testing.expect(t, draw_frame(r, w, desc), "the reflection probes' view did not execute")
		desc.debug_view = .Lit
		q.reflections = {}
		testing.expect(t, draw_frame(r, w, desc), "the frame without the reflection probes did not execute")
		testing.expect(t, rp.cubes.texture == {}, "the reflection probes kept their cubes")
		desc.quality = nil
		ecs.despawn(w, probe)
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
	// Until the blue noise is resident, neither the occlusion nor the screen-space reflections run.
	noise := r.blue_noise.texture
	r.blue_noise.texture = {}
	testing.expect(t, draw_frame(r, w, desc), "the frame without the blue noise did not execute")
	testing.expect(t, !record.occlusion && !record.reflections, "a pass ran without the blue noise")
	r.blue_noise.texture = noise
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// Only the Screen and Ray_Traced techniques make the reflections, at every level, and their debug view shows them.
	// The test's world draws no meshes, so hit shading has nothing to shade, and Ray_Traced takes the screen-space
	// reflections (traced_reflections_test.odin traces them).
	for technique in Reflection_Technique {
		for level in Quality_Level {
			q := r.quality
			q.reflections = {technique, level}
			desc.quality = &q
			testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
			testing.expectf(t, record.reflections == (technique == .Screen || technique == .Ray_Traced), "%v at %v: reflections %v", technique, level, record.reflections)
			testing.expectf(t, !record.traced, "%v at %v traced with nothing to shade", technique, level)
		}
	}
	desc.debug_view = .Reflections
	testing.expect(t, draw_frame(r, w, desc), "the reflections' view did not execute")
	desc.debug_view = .Lit
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
		bake, baked := r.post.lut_bake.?
		testing.expect(t, baked)
		testing.expect_value(t, bake.grading.hdr, mode != .Sdr)
		testing.expect_value(t, bake.grading.paper_white, mode != .Sdr ? DEFAULT_PAPER_WHITE : 0)
		testing.expect_value(t, bake.grading.peak, mode != .Sdr ? DEFAULT_PEAK : 0)
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
	// With the shading stats, the forward pass counts its quads, and each frame copies its tally for the editor. Without
	// them, the editor sees none.
	desc.shading_stats = true
	for _ in 0 ..< 2 {
		testing.expect(t, draw_frame(r, w, desc), "the frame with the shading stats did not execute")
	}
	testing.expect_value(t, r.shading.stats_ring.next, 2)
	desc.shading_stats = false
	testing.expect(t, draw_frame(r, w, desc), "the frame without the shading stats did not execute")
	testing.expect_value(t, r.shading.stats_ring.next, 2)
	testing.expect_value(t, shading_stats(r), Shading_Stats{})
	desc.disable = ~Features{}
	testing.expect(t, draw_frame(r, w, desc), "the frame without its features did not execute")
	testing.expect(t, !record.bloom && !record.occlusion && !record.fog && !record.gi)
	testing.expect(t, !record.clouds && !record.cloud_shadow, "the clouds stayed on")
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

// A frame writes and uploads only the records that changed, and a change of what they mean writes them all.
@(test)
frames_upload_only_the_records_that_changed :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	testing.expect(t, jobs.init(2))
	defer jobs.shutdown()
	testing.expect(t, null.init(nil, {64, 32}))
	defer null.shutdown()
	platform := test_platform(&arena)
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
	// The test's cache has no shaders, which is not what this test is about. A test fails through the logger, so only
	// the renderer's own calls go without it.
	quiet := context
	quiet.logger = log.nil_logger()
	{
		context = quiet
		renderer_init(r, &platform, &assets, w)
	}
	defer {
		context = quiet
		renderer_destroy(r)
	}

	// Two archetypes, so two chunks: one interpolates between its poses.
	still := ecs.spawn(w)
	ecs.add(w, still, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, still, Mesh_Renderer{})
	mover := ecs.spawn(w)
	ecs.add(w, mover, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, mover, Mesh_Renderer{})
	glider := ecs.spawn(w)
	ecs.add(w, glider, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, glider, ecs.Previous_Transform(ecs.TRANSFORM_IDENTITY))
	ecs.add(w, glider, Mesh_Renderer{})
	s := &r.scene

	frame :: proc(r: ^Renderer, w: ^ecs.World, at: ecs.World_Position = {}, copied := true) -> int {
		context.logger = log.nil_logger()
		f := new(Frame, r.platform.frame_allocator)
		f.renderer = r
		f.view = {position = at, rotation = 1, vertical_fov = 1, near = 0.05}
		f.size = {64, 32}
		build_scene(f, w, nil, nil)
		// The copy of a frame with no draws does not run here, so a test says whether it did.
		if copied {
			r.scene.copied_frame = r.scene.frame
		}
		return r.scene.uploaded_slots
	}

	testing.expect_value(t, frame(r, w), 3)
	testing.expect_value(t, s.high, 3)
	testing.expect_value(t, frame(r, w), 0)
	testing.expect_value(t, frame(r, w), 0)

	// A pose written in a chunk: the slots of that chunk's entities that changed, and only those.
	slot := s.slots[mover]
	before := s.records[slot].rows
	ecs.get_write(w, mover, ecs.Transform).position = ecs.position_offset({}, {1, 0, 0})
	testing.expect_value(t, frame(r, w), 1)
	testing.expect(t, s.records[slot].rows != before)
	testing.expect_value(t, s.records[slot].previous_rows, before)
	// One more write, so that last frame's pose catches up, and then none.
	testing.expect_value(t, frame(r, w), 1)
	testing.expect_value(t, s.records[slot].previous_rows, s.records[slot].rows)
	testing.expect_value(t, frame(r, w), 0)

	// A write of the same pose is a visit and no upload.
	ecs.get_write(w, mover, ecs.Transform)
	testing.expect_value(t, frame(r, w), 0)

	// Between ticks, the pose moves with alpha, and no column is written.
	ecs.get_write(w, glider, ecs.Transform).position = ecs.position_offset({}, {4, 0, 0})
	w.clock.alpha = 0.25
	testing.expect_value(t, frame(r, w), 1)
	w.clock.alpha = 0.75
	testing.expect_value(t, frame(r, w), 1)
	// When it stops, one more write for last frame's pose, and then none.
	testing.expect_value(t, frame(r, w), 1)
	testing.expect_value(t, frame(r, w), 0)

	// A rebase means something else by every pose, and so does a copy that did not run.
	far := ecs.position_offset({}, {4 * ORIGIN_CELL, 0, 0})
	testing.expect_value(t, frame(r, w, far), 3)
	testing.expect_value(t, frame(r, w, far), 0)
	testing.expect_value(t, frame(r, w, far, copied = false), 0)
	testing.expect_value(t, frame(r, w, far), 3)
	testing.expect_value(t, frame(r, w, far), 0)

	// A freed slot holds nothing, and a new entity takes it, with no help from its old record. The row that moved into
	// the despawned one's place is written, but it is the same.
	testing.expect(t, ecs.despawn(w, still))
	freed := s.slots[still]
	testing.expect_value(t, frame(r, w, far), 1)
	testing.expect_value(t, s.records[freed], Instance_Record{})
	fresh := ecs.spawn(w)
	ecs.add(w, fresh, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, fresh, Mesh_Renderer{})
	testing.expect_value(t, frame(r, w, far), 1)
	testing.expect_value(t, s.slots[fresh], freed)
	testing.expect_value(t, s.records[freed].id, entity_id(fresh))
}

// The null backend, a world and a renderer, for the tests of the extra views (see Extra_View).
@(private = "file")
Rig :: struct {
	arena:    virtual.Arena,
	platform: core.Platform_API,
	record:   Hook_Record,
	w:        ^ecs.World,
	dir:      string,
	assets:   asset.Assets,
	r:        ^Renderer,
}

// rig_start starts the rig. The caller then sets context.logger to record_problems with the rig's record, so a frame's
// warnings and errors come to rig.record.problems.
@(private = "file")
rig_start :: proc(t: ^testing.T, rig: ^Rig) {
	testing.expect(t, virtual.arena_init_growing(&rig.arena) == nil)
	testing.expect(t, jobs.init(2))
	testing.expect(t, null.init(nil, {64, 32}))
	rig.platform = test_platform(&rig.arena)
	rig.record.problems = make([dynamic]string)
	rig.record.runner = context.logger
	rig.w = new(ecs.World)
	testing.expect(t, ecs.init(rig.w, &rig.platform))
	ecs.register_engine_components(&rig.w.registry)
	volume.register_components(&rig.w.registry)
	register_components(&rig.w.registry)
	dir, err := os.make_directory_temp("", "renderer_test_*", context.temp_allocator)
	testing.expect(t, err == nil)
	rig.dir = strings.clone(dir)
	asset.init(&rig.assets, &rig.platform, asset.loose_cache(rig.dir))
	rig.r = new(Renderer)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	renderer_init(rig.r, &rig.platform, &rig.assets, rig.w)
}

@(private = "file")
rig_stop :: proc(rig: ^Rig) {
	renderer_destroy(rig.r)
	free(rig.r)
	asset.destroy(&rig.assets)
	os.remove_all(rig.dir)
	delete(rig.dir)
	ecs.destroy(rig.w)
	free(rig.w)
	null.shutdown()
	jobs.shutdown()
	virtual.arena_destroy(&rig.arena)
	for p in rig.record.problems {
		delete(p)
	}
	delete(rig.record.problems)
}

// forget_problems drops the problems that a test expected.
@(private = "file")
forget_problems :: proc(rig: ^Rig) {
	for p in rig.record.problems {
		delete(p)
	}
	clear(&rig.record.problems)
}

// enable_output_pipelines gives the output pass a pipeline for each output mode, so it draws.
@(private = "file")
enable_output_pipelines :: proc(r: ^Renderer) {
	code := []byte{1}
	for mode in gpu.Output_Mode {
		r.output_pipelines[mode].pipeline = r.platform.gpu_create_graphics_pipeline(
			{vertex = code, pixel = code, colors = {{format = gpu.output_format(mode)}}, label = "test output"},
		)
	}
}

// enable_frame_pipelines is enable_pipelines with the rest of what a frame at the default quality draws with: the output
// passes, FXAA and SMAA, the reflection probes and the virtual shadow map.
@(private = "file")
enable_frame_pipelines :: proc(r: ^Renderer) {
	platform := r.platform
	code := []byte{1}
	enable_pipelines(r)
	enable_output_pipelines(r)
	r.post.spatial.tone_map.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	r.post.spatial.fxaa.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	smaa := [?]struct {
		pipeline: ^Shader_Pipeline,
		format:   gpu.Format,
	}{{&r.post.spatial.smaa_edges, SMAA_EDGES_FORMAT}, {&r.post.spatial.smaa_weights, SMAA_WEIGHTS_FORMAT}, {&r.post.spatial.smaa_blend, DISPLAY_FORMAT}}
	for s in smaa {
		s.pipeline.pipeline = platform.gpu_create_graphics_pipeline({vertex = code, pixel = code, colors = {{format = s.format}}, label = "test smaa"})
	}
	rp := &r.reflection_probes
	for p in ([]^Shader_Pipeline{&rp.face, &rp.downsample, &r.lights.pipeline, &r.shadows.virtual.mark_pipeline, &r.shadows.virtual.allocate_pipeline}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = code, label = "test"})
	}
}

// fill_world makes the world of the extra views' tests: a sun and a lamp that cast shadows, meshes that hold slots, a
// reflection probe, and a global volume with fog, clouds and an atmosphere whose sun is the directional light.
@(private = "file")
fill_world :: proc(w: ^ecs.World) {
	sun := ecs.spawn(w)
	ecs.add(w, sun, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, sun, Directional_Light{intensity = 1, cast_shadows = true})
	lamp := ecs.spawn(w)
	ecs.add(w, lamp, ecs.Transform{position = ecs.position_offset({}, {0, 0, 2}), rotation = 1, scale = 1})
	ecs.add(w, lamp, Point_Light{intensity = 1, cast_shadows = true})
	for k in 0 ..< 3 {
		mesh := ecs.spawn(w)
		ecs.add(w, mesh, ecs.Transform{position = ecs.position_offset({}, {f32(k), 0, 5}), rotation = 1, scale = 1})
		ecs.add(w, mesh, Mesh_Renderer{})
	}
	probe := ecs.spawn(w)
	ecs.add(w, probe, ecs.Transform{position = ecs.position_offset({}, {0, 1, 3}), rotation = 1, scale = 1})
	ecs.add(w, probe, Reflection_Probe{extent = {2, 1, 2}, box_projection = true})
	mist := ecs.spawn(w)
	ecs.add(w, mist, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, mist, volume.Volume{shape = .Global})
	ecs.add(w, mist, Fog{density = {true, 0.05}, height_falloff = {true, 0.5}})
	ecs.add(w, mist, Clouds{density = {true, 1}})
	environment := DEFAULT_ENVIRONMENT
	environment.mode = {true, .Atmosphere}
	environment.sun = {true, sun}
	ecs.add(w, mist, environment)
}

// extra_target makes a target for an extra view, as the editor's shared ones are: in the render target layout.
@(private = "file")
extra_target :: proc(platform: ^core.Platform_API, size: [2]u32) -> gpu.Texture {
	return platform.gpu_create_texture({size = size, format = gpu.FRAME_TARGET_FORMAT, usage = {.Render_Target}, label = "extra view"}, nil)
}

// What a view's hooks saw.
@(private = "file")
View_Record :: struct {
	before_world, after_prepass, before_post, ui, debug: int,
	position:      ecs.World_Position,
	size:          [2]u32,
	output_size:   [2]u32,
	extra:         bool,
	// The debug hook's layer, the lines it was given, the first of them, and the temporal AA's history.
	layer:         bool,
	lines:         int,
	first_line:    Debug_Vertex_Line,
	history_valid: bool,
	// The bloom that the view's settings turn off.
	no_bloom:      bool,
}

// RECORD_HOOKS record into the View_Record that is their data.
@(private = "file")
RECORD_HOOKS :: Frame_Hooks {
	before_world = proc(f: ^Frame) {
		rec := (^View_Record)(f.data)
		rec.before_world += 1
		rec.position, rec.size, rec.output_size, rec.extra = f.view.position, f.size, f.output_size, f.extra
	},
	after_prepass = proc(f: ^Frame) {
		(^View_Record)(f.data).after_prepass += 1
	},
	before_post = proc(f: ^Frame) {
		rec := (^View_Record)(f.data)
		rec.before_post += 1
		rec.no_bloom = f.post.settings.no_bloom
	},
	ui = proc(f: ^Frame) {
		(^View_Record)(f.data).ui += 1
		p := add_render_pass(f.graph, "hud", proc(_: ^Pass_Context) {}, nil)
		color(f.graph, p, f.ui, .Load)
	},
	debug = proc(f: ^Frame) {
		rec := (^View_Record)(f.data)
		rec.debug += 1
		rec.layer, rec.lines, rec.history_valid = f.debug != 0, f.tested_lines + f.overlay_lines, f.post.history.valid
		if rec.lines > 0 {
			rec.first_line = ([^]Debug_Vertex_Line)(raw_data(f.debug_lines.data))[0]
		}
	},
}

// The target of each draw that the submissions made, in order, and whether the next submission fails.
@(private = "file")
Draw_Log :: struct {
	drawn:     [dynamic]gpu.Texture,
	fail_next: bool,
}

@(private = "file")
draw_log: Draw_Log

// logging_submit submits to the null backend, and logs the color target of each draw. With draw_log.fail_next, the next
// submission fails before it reaches the backend, as a lost device's does, and the ones after it do not.
@(private = "file")
logging_submit :: proc(buffers: []gpu.Command_Buffer, queue := gpu.Queue.Graphics, wait_for := gpu.Queues{}) -> bool {
	if draw_log.fail_next {
		draw_log.fail_next = false
		return false
	}
	for cb in buffers {
		it := gpu.packet_iterator(cb)
		target: gpu.Texture
		for p in gpu.next_packet(&it) {
			#partial switch p.kind {
			case .Begin_Pass:
				pass := gpu.payload(p, gpu.Begin_Pass)
				target = pass.color_count > 0 ? pass.colors[0].texture : {}
			case .End_Pass:
				target = {}
			case .Draw:
				if target != {} {
					append(&draw_log.drawn, target)
				}
			}
		}
	}
	return null.submit(buffers, queue, wait_for)
}

// draws_into is how many draws the log has into a target, and the index of the first.
@(private = "file")
draws_into :: proc(target: gpu.Texture) -> (count: int, first: int) {
	first = -1
	for t, i in draw_log.drawn {
		if t == target {
			count += 1
			first = first < 0 ? i : first
		}
	}
	return
}

// A frame's extra views each draw into their own target, after the frame's own view, which is the first to draw. A view
// with no target or no size draws nothing and runs no hook, and so does a view past MAX_EXTRA_VIEWS. If the frame's own
// view does not execute, the extra views still draw, and the frame says that it failed.
@(test)
an_extra_view_draws_into_its_own_target :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	enable_output_pipelines(r)
	main_target := platform.gpu_frame_target()
	first, second, third := extra_target(platform, {32, 16}), extra_target(platform, {40, 20}), extra_target(platform, {16, 8})
	defer {
		for target in ([]gpu.Texture{first, second, third}) {
			platform.gpu_destroy_texture(target)
		}
	}
	platform.gpu_submit = logging_submit
	defer platform.gpu_submit = null.submit
	defer {
		delete(draw_log.drawn)
		draw_log = {}
	}

	records: [4]View_Record
	views: [4]Extra_View
	targets := [4]gpu.Texture{first, second, third, first}
	for &v, i in views {
		v = {
			view   = {position = ecs.position_offset({}, {f32(i), 0, 0}), rotation = 1, vertical_fov = 1, near = 0.05},
			size   = {32, 16},
			target = targets[i],
			hooks  = RECORD_HOOKS,
		}
		v.hooks.data = &records[i]
	}
	desc := Frame_Desc {
		view        = {rotation = 1, vertical_fov = 1, near = 0.05},
		size        = {64, 32},
		extra_views = views[:],
	}
	testing.expect(t, draw_frame(r, rig.w, desc), "the frame with extra views did not execute")
	main_draws, main_first := draws_into(main_target)
	first_draws, first_first := draws_into(first)
	second_draws, second_first := draws_into(second)
	third_draws, third_first := draws_into(third)
	testing.expect_value(t, main_draws, 1)
	testing.expect_value(t, first_draws, 1)
	testing.expect_value(t, second_draws, 1)
	testing.expect_value(t, third_draws, 1)
	testing.expect(t, main_first < first_first && first_first < second_first && second_first < third_first, "the views did not draw in order")
	for i in 0 ..< 3 {
		testing.expect_value(t, records[i].before_world, 1)
	}
	// The fourth view is past the limit, and the frame says so.
	testing.expect_value(t, records[3].before_world, 0)
	testing.expect_value(t, len(rig.record.problems), 1)
	testing.expect(t, len(rig.record.problems) == 1 && strings.contains(rig.record.problems[0], "extra views"))
	forget_problems(rig)

	// A view with no target or no size draws nothing and runs no hook.
	skipped := [3]Extra_View{views[0], views[1], views[2]}
	skipped[0].target = {}
	skipped[1].size = {}
	desc.extra_views = skipped[:]
	clear(&draw_log.drawn)
	testing.expect(t, draw_frame(r, rig.w, desc), "the frame with views to skip did not execute")
	first_draws, _ = draws_into(first)
	second_draws, _ = draws_into(second)
	third_draws, _ = draws_into(third)
	testing.expect_value(t, first_draws, 0)
	testing.expect_value(t, second_draws, 0)
	testing.expect_value(t, third_draws, 1)
	testing.expect_value(t, records[0].before_world, 1)
	testing.expect_value(t, records[1].before_world, 1)
	testing.expect_value(t, records[2].before_world, 2)

	// The frame's own view does not execute, the extra views do, and the frame says so.
	desc.extra_views = views[:3]
	clear(&draw_log.drawn)
	draw_log.fail_next = true
	testing.expect(t, !draw_frame(r, rig.w, desc), "the frame executed with a submit that fails")
	first_draws, _ = draws_into(first)
	second_draws, _ = draws_into(second)
	third_draws, _ = draws_into(third)
	testing.expect_value(t, first_draws, 1)
	testing.expect_value(t, second_draws, 1)
	testing.expect_value(t, third_draws, 1)
	testing.expect_value(t, records[0].before_world, 2)
	forget_problems(rig)
}

// Frame_State is what a frame leaves of the renderer's state that lasts between frames, without the handles of its
// resources: the GPU scene's origin, frame and previous camera, the cache's frame and histories, post-processing's
// jitter, lookup table and exposure, the reflection probes' slots, the sky's cached ambient light and its cubemap's
// ring, and the counters of the features that keep a history.
@(private = "file")
Frame_State :: struct {
	scene_frame, copied_frame, alpha_frame:       u64,
	origin:                                       ecs.World_Position,
	origin_set:                                   bool,
	slots, free_slots:                            int,
	high, cell_high:                              u32,
	uploaded_slots:                               int,
	previous_position:                            ecs.World_Position,
	previous_rotation:                            quaternion128,
	previous_view_projection, previous_view_model: matrix[4, 4]f32,
	previous_time:                                f32,
	has_previous:                                 bool,
	cache_frame:                                  u64,
	histories:                                    [MAX_HISTORY_TEXTURES][5]u64,
	jitter_index:                                 u32,
	last_time:                                    f64,
	adapted:                                      bool,
	lut_bake:                                     Maybe(Lut_Bake),
	upscaler_active:                              bool,
	upscaler_size:                                [2]u32,
	probe_frame:                                  u64,
	probe_slots:                                  [MAX_REFLECTION_PROBES]Reflection_Probe_Slot,
	probe_spare:                                  i32,
	probe_capture:                                Maybe(Reflection_Probe_Capture),
	probe_stats:                                  Reflection_Probe_Stats,
	ambient_key:                                  Sky_Light_Key,
	ambient_valid:                                bool,
	ambient:                                      Ambient,
	cube_ring:                                    Sky_Cube_Ring,
	last_sky_mode:                                Sky_Mode,
	ao_frame, fog_frame, gi_frame:                u32,
	clouds_frame:                                 u32,
	ssr_frame:                                    u32,
	virtual_pages:                                [2]u32,
	ribbon_capacity, mesh_capacity:               int,
}

@(private = "file")
frame_state :: proc(r: ^Renderer) -> (state: Frame_State) {
	s := &r.scene
	state = {
		scene_frame              = s.frame,
		copied_frame             = s.copied_frame,
		alpha_frame              = s.alpha_frame,
		origin                   = s.origin,
		origin_set               = s.origin_set,
		slots                    = len(s.slots),
		free_slots               = len(s.free),
		high                     = s.high,
		cell_high                = s.cell_high,
		uploaded_slots           = s.uploaded_slots,
		previous_position        = s.previous_position,
		previous_rotation        = s.previous_rotation,
		previous_view_projection = s.previous_view_projection,
		previous_view_model      = s.previous_view_model,
		previous_time            = s.previous_time,
		has_previous             = s.has_previous,
		cache_frame              = r.textures.frame,
		jitter_index             = r.post.jitter_index,
		last_time                = r.post.last_time,
		adapted                  = r.post.adapted,
		lut_bake                 = r.post.lut_bake,
		upscaler_active          = r.post.upscalers.active,
		upscaler_size            = r.post.upscalers.render_size,
		probe_frame              = r.reflection_probes.frame,
		probe_slots              = r.reflection_probes.slots,
		probe_spare              = r.reflection_probes.spare,
		probe_capture            = r.reflection_probes.capture,
		probe_stats              = r.reflection_probes.stats,
		ambient_key              = r.sky.ambient_key,
		ambient_valid            = r.sky.ambient_valid,
		ambient                  = r.sky.ambient,
		cube_ring                = r.sky.cube.ring,
		last_sky_mode            = r.last_sky_mode,
		ao_frame                 = u32(r.ao.frame),
		fog_frame                = u32(r.fog.frame),
		gi_frame                 = u32(r.gi.frame),
		clouds_frame             = u32(r.clouds.frame),
		ssr_frame                = u32(r.ssr.frame),
		virtual_pages            = r.shadows.virtual.pool_pages,
		ribbon_capacity          = r.particles.ribbon_capacity,
		mesh_capacity            = r.particles.mesh_capacity,
	}
	for h, i in r.textures.histories {
		state.histories[i] = {h.label_hash, h.written, h.last_used, u64(h.current), u64(h.textures[0] != {})}
	}
	return
}

// What the frame's own view's debug hook saw, for the tests below that compare two renderers' frames.
@(private = "file")
Main_Record :: struct {
	history_valid: [16]bool,
	frames:        int,
}

// An extra view changes none of the state that lasts between frames: a renderer that draws the frame's own view with extra
// views at other places and sizes, one of them high above the others, has the state of one that draws it alone, after
// each frame, and its frame's own view saw the same histories. Every feature runs, and the null backend checks every barrier
// and wait of the extra views' graphs.
@(test)
an_extra_view_changes_none_of_the_frames_state :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	platform := &rig.platform
	// The renderer that draws extra views, and the reference that does not.
	extra_r, reference := rig.r, new(Renderer)
	renderer_init(reference, platform, &rig.assets, rig.w)
	defer {
		renderer_destroy(reference)
		free(reference)
	}
	fill_world(rig.w)
	for r in ([]^Renderer{extra_r, reference}) {
		enable_frame_pipelines(r)
	}
	defer platform.gpu_destroy_texture(extra_r.blue_noise.texture)
	defer platform.gpu_destroy_texture(reference.blue_noise.texture)
	targets := [2]gpu.Texture{extra_target(platform, {32, 16}), extra_target(platform, {48, 24})}
	defer {
		for target in targets {
			platform.gpu_destroy_texture(target)
		}
	}

	main_hooks := Frame_Hooks {
		debug = proc(f: ^Frame) {
			rec := (^Main_Record)(f.data)
			rec.history_valid[rec.frames] = f.post.history.valid
			rec.frames += 1
		},
	}
	records: [2]Main_Record
	extra_records: [2]View_Record
	for k in 0 ..< 10 {
		at := ecs.position_offset({}, {f32(k) * 2, 1, -4})
		views := [2]Extra_View {
			{
				view = {position = ecs.position_offset({}, {30 + f32(k), 5, 2}), rotation = 1, vertical_fov = 1, near = 0.05},
				size = {32, 16},
				target = targets[0],
				hooks = RECORD_HOOKS,
			},
			// High above the others, where the sky's ambient light is not the frame's own view's.
			{
				view = {position = ecs.position_offset({}, {-300, 3000, 0}), rotation = 1, vertical_fov = 1, near = 0.05},
				size = {48, 24},
				target = targets[1],
				disable = {.Bloom},
				hooks = RECORD_HOOKS,
			},
		}
		for &v, i in views {
			v.hooks.data = &extra_records[i]
		}
		desc := Frame_Desc {
			view  = {position = at, rotation = 1, vertical_fov = 1, near = 0.05},
			size  = {64, 32},
			hooks = main_hooks,
		}
		desc.hooks.data = &records[0]
		testing.expect(t, draw_frame(reference, rig.w, desc), "the frame without extra views did not execute")
		desc.hooks.data = &records[1]
		desc.extra_views = views[:]
		testing.expect(t, draw_frame(extra_r, rig.w, desc), "the frame with extra views did not execute")

		want, got := frame_state(reference), frame_state(extra_r)
		testing.expect_value(t, got.scene_frame, want.scene_frame)
		testing.expect_value(t, got.origin, want.origin)
		testing.expect_value(t, got.previous_position, want.previous_position)
		testing.expect_value(t, got.previous_view_projection, want.previous_view_projection)
		testing.expect_value(t, got.cache_frame, want.cache_frame)
		testing.expect_value(t, got.histories, want.histories)
		testing.expect_value(t, got.jitter_index, want.jitter_index)
		testing.expect_value(t, got.probe_slots, want.probe_slots)
		testing.expect_value(t, got.ambient_key, want.ambient_key)
		testing.expect_value(t, got.cube_ring, want.cube_ring)
		testing.expectf(t, got == want, "frame %d: the state differs: %v != %v", k, got, want)
		testing.expect_value(t, extra_records[0].before_world, k + 1)
		testing.expect_value(t, extra_records[1].before_world, k + 1)
	}
	// The frames after the first read the histories that the frame before wrote, extra views or not.
	testing.expect_value(t, records[1], records[0])
	testing.expect(t, records[1].history_valid[1] && records[1].history_valid[9], "the temporal AA's history was not valid")
	testing.expect(t, !records[1].history_valid[0])
	// The frames' captures finished, so the extra views read probes with cubes.
	testing.expect(t, reflection_probe_stats(extra_r).slots > 0, "no probe was captured")
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// A frame whose own view does not execute marks no history as written, though its extra views do execute: the frame
// after starts its histories over.
@(test)
a_failed_frame_with_extra_views_leaves_its_histories_unwritten :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	fill_world(rig.w)
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	target := extra_target(platform, {32, 16})
	defer platform.gpu_destroy_texture(target)
	platform.gpu_submit = logging_submit
	defer platform.gpu_submit = null.submit
	defer {
		delete(draw_log.drawn)
		draw_log = {}
	}

	record: View_Record
	desc := Frame_Desc {
		view  = {rotation = 1, vertical_fov = 1, near = 0.05},
		size  = {64, 32},
		hooks = RECORD_HOOKS,
	}
	desc.hooks.data = &record
	view_record: View_Record
	extra := Extra_View {
		view   = {position = ecs.position_offset({}, {20, 0, 0}), rotation = 1, vertical_fov = 1, near = 0.05},
		size   = {32, 16},
		target = target,
		hooks  = RECORD_HOOKS,
	}
	extra.hooks.data = &view_record
	extras := [1]Extra_View{extra}
	desc.extra_views = extras[:]
	Step :: struct {
		fails: bool,
		valid: bool,
	}
	// Valid history needs a frame before it that executed.
	steps := [?]Step{{false, false}, {false, true}, {true, true}, {false, false}, {false, true}}
	for step, i in steps {
		draw_log.fail_next = step.fails
		testing.expectf(t, draw_frame(r, rig.w, desc) == !step.fails, "frame %d: executed %v", i, !step.fails)
		testing.expectf(t, record.history_valid == step.valid, "frame %d: history valid %v, want %v", i, record.history_valid, step.valid)
		// The extra view draws in a frame that failed, too, and it never has a history.
		count, _ := draws_into(target)
		testing.expect_value(t, count, i + 1)
		testing.expect(t, !view_record.history_valid)
	}
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// An extra view's hooks run at the same points as the frame's own, with a frame of its own: its view, its size and its
// output size, at the quality's render scale, and the settings of the volumes at its place. A frame's own settings,
// given in Frame_Desc, are the extra view's too. Frame.extra says which it is.
@(test)
an_extra_views_hooks_run_with_its_own_view_and_size :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	w := rig.w
	// A box of volume around the extra view, with no bloom.
	room := ecs.spawn(w)
	ecs.add(w, room, ecs.Transform{position = ecs.position_offset({}, {100, 0, 0}), rotation = 1, scale = 1})
	ecs.add(w, room, volume.Volume{shape = .Box, extents = {10, 10, 10}})
	ecs.add(w, room, Bloom{off = {true, true}})
	target := extra_target(platform, {32, 16})
	defer platform.gpu_destroy_texture(target)

	main_record, extra_record: View_Record
	extra_at := ecs.position_offset({}, {100, 0, 0})
	quality := r.quality
	quality.render_scale = 0.5
	extras := [1]Extra_View{{view = {position = extra_at, rotation = 1, vertical_fov = 1, near = 0.05}, size = {32, 16}, target = target, hooks = RECORD_HOOKS}}
	extras[0].hooks.data = &extra_record
	desc := Frame_Desc {
		view        = {position = ecs.position_offset({}, {1, 2, 3}), rotation = 1, vertical_fov = 1, near = 0.05},
		size        = {64, 32},
		quality     = &quality,
		hooks       = RECORD_HOOKS,
		extra_views = extras[:],
	}
	desc.hooks.data = &main_record
	testing.expect(t, draw_frame(r, w, desc), "the frame did not execute")
	for rec in ([]View_Record{main_record, extra_record}) {
		for count in ([]int{rec.before_world, rec.after_prepass, rec.before_post, rec.ui, rec.debug}) {
			testing.expect_value(t, count, 1)
		}
	}
	testing.expect(t, !main_record.extra && extra_record.extra)
	testing.expect_value(t, main_record.position, desc.view.position)
	testing.expect_value(t, extra_record.position, extra_at)
	testing.expect_value(t, main_record.size, [2]u32{32, 16})
	testing.expect_value(t, main_record.output_size, [2]u32{64, 32})
	testing.expect_value(t, extra_record.size, [2]u32{16, 8})
	testing.expect_value(t, extra_record.output_size, [2]u32{32, 16})
	// The volumes at each view's place give its settings.
	testing.expect(t, !main_record.no_bloom && extra_record.no_bloom, "the settings are not the volumes' at each view")

	// Settings that the frame is given are the extra view's too.
	settings := resolve_settings(r, w, desc.view.position)
	desc.settings = &settings
	testing.expect(t, draw_frame(r, w, desc), "the frame with its settings did not execute")
	testing.expect(t, !main_record.no_bloom && !extra_record.no_bloom, "the extra view did not take the frame's settings")
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// The debug lines of a frame reach its extra views as well as its own view, each relative to its own camera, unless the
// view has none. The frame drops them after its last view, and keeps those with a duration for the next frames.
@(test)
the_debug_lines_of_a_frame_reach_its_extra_views :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	first, second := extra_target(platform, {32, 16}), extra_target(platform, {32, 16})
	defer {
		platform.gpu_destroy_texture(first)
		platform.gpu_destroy_texture(second)
	}

	records: [3]View_Record
	extra_at := ecs.position_offset({}, {10, 0, 0})
	extras := [2]Extra_View {
		{view = {position = extra_at, rotation = 1, vertical_fov = 1, near = 0.05}, size = {32, 16}, target = first, hooks = RECORD_HOOKS},
		// This one has no debug layer, and its hook still runs.
		{view = {rotation = 1, vertical_fov = 1, near = 0.05}, size = {32, 16}, target = second, no_debug = true, hooks = RECORD_HOOKS},
	}
	extras[0].hooks.data = &records[1]
	extras[1].hooks.data = &records[2]
	desc := Frame_Desc {
		view        = {position = ecs.position_offset({}, {1, 0, 0}), rotation = 1, vertical_fov = 1, near = 0.05},
		size        = {64, 32},
		hooks       = RECORD_HOOKS,
		extra_views = extras[:],
	}
	desc.hooks.data = &records[0]
	from, to := ecs.position_offset({}, {2, 3, 4}), ecs.position_offset({}, {2, 3, 5})
	debug.line(&r.debug, from, to, {1, 0, 0, 1})
	debug.line(&r.debug, from, to, {0, 1, 0, 1}, duration = 60, mode = .Overlay)
	testing.expect(t, draw_frame(r, rig.w, desc), "the frame did not execute")
	for rec, i in records {
		testing.expect_value(t, rec.debug, 1)
		testing.expectf(t, rec.layer == (i != 2), "view %d: debug layer %v", i, rec.layer)
		testing.expect_value(t, rec.lines, i != 2 ? 2 : 0)
	}
	testing.expect_value(t, records[0].first_line.a, ecs.position_sub(from, desc.view.position))
	testing.expect_value(t, records[1].first_line.a, ecs.position_sub(from, extra_at))
	testing.expect_value(t, records[1].first_line.b, ecs.position_sub(to, extra_at))
	// The line of this frame is gone, and the one with a duration stays for the views of the next.
	testing.expect_value(t, len(debug.frame_lines(&r.debug)), 1)
	testing.expect(t, draw_frame(r, rig.w, desc), "the next frame did not execute")
	for rec, i in records {
		testing.expect_value(t, rec.debug, 2)
		testing.expect_value(t, rec.lines, i != 2 ? 1 : 0)
	}
	testing.expect_value(t, records[1].first_line.a, ecs.position_sub(from, extra_at))
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

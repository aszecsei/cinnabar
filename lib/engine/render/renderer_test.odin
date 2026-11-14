package render

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"

import "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
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
		&r.sky.aerial,
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
		// The scatter of the GPU scene's changed records.
		&r.scene.scatter_pipeline,
		&r.scene.select_pipeline,
		&r.scene.cull_patches_pipeline,
		// The traced shadows, so the lights trace their mask, and the frame builds the ray scene before it.
		&r.shadows.mask_pipeline,
		// The traced mask's denoiser, for its lights with a size.
		&r.shadows.temporal_pipeline,
		&r.shadows.spatial_pipeline,
		// The contact shadows, which the sun takes where the frame does not trace.
		&r.shadows.contact_pipeline,
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
		view = {rotation = 1, projection = Perspective{1, 0.05}},
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
					_, rec.capture_gi = pf.face_light[pf.first_face].(Reflection_Probe_Voxel_Light)
					_, rec.capture_occlusion = pf.face_light[pf.first_face].(Reflection_Probe_Occlusion)
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
	testing.expect(t, !r.view.post.adapted, "the failed frame adapted the exposure")
	testing.expect(t, !r.sky.cube.ring.valid, "the failed frame made the sky's cubemap")
	testing.expect(t, r.view.gi.split.slots == {} || r.view.gi.split.fresh, "the failed frame cleared the split cascades' storage")
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
		testing.expect(t, r.post.lut_bake != nil && r.view.post.adapted)
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
		testing.expect(t, r.view.virtual_shadows.pool != {})
		testing.expect(t, r.view.virtual_shadows.table != {} && r.view.virtual_shadows.pages != {})
		testing.expect_value(t, r.view.virtual_shadows.pool_pages, SHADOW_PARAMS[.High].pool_pages)
		// The frame that executed keeps what it drew for. With the cache, the next frame keeps it and counts on.
		cache, cached := r.view.virtual_shadows.cache.?
		testing.expect(t, cached && cache.epoch == 1 && cache.params == SHADOW_PARAMS[.High], "the frame kept no cache")
		q.shadows.virtual_cache = true
		testing.expect(t, draw_frame(r, w, desc), "the virtual shadow map's frame did not execute")
		cache, cached = r.view.virtual_shadows.cache.?
		testing.expect(t, cached && cache.epoch == 2 && cache.settings.virtual_cache, "the cache did not count on")
		// A level with another pool remakes it, whose pages hold nothing, so the cache starts again.
		q.shadows.level = .Ultra
		testing.expect(t, draw_frame(r, w, desc), "the virtual shadow map's frame did not execute")
		testing.expect_value(t, r.view.virtual_shadows.pool_pages, SHADOW_PARAMS[.Ultra].pool_pages)
		cache, cached = r.view.virtual_shadows.cache.?
		testing.expect(t, cached && cache.epoch == 1 && cache.params == SHADOW_PARAMS[.Ultra], "the new pool kept the old cache")
		// A frame that records the stats' copy and then fails writes no copy and does not move on, so its stats show none,
		// and it keeps the cache of the last frame that ran.
		next := r.view.virtual_shadows.stats_ring.next
		platform.gpu_submit = fail_submit
		testing.expect(t, !draw_frame(r, w, desc), "the frame executed with a submit that fails")
		platform.gpu_submit = null.submit
		testing.expect_value(t, r.view.virtual_shadows.stats_ring.next, next)
		testing.expect_value(t, virtual_shadow_stats(r), Virtual_Shadow_Stats{})
		kept, _ := r.view.virtual_shadows.cache.?
		testing.expect_value(t, kept, cache)
		q.shadows = {level = .Low, virtual = true}
		testing.expect(t, draw_frame(r, w, desc), "the cascades' frame did not execute")
		testing.expect_value(t, record.shadow_views, SHADOW_PARAMS[.Low].cascades + 6)
		// What moved while the cascades drew is not known, so the cache is gone.
		testing.expect(t, r.view.virtual_shadows.cache == nil, "the cascades' frame kept the cache")
		// The cascades' frame copies no virtual stats, so none are written, and none show.
		testing.expect_value(t, r.view.virtual_shadows.stats_ring.written, [READBACK_COPIES]bool{})
		testing.expect_value(t, virtual_shadow_stats(r), Virtual_Shadow_Stats{})
		q.shadows = {level = .High, virtual = false}
		testing.expect(t, draw_frame(r, w, desc), "the cascades' frame did not execute")
		testing.expect_value(t, record.shadow_views, SHADOW_CASCADES + 6)
		desc.quality = nil
	}
	testing.expectf(t, len(record.problems) == 0, "problems: %v", record.problems)

	// The atlas's cache: with its pipeline, the lamp's six faces draw into the cache, which the frames after copy. A
	// light that moves draws again, a frame that fails keeps the cache of the last frame that ran, and a frame without the
	// cache forgets it. The null backend validates the cache's pass and its copy.
	r.shadows.cache_pipeline.pipeline = platform.gpu_create_graphics_pipeline(
		{vertex = code, pixel = code, depth_format = SHADOW_FORMAT, depth_compare = .Always, depth_write = true, label = "test"},
	)
	{
		q := r.quality
		q.shadows = {level = .High, atlas_cache = true}
		desc.quality = &q
		testing.expect(t, draw_frame(r, w, desc), "the cache's frame did not execute")
		testing.expect_value(t, record.shadow_views, SHADOW_CASCADES + 6)
		testing.expect(t, r.view.atlas_cache.texture != {} && r.view.atlas_cache.size == SHADOW_PARAMS[.High].atlas)
		cache, cached := r.view.atlas_cache.cache.?
		testing.expect(t, cached && cache.count == 1 && cache.lights[0].light.entity == lamp, "the frame kept no cache of the lamp")
		testing.expect_value(t, atlas_cache_stats(r), Atlas_Cache_Stats{lights = 1, copied = 6, drawn = 6})
		testing.expect(t, draw_frame(r, w, desc), "the cache's frame did not execute")
		testing.expect_value(t, atlas_cache_stats(r), Atlas_Cache_Stats{lights = 1, copied = 6})
		ecs.get_write(w, lamp, ecs.Transform).position = ecs.position_offset({}, {0, 0, 3})
		testing.expect(t, draw_frame(r, w, desc), "the cache's frame did not execute")
		testing.expect_value(t, atlas_cache_stats(r), Atlas_Cache_Stats{lights = 1, copied = 6, drawn = 6})
		cache, cached = r.view.atlas_cache.cache.?
		platform.gpu_submit = fail_submit
		ecs.get_write(w, lamp, ecs.Transform).position = ecs.position_offset({}, {0, 0, 2})
		testing.expect(t, !draw_frame(r, w, desc), "the frame executed with a submit that fails")
		platform.gpu_submit = null.submit
		kept, _ := r.view.atlas_cache.cache.?
		testing.expect_value(t, kept, cache)
		// The frame after the failed one missed its changes, so it starts again.
		testing.expect(t, draw_frame(r, w, desc), "the cache's frame did not execute")
		testing.expect_value(t, atlas_cache_stats(r).drawn, 6)
		q.shadows.atlas_cache = false
		testing.expect(t, draw_frame(r, w, desc), "the frame without the cache did not execute")
		testing.expect(t, r.view.atlas_cache.cache == nil, "the frame without the cache kept it")
		testing.expect_value(t, atlas_cache_stats(r), Atlas_Cache_Stats{})
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
		testing.expect(t, r.view.gi.voxel.running, "the voxel cones did not run")
		testing.expect(t, r.view.gi.voxel.boxes[0].voxelized)
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
	testing.expect_value(t, r.view.shading.stats_ring.next, 2)
	desc.shading_stats = false
	testing.expect(t, draw_frame(r, w, desc), "the frame without the shading stats did not execute")
	testing.expect_value(t, r.view.shading.stats_ring.next, 2)
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
		f.state = &r.view
		f.view = {position = at, rotation = 1, projection = Perspective{1, 0.05}}
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
	testing.expect_value(t, frame(r, w, far), 0)

	// An entity that is deactivated leaves its slot, and one that is activated again takes a slot with its pose.
	testing.expect(t, ecs.set_active(w, mover, false))
	left := s.slots[mover]
	testing.expect_value(t, frame(r, w, far), 1)
	testing.expect_value(t, s.records[left], Instance_Record{})
	_, has_slot := s.slots[mover]
	testing.expect(t, !has_slot)
	testing.expect(t, ecs.set_active(w, mover, true))
	testing.expect_value(t, frame(r, w, far), 1)
	back := s.slots[mover]
	testing.expect_value(t, s.records[back].id, entity_id(mover))
	testing.expect_value(t, s.records[back].rows, pose_rows(ecs.get(w, mover, ecs.Transform)^, s.origin))
	testing.expect_value(t, frame(r, w, far), 0)

	// Many entities of one archetype, of which a scattered few move: each one's record and no other, wherever its slot is.
	crowd := make([dynamic]ecs.Entity, context.temp_allocator)
	for _ in 0 ..< 2000 {
		e := ecs.spawn(w)
		ecs.add(w, e, ecs.TRANSFORM_IDENTITY)
		ecs.add(w, e, Mesh_Renderer{})
		append(&crowd, e)
	}
	testing.expect_value(t, frame(r, w, far), 2000)
	testing.expect_value(t, frame(r, w, far), 0)
	for e, i in crowd {
		if i % 40 == 0 {
			ecs.get_write(w, e, ecs.Transform).position = ecs.position_offset({}, {f32(i + 1), 0, 0})
		}
	}
	testing.expect_value(t, frame(r, w, far), 50)
	testing.expect_value(t, frame(r, w, far), 50)
	testing.expect_value(t, frame(r, w, far), 0)

	// An edit of one entity, as the editor's inspector writes it.
	ecs.get_write(w, crowd[1234], ecs.Transform).scale = {2, 2, 2}
	testing.expect_value(t, frame(r, w, far), 1)
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

// rig_start starts the rig, with a frame target of size. The caller then sets context.logger to record_problems with the
// rig's record, so a frame's warnings and errors come to rig.record.problems.
@(private = "file")
rig_start :: proc(t: ^testing.T, rig: ^Rig, size := [2]i32{64, 32}) {
	testing.expect(t, virtual.arena_init_growing(&rig.arena) == nil)
	testing.expect(t, jobs.init(2))
	testing.expect(t, null.init(nil, size))
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
// reflection probe, and a global volume, mist, with fog, clouds and an atmosphere whose sun is the directional light.
@(private = "file")
fill_world :: proc(w: ^ecs.World) -> (probe, mist: ecs.Entity) {
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
	probe = ecs.spawn(w)
	ecs.add(w, probe, ecs.Transform{position = ecs.position_offset({}, {0, 1, 3}), rotation = 1, scale = 1})
	ecs.add(w, probe, Reflection_Probe{extent = {2, 1, 2}, box_projection = true})
	mist = ecs.spawn(w)
	ecs.add(w, mist, ecs.TRANSFORM_IDENTITY)
	ecs.add(w, mist, volume.Volume{shape = .Global})
	ecs.add(w, mist, Fog{density = {true, 0.05}, height_falloff = {true, 0.5}})
	ecs.add(w, mist, Clouds{density = {true, 1}})
	environment := DEFAULT_ENVIRONMENT
	environment.mode = {true, .Atmosphere}
	environment.sun = {true, sun}
	ecs.add(w, mist, environment)
	return
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
	// Whether the temporal AA's history was valid in each frame that the debug hook ran, and the passes of the last, by name.
	sequence:      [16]bool,
	passes:        map[string]int,
	// The particles that the debug hook saw: the frame had them, and drew them without stepping.
	particles:     bool,
	draw_only:     bool,
	// The frame had particles to step and a valid history of last frame's depth for their collisions.
	collides:      bool,
}

// RECORD_HOOKS record into the View_Record that is their data.
@(private = "file")
RECORD_HOOKS :: Frame_Hooks {
	before_world = proc(f: ^Frame) {
		rec := (^View_Record)(f.data)
		rec.before_world += 1
		rec.position, rec.size, rec.output_size, rec.extra = f.view.position, f.size, f.output_size, f.extra
		rec.collides = f.particles != nil && !f.particles.draw_only && f.particles.history.valid
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
		rec.sequence[rec.debug % len(rec.sequence)] = f.post.history.valid
		rec.debug += 1
		rec.layer, rec.lines, rec.history_valid = f.debug != 0, f.tested_lines + f.overlay_lines, f.post.history.valid
		rec.particles, rec.draw_only = f.particles != nil, f.particles != nil && f.particles.draw_only
		if rec.passes == nil {
			rec.passes = make(map[string]int, f.renderer.platform.frame_allocator)
		}
		clear(&rec.passes)
		for pass in f.graph.passes {
			rec.passes[pass.name] += 1
		}
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

// second_renderer makes another renderer on the rig's platform and world, with every pipeline, for a reference.
@(private = "file")
second_renderer :: proc(rig: ^Rig) -> ^Renderer {
	r := new(Renderer)
	renderer_init(r, &rig.platform, &rig.assets, rig.w)
	enable_frame_pipelines(r)
	r.transparency_composite.pipeline = rig.platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test composite"})
	return r
}

@(private = "file")
destroy_second_renderer :: proc(rig: ^Rig, r: ^Renderer) {
	rig.platform.gpu_destroy_texture(r.blue_noise.texture)
	renderer_destroy(r)
	free(r)
}

// View_Snapshot is what a view keeps between frames, without the handles of its resources: its frames, its last frame's
// camera, the histories' use, its post-processing's jitter, exposure and upscaler, its occlusion culling's pyramid, the
// counters of the features that keep a history, its sky's cached ambient light, and the cursors and levels of its global
// illumination, with the use of its stats' rings.
@(private = "file")
View_Snapshot :: struct {
	frames:         u64,
	previous:       Previous_Camera,
	histories:      [MAX_HISTORY_TEXTURES][5]u64,
	jitter_index:   u32,
	last_time:      f64,
	adapted:        bool,
	upscaler:       [3]u32,
	hzb_size:       [2]u32,
	hzb_levels:     int,
	ao_frame:       u32,
	fog_frame:      u32,
	ssr:            Ssr_State,
	clouds_frame:   u32,
	shadow_size:    u32,
	sky:            Sky_State,
	gi_frame:       u32,
	probe_frame:    u32,
	probe_levels:   [MAX_PROBE_LEVELS]Gi_Probe_Level,
	probe_schedule: Probe_Schedule,
	split_params:   Gi_Split_Params,
	split_windows:  [MAX_SPLIT_LEVELS]Split_Window,
	split_lifetime: [MAX_SPLIT_CASCADES]u32,
	split_frame:    u32,
	voxel_params:   Gi_Voxel_Params,
	voxel_boxes:    [VOXEL_MAX_LEVELS]Voxel_Box,
	voxel_frame:    u32,
	voxel_turn:     u32,
	virtual_pages:  [2]u32,
	rings:          [4]int,
}

@(private = "file")
view_snapshot :: proc(v: ^View_State) -> (s: View_Snapshot) {
	s = {
		frames         = v.frames,
		previous       = v.previous,
		jitter_index   = v.post.jitter_index,
		last_time      = v.post.last_time,
		adapted        = v.post.adapted,
		upscaler       = {u32(v.post.upscaler.active), v.post.upscaler.render_size.x, v.post.upscaler.render_size.y},
		hzb_size       = v.occlusion.hzb_size,
		hzb_levels     = v.occlusion.hzb_levels,
		ao_frame       = v.ao_frame,
		fog_frame      = v.fog_frame,
		ssr            = v.ssr,
		clouds_frame   = v.clouds.frame,
		shadow_size    = v.clouds.shadow_size,
		sky            = v.sky,
		gi_frame       = v.gi.frame,
		probe_frame    = v.gi.probes.frame,
		probe_levels   = v.gi.probes.levels,
		probe_schedule = v.gi.probes.schedule,
		split_params   = v.gi.split.params,
		split_windows  = v.gi.split.windows,
		split_lifetime = v.gi.split.lifetimes,
		split_frame    = v.gi.split.frame,
		voxel_params   = v.gi.voxel.params,
		voxel_boxes    = v.gi.voxel.boxes,
		voxel_frame    = v.gi.voxel.frame,
		voxel_turn     = v.gi.voxel.turn,
		virtual_pages  = v.virtual_shadows.pool_pages,
		rings          = {v.occlusion.stats_ring.next, v.gi.split.stats_ring.next, v.virtual_shadows.stats_ring.next, v.shading.stats_ring.next},
	}
	for h, i in v.histories.entries {
		s.histories[i] = {h.label_hash, h.written, h.last_used, u64(h.current), u64(h.textures[0] != {})}
	}
	return
}

// gpu_objects counts the textures and buffers that a view's state holds.
@(private = "file")
gpu_objects :: proc(v: ^View_State) -> (textures, buffers: int) {
	texture :: proc(handles: []gpu.Texture) -> (n: int) {
		for h in handles {
			n += int(h != {})
		}
		return
	}
	buffer :: proc(handles: []gpu.Buffer) -> (n: int) {
		for h in handles {
			n += int(h != {})
		}
		return
	}
	for &h in v.histories.entries {
		textures += texture(h.textures[:])
	}
	textures += texture(v.occlusion.hzb[:])
	textures += texture({v.clouds.shadow_map, v.gi.probes.radiance, v.gi.probes.irradiance, v.gi.split.atlas, v.virtual_shadows.pool, v.atlas_cache.texture})
	for level in v.gi.voxel.textures {
		for kind in Voxel_Texture {
			textures += texture({level[kind]})
		}
	}
	buffers += buffer({v.post.exposure, v.occlusion.cell_seen, v.occlusion.stats, v.gi.probes.states, v.virtual_shadows.stats, v.shading.stats})
	buffers += buffer({v.virtual_shadows.table, v.virtual_shadows.pages})
	buffers += buffer(v.occlusion.slot_seen[:])
	buffers += buffer({v.gi.split.slots, v.gi.split.deposits, v.gi.split.index, v.gi.split.lists, v.gi.split.counters})
	buffers += buffer({v.gi.split.arguments, v.gi.split.accum, v.gi.split.history, v.gi.split.merged})
	for ring in ([]^Readback_Ring{&v.occlusion.stats_ring, &v.gi.split.stats_ring, &v.virtual_shadows.stats_ring, &v.shading.stats_ring}) {
		buffers += buffer(ring.copies[:])
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
	states: [MAX_EXTRA_VIEWS + 1]View_State
	for &state in states {
		view_state_init(&state, r)
	}
	defer {
		for &state in states {
			view_state_destroy(&state, r)
		}
	}
	platform.gpu_submit = logging_submit
	defer platform.gpu_submit = null.submit
	defer {
		delete(draw_log.drawn)
		draw_log = {}
	}

	// One view more than draw. The fourth draws into the third's target again, after it.
	records: [MAX_EXTRA_VIEWS + 1]View_Record
	views: [MAX_EXTRA_VIEWS + 1]Extra_View
	targets := [MAX_EXTRA_VIEWS + 1]gpu.Texture{first, second, third, third, first}
	for &v, i in views {
		v = {
			view   = {position = ecs.position_offset({}, {f32(i + 1), 0, 0}), rotation = 1, projection = Perspective{1, 0.05}},
			size   = {32, 16},
			target = targets[i],
			state  = &states[i],
			hooks  = RECORD_HOOKS,
		}
		v.hooks.data = &records[i]
	}
	desc := Frame_Desc {
		view        = {rotation = 1, projection = Perspective{1, 0.05}},
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
	testing.expect_value(t, third_draws, 2)
	testing.expect(t, main_first < first_first && first_first < second_first && second_first < third_first, "the views did not draw in order")
	for i in 0 ..< MAX_EXTRA_VIEWS {
		testing.expect_value(t, records[i].before_world, 1)
	}
	// The last view is past the limit, and the frame says so.
	testing.expect_value(t, records[MAX_EXTRA_VIEWS].before_world, 0)
	testing.expect_value(t, len(rig.record.problems), 1)
	testing.expect(t, len(rig.record.problems) == 1 && strings.contains(rig.record.problems[0], "extra views"))
	forget_problems(rig)

	// A view with no target or no size draws nothing and runs no hook, and keeps no frame.
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
	testing.expect_value(t, states[0].frames, 1)
	testing.expect_value(t, states[2].frames, 2)

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

// With two views drawn every frame, each keeps what it would if it were the only one: the view state of the frame's own
// view equals a renderer's that draws it alone, and the state of an extra view equals that of a renderer that draws it as
// its own view. Every feature runs, at the default quality, and the null backend checks every barrier and wait.
@(test)
two_views_keep_the_state_that_each_would_alone :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	platform := &rig.platform
	both, only_a, only_b := rig.r, second_renderer(rig), second_renderer(rig)
	defer {
		destroy_second_renderer(rig, only_a)
		destroy_second_renderer(rig, only_b)
	}
	fill_world(rig.w)
	enable_frame_pipelines(both)
	defer platform.gpu_destroy_texture(both.blue_noise.texture)
	state_b: View_State
	view_state_init(&state_b, both)
	defer view_state_destroy(&state_b, both)
	target := extra_target(platform, {48, 24})
	defer platform.gpu_destroy_texture(target)

	// Records: A in the renderer with both, B in it, A alone, B alone.
	records: [4]View_Record
	for k in 0 ..< 10 {
		a := View{position = ecs.position_offset({}, {f32(k) * 2, 1, -4}), rotation = 1, projection = Perspective{1, 0.05}}
		// High above the others, where the sky's ambient light is not A's.
		b := View{position = ecs.position_offset({}, {-300 + f32(k), 3000, 10}), rotation = 1, projection = Perspective{1, 0.05}}
		desc_a := Frame_Desc {
			view  = a,
			size  = {64, 32},
			hooks = RECORD_HOOKS,
		}
		desc_b := Frame_Desc {
			view  = b,
			size  = {48, 24},
			hooks = RECORD_HOOKS,
		}
		extras := [1]Extra_View{{view = b, size = {48, 24}, target = target, state = &state_b, hooks = RECORD_HOOKS}}
		extras[0].hooks.data = &records[1]
		together := desc_a
		together.hooks.data, together.extra_views = &records[0], extras[:]
		testing.expect(t, draw_frame(both, rig.w, together), "the frame with two views did not execute")
		desc_a.hooks.data = &records[2]
		testing.expect(t, draw_frame(only_a, rig.w, desc_a), "the frame of the first view alone did not execute")
		desc_b.hooks.data = &records[3]
		testing.expect(t, draw_frame(only_b, rig.w, desc_b), "the frame of the second view alone did not execute")

		got_a, want_a := view_snapshot(&both.view), view_snapshot(&only_a.view)
		testing.expectf(t, got_a == want_a, "frame %d: the first view's state differs from the view alone: %v != %v", k, got_a, want_a)
		got_b, want_b := view_snapshot(&state_b), view_snapshot(&only_b.view)
		testing.expectf(t, got_b == want_b, "frame %d: the second view's state differs from the view alone: %v != %v", k, got_b, want_b)
		testing.expect_value(t, got_b.sky.ambient_valid, true)
		testing.expect(t, got_a.sky.ambient_key != got_b.sky.ambient_key, "the views' skies are at one height")
	}
	// Each view read the histories that its own frame before wrote, as it does alone.
	testing.expect_value(t, records[0].sequence, records[2].sequence)
	testing.expect_value(t, records[1].sequence, records[3].sequence)
	testing.expect(t, !records[1].sequence[0] && records[1].sequence[1] && records[1].sequence[9], "the second view had no history")
	testing.expect(t, records[1].extra && !records[0].extra && !records[3].extra)
	// Both views have adapted their own exposure and keep it apart.
	testing.expect(t, both.view.post.adapted && state_b.post.adapted)
	testing.expect(t, both.view.post.exposure != state_b.post.exposure)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// Views keep histories of their own, at their own sizes: both are valid from the second frame on, a view that is not drawn
// in a frame has none in the next, and a view whose frame did not execute leaves the others as they are. view_state_destroy
// frees a view's GPU objects, histories first, at once, and a zero view state is safe to destroy.
@(test)
views_keep_histories_of_their_own :: proc(t: ^testing.T) {
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
	state_b: View_State
	view_state_init(&state_b, r)
	target := extra_target(platform, {48, 24})
	defer platform.gpu_destroy_texture(target)
	platform.gpu_submit = logging_submit
	defer platform.gpu_submit = null.submit
	defer {
		delete(draw_log.drawn)
		draw_log = {}
	}

	record_a, record_b: View_Record
	extras := [1]Extra_View{{view = {position = ecs.position_offset({}, {20, 0, 0}), rotation = 1, projection = Perspective{1, 0.05}}, size = {48, 24}, target = target, state = &state_b, hooks = RECORD_HOOKS}}
	extras[0].hooks.data = &record_b
	desc := Frame_Desc {
		view  = {rotation = 1, projection = Perspective{1, 0.05}},
		size  = {64, 32},
		hooks = RECORD_HOOKS,
	}
	desc.hooks.data = &record_a
	// Which views draw in each frame, and whether the frame's own view fails.
	Step :: struct {
		own_fails, extra_draws: bool,
		valid_a, valid_b:       bool,
	}
	steps := [?]Step {
		{false, true, false, false},
		{false, true, true, true},
		// The extra view is not drawn, and its history is not valid in the next frame, once.
		{false, false, true, false},
		{false, true, true, false},
		{false, true, true, true},
		// The frame's own view fails: its frame is not written, and the extra view's is.
		{true, true, true, true},
		{false, true, false, true},
		{false, true, true, true},
	}
	for step, i in steps {
		desc.extra_views = step.extra_draws ? extras[:] : nil
		draw_log.fail_next = step.own_fails
		draws := len(draw_log.drawn)
		testing.expectf(t, draw_frame(r, rig.w, desc) == !step.own_fails, "frame %d: executed %v", i, !step.own_fails)
		testing.expectf(t, record_a.history_valid == step.valid_a, "frame %d: the first view's history is valid %v, want %v", i, record_a.history_valid, step.valid_a)
		if step.extra_draws {
			testing.expectf(t, record_b.history_valid == step.valid_b, "frame %d: the second view's history is valid %v, want %v", i, record_b.history_valid, step.valid_b)
			extra_draws, _ := draws_into(target)
			testing.expect(t, extra_draws > 0 && len(draw_log.drawn) > draws)
		}
	}
	// The views' histories are the sizes of their own views.
	sizes: [2][2]u32
	for h in state_b.histories.entries {
		if h.textures[0] != {} && h.desc.size == {48, 24} {
			sizes[1] = h.desc.size
		}
	}
	for h in r.view.histories.entries {
		if h.textures[0] != {} && h.desc.size == {64, 32} {
			sizes[0] = h.desc.size
		}
	}
	testing.expect_value(t, sizes, [2][2]u32{{64, 32}, {48, 24}})

	// Destroying the view state frees what it holds, at once, and nothing else.
	textures, buffers := gpu_objects(&state_b)
	testing.expect(t, textures > 0 && buffers > 0)
	before := null.stats()
	view_state_destroy(&state_b, r)
	after := null.stats()
	testing.expect_value(t, int(before.textures - after.textures), textures)
	testing.expect_value(t, int(before.buffers - after.buffers), buffers)
	testing.expect_value(t, state_b, View_State{})
	view_state_destroy(&state_b, r)
	zero: View_State
	view_state_destroy(&zero, r)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// An extra view draws the passes that the frame's own view does at the same quality: once the world's work is done, the
// two graphs have the same passes, by name and count.
@(test)
an_extra_view_draws_the_passes_of_the_frames_own_view :: proc(t: ^testing.T) {
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
	state_b: View_State
	view_state_init(&state_b, r)
	defer view_state_destroy(&state_b, r)
	target := extra_target(platform, {64, 32})
	defer platform.gpu_destroy_texture(target)

	record_a, record_b: View_Record
	view := View{position = ecs.position_offset({}, {0, 1, -4}), rotation = 1, projection = Perspective{1, 0.05}}
	extras := [1]Extra_View{{view = view, size = {64, 32}, target = target, state = &state_b, hooks = RECORD_HOOKS}}
	extras[0].hooks.data = &record_b
	desc := Frame_Desc {
		view        = view,
		size        = {64, 32},
		hooks       = RECORD_HOOKS,
		extra_views = extras[:],
	}
	desc.hooks.data = &record_a
	// The frames that do the world's work once: the lookup table's bake, the sky's cubemap, the noise, the probes' captures.
	for _ in 0 ..< 24 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	same := true
	for name, count in record_a.passes {
		if record_b.passes[name] != count {
			same = false
			testing.expectf(t, false, "%q: %d passes in the frame's own view, %d in the extra view", name, count, record_b.passes[name])
		}
	}
	for name, count in record_b.passes {
		if name not_in record_a.passes {
			same = false
			testing.expectf(t, false, "%q: no pass in the frame's own view, %d in the extra view", name, count)
		}
	}
	testing.expect(t, same)
	testing.expectf(t, record_a.passes["gi trace"] > 0 && record_a.passes["exposure"] > 0 && record_a.passes["temporal aa"] > 0, "the frame lacks passes: %v", record_a.passes)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// An orthographic view draws beside a perspective one, with the passes that do not take a perspective: no sky and no
// clouds behind the world, and no screen-space reflections (see docs/rendering/frame.md#orthographic-views).
@(test)
an_orthographic_view_draws_the_passes_that_do_not_take_a_perspective :: proc(t: ^testing.T) {
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
	state_b: View_State
	view_state_init(&state_b, r)
	defer view_state_destroy(&state_b, r)
	target := extra_target(platform, {64, 32})
	defer platform.gpu_destroy_texture(target)

	record_a, record_b: View_Record
	at := ecs.position_offset({}, {0, 1, -4})
	extras := [1]Extra_View{{view = {position = at, rotation = 1, projection = Orthographic{10, 0.1, 100}}, size = {64, 32}, target = target, state = &state_b, hooks = RECORD_HOOKS}}
	extras[0].hooks.data = &record_b
	desc := Frame_Desc {
		view        = {position = at, rotation = 1, projection = Perspective{1, 0.05}},
		size        = {64, 32},
		hooks       = RECORD_HOOKS,
		extra_views = extras[:],
	}
	desc.hooks.data = &record_a
	for _ in 0 ..< 24 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	// What only the perspective view draws.
	only := make(map[string]bool, context.temp_allocator)
	for name in record_a.passes {
		if name not_in record_b.passes {
			only[name] = true
		}
	}
	for name in record_b.passes {
		testing.expectf(t, name in record_a.passes, "%q draws only in the orthographic view", name)
	}
	testing.expectf(t, only["sky"] && only["sky aerial"] && only["clouds march"] && only["reflections trace"], "the orthographic view draws the sky, its air, the clouds or the screen-space reflections: only the perspective view has %v", only)
	for name in ([]string{"world", "cluster lights", "fog inject", "fog integrate", "exposure", "temporal aa", "shadow mask", "gtao", "gi trace"}) {
		testing.expectf(t, record_b.passes[name] > 0, "the orthographic view has no %q pass: %v", name, record_b.passes)
	}
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)

	// The orthographic view is the frame's own as well, with a perspective one beside it.
	desc.view, extras[0].view = extras[0].view, desc.view
	for _ in 0 ..< 4 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	testing.expectf(t, "sky" not_in record_a.passes && record_b.passes["sky"] > 0, "the views did not swap their passes: %v, %v", record_a.passes, record_b.passes)
	testing.expectf(t, "sky aerial" not_in record_a.passes && record_b.passes["sky aerial"] == 1, "the views did not swap their air: %v, %v", record_a.passes, record_b.passes)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// The aerial perspective volume is an atmosphere's alone: a perspective view in Atmosphere makes it once, and the world
// pass reads it, so it stays live; Flat and Texture skies have none (see docs/rendering/sky.md#aerial-perspective).
@(test)
the_aerial_volume_is_an_atmospheres_alone :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	_, mist := fill_world(rig.w)
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)

	Air_Record :: struct {
		passes: int,
		aerial: bool,
		reads:  bool,
	}
	record: Air_Record
	desc := Frame_Desc {
		view  = {position = ecs.position_offset({}, {0, 1, -4}), rotation = 1, projection = Perspective{1, 0.05}},
		size  = {64, 32},
		hooks = {
			data = &record,
			debug = proc(f: ^Frame) {
				rec := (^Air_Record)(f.data)
				rec^ = {aerial = f.aerial != 0}
				for pass in f.graph.passes {
					if pass.name == "sky aerial" {
						rec.passes += 1
					}
				}
				// The world pass declares the read, so the graph keeps the pass that writes it.
				for pass in f.graph.passes {
					if pass.name != "world" {
						continue
					}
					for use in pass.uses {
						rec.reads ||= f.aerial != 0 && !use.buffer && use.reads && Texture(use.index + 1) == f.aerial
					}
				}
			},
		},
	}
	for mode in Sky_Mode {
		ecs.get(rig.w, mist, Environment).mode = {true, mode}
		for _ in 0 ..< 2 {
			testing.expect(t, draw_frame(r, rig.w, desc))
		}
		atmosphere := mode == .Atmosphere
		testing.expectf(t, record.passes == (atmosphere ? 1 : 0), "%v: %d aerial passes", mode, record.passes)
		testing.expectf(t, record.aerial == atmosphere && record.reads == atmosphere, "%v: the volume %v, read by the world %v", mode, record.aerial, record.reads)
	}
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// The sun's contact shadows are the untraced frames': a frame whose shadow mask has the sun marches no contact shadows,
// one that does not trace does, and the world pass reads them; without the ambient occlusion's depth levels, they wait.
@(test)
the_sun_takes_contact_shadows_where_it_does_not_trace :: proc(t: ^testing.T) {
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

	Contact_Record :: struct {
		contact: int,
		mask:    int,
		reads:   bool,
		flagged: bool,
	}
	record: Contact_Record
	desc := Frame_Desc {
		view  = {position = ecs.position_offset({}, {0, 1, -4}), rotation = 1, projection = Perspective{1, 0.05}},
		size  = {64, 32},
		hooks = {
			data = &record,
			debug = proc(f: ^Frame) {
				rec := (^Contact_Record)(f.data)
				contact := f.shadows.contact
				rec^ = {}
				for pass in f.graph.passes {
					switch pass.name {
					case "contact shadows":
						rec.contact += 1
					case "shadow mask":
						rec.mask += 1
					case "world":
						for use in pass.uses {
							rec.reads ||= contact != 0 && !use.buffer && use.reads && Texture(use.index + 1) == contact
						}
					}
				}
				for light in f.lights.records {
					rec.flagged ||= .Contact_Shadow in light.flags
				}
			},
		},
	}
	draw :: proc(t: ^testing.T, r: ^Renderer, w: ^ecs.World, desc: Frame_Desc) {
		for _ in 0 ..< 2 {
			testing.expect(t, draw_frame(r, w, desc))
		}
	}

	// The default quality traces the sun's shadow.
	draw(t, r, rig.w, desc)
	testing.expectf(t, record.mask == 1 && record.contact == 0 && !record.flagged, "traced: %v", record)

	// Without tracing in the quality, at every level, the sun takes the contact shadows, which the world reads.
	for level in Quality_Level {
		q := preset_quality(Quality_Preset(level), r.caps)
		q.shadows.ray_traced = false
		desc.quality = &q
		draw(t, r, rig.w, desc)
		testing.expectf(t, record.mask == 0 && record.contact == 1 && record.reads && record.flagged, "%v, untraced: %v", level, record)
	}

	// So does a device without Ray_Query, at the default quality.
	desc.quality = nil
	r.caps.ray_query = false
	draw(t, r, rig.w, desc)
	testing.expectf(t, record.mask == 0 && record.contact == 1 && record.reads, "without Ray_Query: %v", record)

	// Without the ambient occlusion there are no depth levels to march, so there is no pass, and the world reads white.
	q := r.quality
	q.ao.technique = .Off
	desc.quality = &q
	draw(t, r, rig.w, desc)
	testing.expectf(t, record.mask == 0 && record.contact == 0 && !record.reads, "without the ambient occlusion: %v", record)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// The systems step once a frame, in the frame's own view, whatever the count of views, and every view draws their sprites
// from the pool that it stepped, relative to its own camera, without stepping it again.
@(test)
particles_step_once_a_frame_and_every_view_draws_them :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	// A world with fog, whose constants the sprites need.
	fill_world(rig.w)
	// An effect of one emitter, in the cache, and a system that plays it.
	guid := format.Guid{0 = 0x42, 15 = 0xaa}
	smoke: [format.Effect_Curve]format.Effect_Curve_Row
	smoke[.Size][63] = {0.5, 0, 0, 0}
	emitters := []format.Effect_Emitter_Contents{{emitter = {capacity = 100, rate = 60, lifetime = {1, 2}, shape = .Sphere, shape_size = {0.1, 0, 0}}, name = "smoke", curves = smoke}}
	blob := format.effect_write({guid = guid, key = 1, emitters = emitters, source_path = "game/effects/smoke.effect"}, context.temp_allocator)
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", rig.dir, format.guid_format(guid, &buffer)), blob) == nil)
	system := ecs.spawn(rig.w)
	ecs.add(rig.w, system, ecs.Transform{position = ecs.position_offset({}, {0, 0, 5}), rotation = 1, scale = 1})
	ecs.add(rig.w, system, Particle_System{effect = guid})
	reference := second_renderer(rig)
	defer destroy_second_renderer(rig, reference)
	for renderer in ([]^Renderer{r, reference}) {
		for p in ([]^Shader_Pipeline{&renderer.particles.update, &renderer.particles.history, &renderer.particles.ribbon, &renderer.particles.meshes}) {
			p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test particles"})
		}
		fake_sprite_pipelines(renderer)
	}
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test composite"})
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	state_b: View_State
	view_state_init(&state_b, r)
	defer view_state_destroy(&state_b, r)
	target := extra_target(platform, {48, 24})
	defer platform.gpu_destroy_texture(target)

	record_a, record_b, record_reference: View_Record
	view_a := View{rotation = 1, projection = Perspective{1, 0.05}}
	view_b := View{position = ecs.position_offset({}, {4, 1, 0}), rotation = 1, projection = Perspective{1, 0.05}}
	extras := [1]Extra_View{{view = view_b, size = {48, 24}, target = target, state = &state_b, hooks = RECORD_HOOKS}}
	extras[0].hooks.data = &record_b
	desc := Frame_Desc {
		view  = view_a,
		size  = {64, 32},
		delta = 1.0 / 60,
		hooks = RECORD_HOOKS,
	}
	alone := desc
	desc.hooks.data, desc.extra_views = &record_a, extras[:]
	alone.hooks.data = &record_reference
	for _ in 0 ..< 8 {
		testing.expect(t, draw_frame(r, rig.w, desc))
		testing.expect(t, draw_frame(reference, rig.w, alone))
		// The pool, the counters and the system's clock are those of a frame with one view.
		p, q := &r.particles, &reference.particles
		testing.expect_value(t, p.frame, q.frame)
		testing.expect_value(t, p.free_count, q.free_count)
		testing.expect_value(t, p.slots[0], q.slots[0])
		testing.expect_value(t, p.previous_view_projection, q.previous_view_projection)
		testing.expect_value(t, p.has_previous, q.has_previous)
	}
	testing.expect_value(t, r.particles.frame, 8)
	slot := r.particles.slots[0]
	testing.expect(t, slot.used && slot.started, "the system did not start")
	testing.expect(t, slot.age > 0.1, "the system did not age")
	// The frame's own view stepped them, and the other drew them from the same records.
	testing.expect(t, record_a.particles && !record_a.draw_only, "the frame's own view had no particles to step")
	testing.expect(t, record_b.particles && record_b.draw_only, "the extra view did not draw the particles")
	testing.expect(t, record_a.passes["particle counters"] == 1 && record_b.passes["particle counters"] == 0)
	testing.expect(t, record_a.passes["particle update"] == 1 && record_b.passes["particle update"] == 1)
	testing.expect(t, record_a.passes["particle history"] == 1 && record_b.passes["particle history"] == 0)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// With more probes than slots and two cameras far apart, the probes rank by the nearest of the views: each camera keeps
// its nearest probes, and no frame moves a probe from one slot to another.
@(test)
no_view_evicts_the_probes_of_another :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	w := rig.w
	slots := int(REFLECTION_PARAMS[.Probes][.Low].probes)
	// Twice the slots of probes, in two groups, a group around each camera.
	groups: [2][dynamic]ecs.Entity
	defer for g in groups {
		delete(g)
	}
	for group in 0 ..< 2 {
		for k in 0 ..< slots {
			probe := ecs.spawn(w)
			at := f32(group) * 1000 + f32(k) + 1
			ecs.add(w, probe, ecs.Transform{position = ecs.position_offset({}, {at, 0, 0}), rotation = 1, scale = 1})
			ecs.add(w, probe, Reflection_Probe{})
			append(&groups[group], probe)
		}
	}
	state_b: View_State
	view_state_init(&state_b, r)
	defer view_state_destroy(&state_b, r)
	target := extra_target(platform, {32, 16})
	defer platform.gpu_destroy_texture(target)
	quality := r.quality
	quality.reflections = {.Probes, .Low}
	extras := [1]Extra_View{{view = {position = ecs.position_offset({}, {1000, 0, 0}), rotation = 1, projection = Perspective{1, 0.05}}, size = {32, 16}, target = target, state = &state_b}}
	desc := Frame_Desc {
		view        = {rotation = 1, projection = Perspective{1, 0.05}},
		size        = {64, 32},
		quality     = &quality,
		extra_views = extras[:],
	}
	held :: proc(rp: ^Reflection_Probes, slots: int, group: []ecs.Entity) -> (count: int) {
		for s in rp.slots[:slots] {
			for e in group {
				count += int(s.used && s.entity == e)
			}
		}
		return
	}
	rp := &r.reflection_probes
	var_slots: [16]ecs.Entity
	for k in 0 ..< 6 {
		testing.expect(t, draw_frame(r, w, desc))
		now: [16]ecs.Entity
		for s, i in rp.slots[:slots] {
			now[i] = s.used ? s.entity : 0
		}
		// The slots are the nearest to the two cameras, half each, and stay where they are.
		testing.expect_value(t, held(rp, slots, groups[0][:]) + held(rp, slots, groups[1][:]), slots)
		testing.expect_value(t, held(rp, slots, groups[0][:]), slots / 2)
		testing.expect_value(t, held(rp, slots, groups[1][:]), slots / 2)
		if k > 0 {
			testing.expect_value(t, now, var_slots)
		}
		var_slots = now
	}
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// Each view has the level of its own quality, and the storage of its own: one with the voxel cones and one with the screen
// cascades keep apart, and a view that changes its level makes its storage again without touching the other's.
@(test)
views_with_other_gi_techniques_keep_separate_storage :: proc(t: ^testing.T) {
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
	state_b: View_State
	view_state_init(&state_b, r)
	defer view_state_destroy(&state_b, r)
	target := extra_target(platform, {48, 24})
	defer platform.gpu_destroy_texture(target)

	quality_a, quality_b := r.quality, r.quality
	quality_a.gi = {.Voxel_Cones, .Low}
	quality_b.gi = {.Screen_Cascades, .Low}
	extras := [1]Extra_View{{view = {position = ecs.position_offset({}, {20, 0, 0}), rotation = 1, projection = Perspective{1, 0.05}}, size = {48, 24}, target = target, state = &state_b, quality = &quality_b}}
	desc := Frame_Desc {
		view        = {rotation = 1, projection = Perspective{1, 0.05}},
		size        = {64, 32},
		quality     = &quality_a,
		extra_views = extras[:],
	}
	for _ in 0 ..< 3 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	a, b := &r.view.gi, &state_b.gi
	testing.expect_value(t, a.voxel.params, GI_VOXEL_PARAMS[.Low])
	testing.expect(t, a.voxel.textures[0][.Radiance] != {}, "the first view has no voxels")
	testing.expect_value(t, b.voxel.params, Gi_Voxel_Params{})
	testing.expect(t, b.voxel.textures[0][.Radiance] == {}, "the screen cascades made voxels")
	testing.expect_value(t, a.split.params, Gi_Split_Params{})
	testing.expect(t, a.frame > 0 && b.frame > 0)
	voxels := a.voxel.textures
	boxes := a.voxel.boxes

	// The second view takes the voxel cones at another level: it makes its voxels, and the first view's are as they were.
	quality_b.gi = {.Voxel_Cones, .High}
	for _ in 0 ..< 2 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	testing.expect_value(t, b.voxel.params, GI_VOXEL_PARAMS[.High])
	testing.expect_value(t, a.voxel.params, GI_VOXEL_PARAMS[.Low])
	testing.expect_value(t, a.voxel.textures, voxels)
	testing.expect(t, a.voxel.boxes[0].voxelized && boxes[0].voxelized)
	testing.expect(t, b.voxel.textures[0][.Radiance] != a.voxel.textures[0][.Radiance])

	// And the first view changes its level: the second's storage stays.
	voxels_b := b.voxel.textures
	quality_a.gi = {.Voxel_Cones, .Medium}
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, a.voxel.params, GI_VOXEL_PARAMS[.Medium])
	testing.expect_value(t, b.voxel.textures, voxels_b)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// An extra view's hooks run at the same points as the frame's, with a frame of its own: its view, its size and its output
// size, at its quality's render scale, and the settings of the volumes at its place. The settings that the view is given
// are its own, not the frame's. Frame.extra says which it is.
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
	state_b: View_State
	view_state_init(&state_b, r)
	defer view_state_destroy(&state_b, r)

	main_record, extra_record: View_Record
	extra_at := ecs.position_offset({}, {100, 0, 0})
	quality := r.quality
	quality.render_scale = 0.5
	extras := [1]Extra_View{{view = {position = extra_at, rotation = 1, projection = Perspective{1, 0.05}}, size = {32, 16}, target = target, state = &state_b, hooks = RECORD_HOOKS}}
	extras[0].hooks.data = &extra_record
	desc := Frame_Desc {
		view        = {position = ecs.position_offset({}, {1, 2, 3}), rotation = 1, projection = Perspective{1, 0.05}},
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
	// The frame's quality is the extra view's, with its render scale.
	testing.expect_value(t, extra_record.size, [2]u32{16, 8})
	testing.expect_value(t, extra_record.output_size, [2]u32{32, 16})
	// The volumes at each view's place give its settings.
	testing.expect(t, !main_record.no_bloom && extra_record.no_bloom, "the settings are not the volumes' at each view")

	// The view's own quality and settings are its own.
	own_quality := r.quality
	settings := resolve_settings(r, w, desc.view.position)
	desc.extra_views[0].quality, desc.extra_views[0].settings = &own_quality, &settings
	testing.expect(t, draw_frame(r, w, desc), "the frame with the view's own quality did not execute")
	testing.expect_value(t, extra_record.size, [2]u32{32, 16})
	testing.expect(t, !main_record.no_bloom && !extra_record.no_bloom, "the extra view did not take its own settings")
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
	states: [2]View_State
	for &state in states {
		view_state_init(&state, r)
	}
	defer {
		for &state in states {
			view_state_destroy(&state, r)
		}
	}

	records: [3]View_Record
	extra_at := ecs.position_offset({}, {10, 0, 0})
	extras := [2]Extra_View {
		{view = {position = extra_at, rotation = 1, projection = Perspective{1, 0.05}}, size = {32, 16}, target = first, state = &states[0], hooks = RECORD_HOOKS},
		// This one has no debug layer, and its hook still runs.
		{view = {rotation = 1, projection = Perspective{1, 0.05}}, size = {32, 16}, target = second, state = &states[1], no_debug = true, hooks = RECORD_HOOKS},
	}
	extras[0].hooks.data = &records[1]
	extras[1].hooks.data = &records[2]
	desc := Frame_Desc {
		view        = {position = ecs.position_offset({}, {1, 0, 0}), rotation = 1, projection = Perspective{1, 0.05}},
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

// The frame's own view can draw into a target of its own, with a state of its own: it draws there and not into the frame
// target, in the frame's place in the order, with that state's histories. The stats getters follow the state, and do not
// dangle when it is freed.
@(test)
the_frames_own_view_draws_into_a_target_with_a_state_of_its_own :: proc(t: ^testing.T) {
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
	state: View_State
	view_state_init(&state, r)
	target := extra_target(platform, {48, 24})
	defer platform.gpu_destroy_texture(target)
	main_target := platform.gpu_frame_target()
	platform.gpu_submit = logging_submit
	defer platform.gpu_submit = null.submit
	defer {
		delete(draw_log.drawn)
		draw_log = {}
	}

	record: View_Record
	desc := Frame_Desc {
		view   = {rotation = 1, projection = Perspective{1, 0.05}},
		size   = {48, 24},
		target = target,
		state  = &state,
		hooks  = RECORD_HOOKS,
	}
	desc.hooks.data = &record
	for k in 0 ..< 3 {
		testing.expectf(t, draw_frame(r, rig.w, desc), "frame %d did not execute", k)
		testing.expectf(t, record.history_valid == (k > 0), "frame %d: the history is valid %v", k, record.history_valid)
	}
	into_target, _ := draws_into(target)
	into_frame, _ := draws_into(main_target)
	testing.expect(t, into_target > 0, "the frame's own view did not draw into its target")
	testing.expect_value(t, into_frame, 0)
	testing.expect_value(t, state.frames, 3)
	testing.expect_value(t, r.view.frames, 0)
	testing.expect(t, !record.extra, "the frame's own view is not an extra view")
	testing.expect_value(t, record.output_size, [2]u32{48, 24})

	// The stats are those of the state that drew the frame's own view.
	state.occlusion.last_stats.early_items = 7
	r.view.occlusion.last_stats.early_items = 3
	testing.expect_value(t, cull_stats(r).early_items, 7)
	// And a state that is freed leaves the renderer's own.
	view_state_destroy(&state, r)
	testing.expect_value(t, cull_stats(r).early_items, 3)

	// Without a target and a state, the frame draws as it did: into the frame target, with the renderer's state.
	desc.target, desc.state = {}, nil
	desc.size = {64, 32}
	clear(&draw_log.drawn)
	testing.expect(t, draw_frame(r, rig.w, desc))
	into_frame, _ = draws_into(main_target)
	testing.expect(t, into_frame > 0)
	testing.expect_value(t, r.view.frames, 1)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// The frame's own view can move from one state to another between frames, as the editor's does when its viewports open and
// close: a view keeps its histories while it draws every frame, whether as the frame's own view or as an extra one, and one
// that is not drawn has none in its next frame.
@(test)
the_own_views_role_moves_between_states_without_losing_histories :: proc(t: ^testing.T) {
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
	states: [2]View_State
	targets: [2]gpu.Texture
	for &s, i in states {
		view_state_init(&s, r)
		targets[i] = extra_target(platform, {48, 24})
	}
	defer {
		for &s, i in states {
			view_state_destroy(&s, r)
			platform.gpu_destroy_texture(targets[i])
		}
	}
	records: [2]View_Record
	views: [2]Extra_View
	for &v, i in views {
		v = {
			view   = {position = ecs.position_offset({}, {f32(i) * 30, 1, -4}), rotation = 1, projection = Perspective{1, 0.05}},
			size   = {48, 24},
			target = targets[i],
			state  = &states[i],
			hooks  = RECORD_HOOKS,
		}
		v.hooks.data = &records[i]
	}

	// Which view is the frame's own in each frame, which views draw, and whether each view's history is valid in it.
	Step :: struct {
		own:   int,
		draws: [2]bool,
		valid: [2]bool,
	}
	steps := [?]Step {
		{0, {true, true}, {false, false}},
		{0, {true, true}, {true, true}},
		// The role moves: both views draw every frame, so neither loses its histories.
		{1, {true, true}, {true, true}},
		{0, {true, true}, {true, true}},
		// Only the second view draws, as the frame's own, and the first has no history in its next frame.
		{1, {false, true}, {false, true}},
		{1, {true, true}, {false, true}},
		{0, {true, true}, {true, true}},
	}
	for step, k in steps {
		desc: Frame_Desc
		extras: [1]Extra_View
		count := 0
		use_view(&desc, views[step.own])
		if !step.draws[step.own] {
			// The own view's target and state are the renderer's.
			desc.target, desc.state = {}, nil
			desc.size = {64, 32}
		}
		if other := 1 - step.own; step.draws[other] {
			extras[0] = views[other]
			count = 1
		}
		desc.extra_views = extras[:count]
		testing.expectf(t, draw_frame(r, rig.w, desc), "frame %d did not execute", k)
		for i in 0 ..< 2 {
			if step.draws[i] {
				testing.expectf(t, records[i].history_valid == step.valid[i], "frame %d: view %d's history is valid %v, want %v", k, i, records[i].history_valid, step.valid[i])
				testing.expectf(t, records[i].extra == (i != step.own), "frame %d: view %d is extra %v", k, i, records[i].extra)
			}
		}
	}
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// use_view makes every field of an extra view the frame's own.
@(test)
use_view_takes_every_field_of_an_extra_view :: proc(t: ^testing.T) {
	state: View_State
	quality := Quality {
		render_scale = 0.5,
	}
	settings: Frame_Settings
	hook :: proc(_: ^Frame) {}
	v := Extra_View {
		view            = {rotation = 1, projection = Perspective{2, 0.5}},
		size            = {8, 4},
		target          = {index = 3, generation = 1},
		state           = &state,
		quality         = &quality,
		settings        = &settings,
		keep_ids        = true,
		no_debug        = true,
		debug_view      = .Normals,
		disable         = {.Fog},
		exposure_offset = -1,
		hooks           = {debug = hook},
	}
	desc := Frame_Desc {
		delta = 0.5,
	}
	use_view(&desc, v)
	testing.expect_value(t, desc.view, v.view)
	testing.expect_value(t, desc.size, [2]u32{8, 4})
	testing.expect_value(t, desc.target, gpu.Texture{index = 3, generation = 1})
	testing.expect(t, desc.state == &state && desc.quality == &quality && desc.settings == &settings)
	testing.expect(t, desc.keep_ids && desc.no_debug)
	testing.expect_value(t, desc.debug_view, Debug_View.Normals)
	testing.expect_value(t, desc.disable, Features{.Fog})
	testing.expect_value(t, desc.exposure_offset, -1)
	testing.expect(t, desc.hooks.debug == hook)
	testing.expect_value(t, desc.delta, 0.5)
}

// The particles' collisions use the depth of the frame's own view, kept in its state: when the role moves to a state that
// did not keep it, the particles do not collide in that frame, and collide again from the next, as for a view that missed a
// frame. The renderer's own particle clock goes on.
@(test)
the_particles_collide_again_a_frame_after_the_own_views_role_moves :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	fill_world(rig.w)
	guid := format.Guid{0 = 0x43, 15 = 0xab}
	smoke: [format.Effect_Curve]format.Effect_Curve_Row
	smoke[.Size][63] = {0.5, 0, 0, 0}
	emitters := []format.Effect_Emitter_Contents{{emitter = {capacity = 100, rate = 60, lifetime = {1, 2}, shape = .Sphere, shape_size = {0.1, 0, 0}}, name = "smoke", curves = smoke}}
	blob := format.effect_write({guid = guid, key = 1, emitters = emitters, source_path = "game/effects/smoke.effect"}, context.temp_allocator)
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", rig.dir, format.guid_format(guid, &buffer)), blob) == nil)
	system := ecs.spawn(rig.w)
	ecs.add(rig.w, system, ecs.Transform{position = ecs.position_offset({}, {0, 0, 5}), rotation = 1, scale = 1})
	ecs.add(rig.w, system, Particle_System{effect = guid})
	for p in ([]^Shader_Pipeline{&r.particles.update, &r.particles.history, &r.particles.ribbon, &r.particles.meshes}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test particles"})
	}
	fake_sprite_pipelines(r)
	r.transparency_composite.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test composite"})
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	states: [2]View_State
	targets: [2]gpu.Texture
	for &s, i in states {
		view_state_init(&s, r)
		targets[i] = extra_target(platform, {48, 24})
	}
	defer {
		for &s, i in states {
			view_state_destroy(&s, r)
			platform.gpu_destroy_texture(targets[i])
		}
	}
	records: [2]View_Record
	views: [2]Extra_View
	for &v, i in views {
		v = {
			view   = {position = ecs.position_offset({}, {f32(i) * 4, 1, 0}), rotation = 1, projection = Perspective{1, 0.05}},
			size   = {48, 24},
			target = targets[i],
			state  = &states[i],
			hooks  = RECORD_HOOKS,
		}
		v.hooks.data = &records[i]
	}
	// The view that is the frame's own in each frame, and whether its particles collide in it.
	own := [?]int{0, 0, 1, 1, 0, 0}
	collides := [?]bool{false, true, false, true, false, true}
	for k in 0 ..< len(own) {
		desc := Frame_Desc {
			delta = 1.0 / 60,
		}
		use_view(&desc, views[own[k]])
		extras := [1]Extra_View{views[1 - own[k]]}
		desc.extra_views = extras[:]
		testing.expectf(t, draw_frame(r, rig.w, desc), "frame %d did not execute", k)
		testing.expectf(t, records[own[k]].collides == collides[k], "frame %d: the particles collide %v, want %v", k, records[own[k]].collides, collides[k])
	}
	testing.expect_value(t, r.particles.frame, len(own))
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// What the hooks and the overlay of the tests below saw, in order: 'w' for before_world, 'd' for the debug hook and 'o'
// for the overlay.
@(private = "file")
Hook_Order :: struct {
	order:       [16]u8,
	count:       int,
	layer:       bool,
	// Frame.user as each hook saw it, and the Frame.user that the first hook of the view set.
	user_at_start: rawptr,
	user_seen:   [3]rawptr,
	hidden:      []u32,
}

@(private = "file")
note :: proc(rec: ^Hook_Order, what: u8) {
	rec.order[rec.count % len(rec.order)] = what
	rec.count += 1
}

@(private = "file")
ORDER_HOOKS :: Frame_Hooks {
	before_world = proc(f: ^Frame) {
		rec := (^Hook_Order)(f.data)
		rec.user_at_start = f.user
		rec.hidden = f.hidden
		note(rec, 'w')
		f.user = new_clone(i32(len(rec.order)), f.renderer.platform.frame_allocator)
		rec.user_seen[0] = f.user
	},
	debug = proc(f: ^Frame) {
		rec := (^Hook_Order)(f.data)
		note(rec, 'd')
		rec.layer = f.debug != 0
		rec.user_seen[1] = f.user
	},
}

@(private = "file")
order_overlay :: proc(f: ^Frame, data: rawptr) {
	rec := (^Hook_Order)(data)
	note(rec, 'o')
	rec.layer = f.debug != 0
	rec.user_seen[2] = f.user
}

// The overlay is a second hook with a data pointer of its own: it runs after the debug hook in every view, with the
// debug layer, and without a layer when the frame has no debug layer, as the debug hook does. A frame with only an overlay
// has a layer. Frame.user is nil when each view begins, and holds what the view's hooks set; Frame.hidden is the frame's.
@(test)
the_overlay_runs_after_the_debug_hook_in_every_view_and_frame_user_is_of_one_view :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	state: View_State
	view_state_init(&state, r)
	defer view_state_destroy(&state, r)
	target := extra_target(platform, {48, 24})
	defer platform.gpu_destroy_texture(target)

	own, extra, other: Hook_Order
	hidden := []u32{0b101}
	// The same hooks and the same data for both views, as a game's are, and an overlay of its own data for each.
	extras := [1]Extra_View{{view = {rotation = 1, projection = Perspective{1, 0.05}}, size = {48, 24}, target = target, state = &state, hooks = ORDER_HOOKS, overlay = {&other, order_overlay}}}
	extras[0].hooks.data = &extra
	desc := Frame_Desc {
		view        = {rotation = 1, projection = Perspective{1, 0.05}},
		size        = {64, 32},
		hidden      = hidden,
		hooks       = ORDER_HOOKS,
		overlay     = {&own, order_overlay},
		extra_views = extras[:],
	}
	desc.hooks.data = &own
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, string(own.order[:own.count]), "wdo")
	testing.expect(t, own.layer, "the overlay had no debug layer")
	// The extra view's hooks are its own, and so is its overlay.
	testing.expect_value(t, string(extra.order[:extra.count]), "wd")
	testing.expect_value(t, string(other.order[:other.count]), "o")
	// Frame.user is nil at the start of each view, and each view's hooks see what its first hook set.
	testing.expect(t, own.user_at_start == nil && extra.user_at_start == nil)
	testing.expect(t, own.user_seen[0] != nil && own.user_seen[0] == own.user_seen[1] && own.user_seen[1] == own.user_seen[2])
	testing.expect(t, extra.user_seen[0] != nil && extra.user_seen[0] == extra.user_seen[1] && extra.user_seen[0] != own.user_seen[0])
	// The frame's hidden entities are in every view.
	testing.expect(t, len(own.hidden) == 1 && len(extra.hidden) == 1 && own.hidden[0] == 0b101)

	// With no debug layer, the overlay still runs, with Frame.debug 0.
	desc.no_debug = true
	own, extra, other = {}, {}, {}
	extras[0].no_debug = true
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, string(own.order[:own.count]), "wdo")
	testing.expect(t, !own.layer)

	// A frame with an overlay and no debug hook or lines has the layer.
	desc.no_debug = false
	desc.hooks = {}
	desc.extra_views = nil
	own = {}
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, string(own.order[:own.count]), "o")
	testing.expect(t, own.layer)
	// And one without an overlay has none, as before.
	desc.overlay = {}
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// use_view takes the overlay too.
@(test)
use_view_takes_the_overlay :: proc(t: ^testing.T) {
	data: i32
	v := Extra_View {
		overlay = {&data, order_overlay},
	}
	desc: Frame_Desc
	use_view(&desc, v)
	testing.expect(t, desc.overlay.data == &data && desc.overlay.draw == order_overlay)
}

// What the sprite test's hook saw of a view: its sprites' records in the order that they draw, and its passes.
@(private = "file")
Sprite_Capture :: struct {
	records: [dynamic]Sheet_Sprite_Record,
	passes:  map[string]int,
}

// The sprite renderers draw in one pass, sorted by layer, then by order, then from the farthest, each with its frame of
// its sheet's texture, and write their IDs for the editor only when the frame keeps them.
@(test)
sprite_renderers_draw_sorted_by_layer_order_and_depth :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r, platform := rig.r, &rig.platform
	platform.time_seconds = proc() -> f64 {return 0.1}
	// The atlas streams in, which the other tests of the rig have no need of.
	platform.gpu_stream_texture, platform.gpu_stream_buffer, platform.gpu_transfer_done = null.stream_texture, null.stream_buffer, null.transfer_done
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)
	code := []byte{1}
	r.sheet_sprites.pipeline.pipeline = platform.gpu_create_graphics_pipeline({vertex = code, pixel = code, colors = {{format = SCENE_FORMAT, blend = .Premultiplied}}, depth_format = DEPTH_FORMAT, label = "test"})
	r.sheet_sprites.ids.pipeline = platform.gpu_create_graphics_pipeline({vertex = code, pixel = code, colors = {{format = ID_FORMAT}}, depth_format = DEPTH_FORMAT, label = "test"})

	// A sheet of two frames of 16 by 16 texels in a texture of 32 by 16, at 16 texels to a meter, with a walk of two
	// frames a second.
	atlas := format.Guid{0 = 0x51, 15 = 1}
	sheet := format.Guid{0 = 0x51, 15 = 2}
	write :: proc(t: ^testing.T, rig: ^Rig, guid: format.Guid, blob: []byte) {
		buffer: [32]u8
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", rig.dir, format.guid_format(guid, &buffer)), blob) == nil)
	}
	chain := format.texture_chain_size(.BC7_Unorm_Srgb, {32, 16}, 1)
	write(t, rig, atlas, format.texture_write({guid = atlas, format = .BC7_Unorm_Srgb, usage = .Color, dimension = .D2, layer_count = 1, size = {32, 16}, mip_count = 1, mips = make([]byte, chain, context.temp_allocator)}, context.temp_allocator))
	write(
		t,
		rig,
		sheet,
		format.sprite_sheet_write(
			{
				guid = sheet,
				key = 1,
				atlas = atlas,
				atlas_size = {32, 16},
				pixels_per_unit = 16,
				filter = .Nearest,
				frames = {{name = "a", rect = {0, 0, 16, 16}, pivot = {0.5, 0}}, {name = "b", rect = {16, 0, 16, 16}, pivot = {0.5, 0}}},
				animations = {{name = "walk", frames = {0, 1}, rate = 2, loop = true}},
				source_path = "game/hero.sprite_sheet",
			},
			context.temp_allocator,
		),
	)

	spawn :: proc(w: ^ecs.World, sheet: format.Guid, z: f32, layer, order: i16) -> ecs.Entity {
		e := ecs.spawn(w)
		ecs.add(w, e, ecs.Transform{position = ecs.position_offset({}, {0, 0, z}), rotation = 1, scale = {2, 1, 1}})
		sprite := DEFAULT_SPRITE_RENDERER
		sprite.sheet, sprite.layer, sprite.order = sheet, layer, order
		ecs.add(w, e, sprite)
		return e
	}
	far := spawn(rig.w, sheet, 5, 0, 0)
	near := spawn(rig.w, sheet, 2, 0, 0)
	over := spawn(rig.w, sheet, 9, 0, 1)
	top := spawn(rig.w, sheet, 9, 1, -5)
	hidden_sprite := spawn(rig.w, sheet, 3, 0, 0)
	clear_sprite := spawn(rig.w, sheet, 3, 0, 0)
	ecs.get_write(rig.w, clear_sprite, Sprite_Renderer).opacity = 0
	// One that walks, lit and snapped and flipped, half a second into its second frame.
	walker := spawn(rig.w, sheet, 4, 2, 0)
	walk := ecs.get_write(rig.w, walker, Sprite_Renderer)
	walk.animation, walk.time, walk.lit, walk.pixel_snap, walk.flip_x, walk.opacity = 1, 0.6, true, true, true, 0.5
	// A sprite of a sheet that is not cooked draws nothing, and says nothing.
	spawn(rig.w, {0 = 0x99}, 3, 0, 0)

	capture: Sprite_Capture
	capture.records = make([dynamic]Sheet_Sprite_Record)
	capture.passes = make(map[string]int)
	defer delete(capture.records)
	defer delete(capture.passes)
	hidden := make([]u32, int(ecs.entity_index(hidden_sprite)) / 32 + 1, context.temp_allocator)
	hidden[ecs.entity_index(hidden_sprite) / 32] |= 1 << (ecs.entity_index(hidden_sprite) % 32)
	desc := Frame_Desc {
		view = {rotation = 1, projection = Orthographic{10, 0.1, 100}},
		size = {64, 32},
		hidden = hidden,
		keep_ids = true,
		hooks = {
			ui = proc(f: ^Frame) {
				capture := (^Sprite_Capture)(f.data)
				clear(&capture.records)
				clear(&capture.passes)
				if f.sheet_sprites != nil {
					append(&capture.records, ..([^]Sheet_Sprite_Record)(raw_data(f.sheet_sprites.records.data))[:f.sheet_sprites.count])
				}
				for pass in f.graph.passes {
					capture.passes[pass.name] += 1
				}
			},
		},
	}
	desc.hooks.data = &capture
	// The atlas streams in over the first frames.
	for _ in 0 ..< 8 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	ids := make([dynamic]u32, context.temp_allocator)
	for record in capture.records {
		append(&ids, record.id)
	}
	wanted := []u32{entity_id(far), entity_id(near), entity_id(over), entity_id(top), entity_id(walker)}
	testing.expectf(t, slice.equal(ids[:], wanted), "the sprites draw as %v, want %v", ids, wanted)
	testing.expect_value(t, capture.passes["sheet sprites"], 1)
	testing.expect_value(t, capture.passes["sheet sprite ids"], 1)
	if len(capture.records) == 5 {
		// A frame of 16 texels at 16 to a meter is 1 m, twice as wide by the Transform's scale, about its pivot at the
		// middle of its bottom, with the first frame's half of the texture.
		first := capture.records[0]
		testing.expect_value(t, first.center, [3]f32{0, 0, 5})
		testing.expect_value(t, first.right, [3]f32{2, 0, 0})
		testing.expect_value(t, first.up, [3]f32{0, 1, 0})
		testing.expect_value(t, first.pivot, [2]f32{0.5, 0})
		testing.expect_value(t, first.uv_rect, [4]f32{0, 0, 0.5, 1})
		testing.expect_value(t, first.color, [4]f32{1, 1, 1, 1})
		testing.expect_value(t, first.flags, 0)
		testing.expect_value(t, first.sampler, gpu.sampler_index(r.sheet_sprites.samplers[.Nearest]))
		// The walker shows its second frame, flipped, with its flags and its opacity.
		last := capture.records[4]
		testing.expect_value(t, last.uv_rect, [4]f32{1, 0, -0.5, 1})
		testing.expect_value(t, last.flags, SHEET_SPRITE_LIT | SHEET_SPRITE_SNAP)
		testing.expect_value(t, last.color.a, 0.5)
	}
	// While the world stands still, a sprite that the editor plays shows the frame of the host's time, and the others
	// the frame of their own.
	playing := [1]ecs.Entity{walker}
	desc.playing = playing[:]
	testing.expect(t, draw_frame(r, rig.w, desc))
	if len(capture.records) == 5 {
		testing.expect_value(t, capture.records[4].uv_rect, [4]f32{0.5, 0, -0.5, 1})
	}
	desc.playing = nil
	// A frame that does not keep the IDs has no pass for them.
	desc.keep_ids = false
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, capture.passes["sheet sprites"], 1)
	testing.expect_value(t, capture.passes["sheet sprite ids"], 0)
	testing.expect_value(t, len(capture.records), 5)
	// A sprite that is turned a quarter about its z draws turned about the view's axis, with its frame's shape.
	turned := sheet_sprite_record(
		DEFAULT_SPRITE_RENDERER,
		{rotation = linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1}), scale = 1},
		{rect = {0, 0, 16, 32}, pivot = {0.5, 0.5}},
		&format.Sprite_Sheet_Blob{atlas_size = {32, 32}, pixels_per_unit = 16},
		{rotation = 1, projection = Perspective{1, 0.05}},
		1,
		2,
		3,
	)
	testing.expect(t, linalg.length(turned.right - [3]f32{0, 1, 0}) < 1e-5 && linalg.length(turned.up - [3]f32{-2, 0, 0}) < 1e-5)
	testing.expectf(t, len(rig.record.problems) == 0, "problems: %v", rig.record.problems)
}

// A frame brings the pool of mesh pages up to date in its first pass, whether or not anything draws yet, so a paged
// mesh's roots come in, the mesh is ready, and its level 0 is assembled for the ray scene.
@(test)
a_frame_streams_a_paged_meshs_pages :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig)
	defer rig_stop(rig)
	context.logger = {record_problems, &rig.record, .Debug, {}}
	fake: Page_Fake
	context.user_ptr = &fake
	r, platform := rig.r, &rig.platform
	platform.time_seconds = proc() -> f64 {return 0.1}
	platform.gpu_stream_texture, platform.gpu_stream_buffer, platform.gpu_transfer_done = null.stream_texture, null.stream_buffer, null.transfer_done
	page_file_reads(platform)
	enable_frame_pipelines(r)
	defer platform.gpu_destroy_texture(r.blue_noise.texture)

	guid := format.Guid{0 = 0x52, 15 = 2}
	buffer: [32]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s.blob", rig.dir, format.guid_format(guid, &buffer)), paged_mesh_bytes(guid, chain_pages())) == nil)
	e := ecs.spawn(rig.w)
	ecs.add(rig.w, e, ecs.Transform{position = ecs.position_offset({}, {0, 0, -5}), rotation = 1, scale = 1})
	ecs.add(rig.w, e, Mesh_Renderer{mesh = guid})

	passes := make(map[string]int)
	defer delete(passes)
	desc := Frame_Desc {
		view = {rotation = 1, projection = Perspective{1, 0.1}},
		size = {64, 32},
		hooks = {
			ui = proc(f: ^Frame) {
				passes := (^map[string]int)(f.data)
				clear(passes)
				for pass in f.graph.passes {
					passes[pass.name] += 1
				}
			},
		},
	}
	desc.hooks.data = &passes
	// The first frame makes the pool when it first asks for the mesh, after its passes began: it has no pass for it.
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, passes["stream pages"], 0)
	_, ready := resident_mesh(&r.residency, guid)
	testing.expect(t, !ready)
	// The second copies the root, and the third finds the mesh ready.
	testing.expect(t, draw_frame(r, rig.w, desc))
	testing.expect_value(t, passes["stream pages"], 1)
	testing.expect_value(t, passes["copy page feedback"], 1)
	testing.expect_value(t, mesh_stream_stats(&r.residency).resident_pages, 1)
	testing.expect(t, draw_frame(r, rig.w, desc))
	mesh, now_ready := resident_mesh(&r.residency, guid)
	testing.expect(t, now_ready && mesh.paged)
	for _ in 0 ..< 6 {
		testing.expect(t, draw_frame(r, rig.w, desc))
	}
	testing.expect_value(t, passes["stream pages"], 1)
	// The frame traces, so the mesh's level 0 was read from its pages and has an acceleration structure.
	if r.residency.accels {
		mesh, _ = resident_mesh(&r.residency, guid)
		_, whole := mesh.level0.(Level0_Ready)
		testing.expect(t, whole && mesh.accel != {} && mesh.positions != {})
		testing.expect(t, fake.reads_begun > 0)
	}
	testing.expect_value(t, fake.reads_open, 0)
	testing.expectf(t, len(rig.record.problems) == 0, "the frames logged %v", rig.record.problems)
}

// What a frame's transient textures take at 1080p at each preset, once the reflection probe's capture is done, and in a
// frame at Ultra that captures all six of its faces: every frame executes, the null backend checks its barriers and
// waits, and the textures that they share are fewer than they are. The numbers are logged at the Info level.
@(test)
transient_textures_share_at_each_preset :: proc(t: ^testing.T) {
	sync.guard(&backend_lock)
	SIZE :: [2]u32{1920, 1080}
	rig := new(Rig)
	defer free(rig)
	rig_start(t, rig, {i32(SIZE.x), i32(SIZE.y)})
	defer rig_stop(rig)
	runner := context.logger
	context.logger = {record_problems, &rig.record, .Debug, {}}
	r := rig.r
	probe, _ := fill_world(rig.w)
	enable_frame_pipelines(r)
	defer rig.platform.gpu_destroy_texture(r.blue_noise.texture)

	measure :: proc(t: ^testing.T, r: ^Renderer, w: ^ecs.World, name: string, quality: ^Quality, faces: u32, runner: log.Logger) {
		// The frames go on until the probe's capture draws the faces asked for: none once it is done, or all six.
		for k in 0 ..< 16 {
			desc := Frame_Desc {
				view    = View{position = ecs.position_offset({}, {f32(k), 1, -4}), rotation = 1, projection = Perspective{1, 0.05}},
				size    = SIZE,
				quality = quality,
			}
			testing.expectf(t, draw_frame(r, w, desc), "%s: frame %d did not execute", name, k)
			if reflection_probe_stats(r).faces == faces {
				break
			}
		}
		testing.expectf(t, reflection_probe_stats(r).faces == faces, "%s: the probe's capture drew %v", name, reflection_probe_stats(r))
		s := r.transients
		testing.expectf(t, s.taken > 0 && s.taken < s.textures, "%s: %d transient textures took %d", name, s.textures, s.taken)
		testing.expect(t, s.taken_bytes < s.bytes)
		testing.expect(t, s.taken <= MAX_CACHED_TEXTURES)
		context.logger = runner
		log.infof(
			"%s: %d transient textures, %.1f MiB; they take %d, %.1f MiB",
			name,
			s.textures,
			f64(s.bytes) / (1 << 20),
			s.taken,
			f64(s.taken_bytes) / (1 << 20),
		)
	}
	for preset in Quality_Preset.Low ..= Quality_Preset.Ultra {
		q := preset_quality(preset, r.caps)
		measure(t, r, rig.w, fmt.tprint(preset), &q, 0, runner)
	}
	q := preset_quality(.Ultra, r.caps)
	testing.expect(t, capture_reflection_probe(r, probe))
	measure(t, r, rig.w, "Ultra, capturing six faces", &q, 6, runner)
	testing.expectf(t, len(rig.record.problems) == 0, "the frames logged %v", rig.record.problems)
}

package render

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:sync"
import "core:testing"

import core "cinnabar:core"
import "cinnabar:core/gpu"
import null "cinnabar:core/gpu/null"
import "cinnabar:core/jobs"
import "cinnabar:engine/ecs"

@(private = "file")
EARTH :: f32(6360000)
@(private = "file")
BOTTOM :: f32(1500)
@(private = "file")
TOP :: f32(4000)

@(private = "file")
near :: proc(a, b, tolerance: f32) -> bool {
	return abs(a - b) <= tolerance
}

// The default Clouds have no density, so a scene without the component has none, and a layer from 1500 to 4000 m.
@(test)
the_default_clouds_are_off_with_a_top_at_4000 :: proc(t: ^testing.T) {
	s := cloud_settings(DEFAULT_CLOUDS)
	testing.expect_value(t, s.density, 0)
	testing.expect_value(t, s.bottom, BOTTOM)
	testing.expect_value(t, s.top, TOP)
	testing.expect_value(t, s.far_distance, 15000)
	testing.expect_value(t, s.far_coverage, 0.5)
	// The settings keep their ranges, whatever a volume blends.
	wild := DEFAULT_CLOUDS
	wild.coverage, wild.weather_size, wild.thickness, wild.shadow_strength = {true, 3}, {true, 10}, {true, 1}, {true, -2}
	wild.base_variation = {true, 7}
	s = cloud_settings(wild)
	testing.expect_value(t, s.coverage, 1)
	testing.expect_value(t, s.base_variation, 1)
	testing.expect_value(t, s.weather_size, 1000)
	testing.expect_value(t, s.top, BOTTOM + 100)
	testing.expect_value(t, s.shadow_strength, 0)
}

// The shell's segment from below the layer, inside it and above it, looking up, down and along the horizon.
@(test)
the_cloud_shell_is_the_segment_through_the_layer :: proc(t: ^testing.T) {
	// From the ground, looking up: the bottom, then the top, where the heights say.
	t0, t1, hit := cloud_shell(1, 1, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 <= t1)
	testing.expect(t, near(cloud_height_at(1, 1, t0, EARTH), BOTTOM, 1) && near(cloud_height_at(1, 1, t1, EARTH), TOP, 1))
	// Along the horizon from the ground, the layer is about sqrt(2 R bottom) away.
	horizon := math.sqrt(2 * EARTH * BOTTOM)
	t0, t1, hit = cloud_shell(1, 0, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 <= t1)
	testing.expectf(t, near(t0, horizon, horizon * 0.01), "the horizon's bottom is at %v, not about %v", t0, horizon)
	testing.expect(t, near(cloud_height_at(1, 0, t0, EARTH), BOTTOM, 1) && near(cloud_height_at(1, 0, t1, EARTH), TOP, 1))
	// Straight down from the ground: the shell is on the far side of the planet, past the ground, so there are no clouds.
	ground, grounded := cloud_ground(1, -1, EARTH)
	testing.expect(t, grounded && near(ground, 1, 0.01))
	t0, t1, hit = cloud_shell(1, -1, BOTTOM, TOP, EARTH)
	testing.expect(t, !hit || t0 > ground)
	// A little down, missing the ground: the bottom shell beyond the horizon's distance.
	_, grounded = cloud_ground(1, -1e-4, EARTH)
	testing.expect(t, !grounded)
	t0, t1, hit = cloud_shell(1, -1e-4, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 >= horizon * 0.99 && t0 <= t1)

	// Inside the layer: the segment starts at the camera and ends at the top looking up, at the bottom looking down.
	inside := f32(2500)
	t0, t1, hit = cloud_shell(inside, 1, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 == 0 && near(cloud_height_at(inside, 1, t1, EARTH), TOP, 1))
	t0, t1, hit = cloud_shell(inside, -1, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 == 0 && near(cloud_height_at(inside, -1, t1, EARTH), BOTTOM, 1))
	t0, t1, hit = cloud_shell(inside, 0, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 == 0 && t1 > 0 && near(cloud_height_at(inside, 0, t1, EARTH), TOP, 1))

	// Above the layer: nothing looking up or along the horizon, the top then the bottom looking down.
	above := f32(6000)
	_, _, hit = cloud_shell(above, 1, BOTTOM, TOP, EARTH)
	testing.expect(t, !hit)
	_, _, hit = cloud_shell(above, 0, BOTTOM, TOP, EARTH)
	testing.expect(t, !hit)
	t0, t1, hit = cloud_shell(above, -1, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 <= t1)
	testing.expect(t, near(cloud_height_at(above, -1, t0, EARTH), TOP, 1) && near(cloud_height_at(above, -1, t1, EARTH), BOTTOM, 1))
	t0, t1, hit = cloud_shell(above, -0.05, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 <= t1 && near(cloud_height_at(above, -0.05, t0, EARTH), TOP, 1))
	// A ray from above that grazes the layer's top without reaching the bottom leaves through the top.
	graze := -math.sqrt(1 - f32(math.pow(f64(EARTH + TOP - 500) / f64(EARTH + above), 2)))
	t0, t1, hit = cloud_shell(above, graze, BOTTOM, TOP, EARTH)
	testing.expect(t, hit && t0 < t1 && near(cloud_height_at(above, graze, t1, EARTH), TOP, 1))
}

// The height along a ray matches the sphere's math in f64 within a meter out to 40 km.
@(test)
the_height_along_a_ray_keeps_its_precision :: proc(t: ^testing.T) {
	for h0 in ([]f32{1, 500, 2500, 6000}) {
		for mu in ([]f32{1, 0.5, 0.1, 0, -0.01, -0.3}) {
			for distance in ([]f32{10, 1000, 10000, 25000, 40000}) {
				d := [3]f64{math.sqrt(max(1 - f64(mu) * f64(mu), 0)), f64(mu), 0}
				p := [3]f64{0, f64(EARTH) + f64(h0), 0} + d * f64(distance)
				exact := linalg.length(p) - f64(EARTH)
				got := cloud_height_at(h0, mu, distance, EARTH)
				testing.expectf(t, abs(f64(got) - exact) <= 1, "h0 %v mu %v t %v: %v, exactly %v", h0, mu, distance, got, exact)
			}
		}
	}
}

// Each cloud type's gradient follows its knots, and the far clouds reach far_coverage at twice far_distance.
@(test)
the_gradient_follows_the_types_knots_and_the_far_clouds_blend_over :: proc(t: ^testing.T) {
	// Stratus: whole from 0.1 to 0.2, gone at 0.3.
	testing.expect(t, near(cloud_gradient(0.05, 0), 0.5, 1e-5))
	testing.expect_value(t, cloud_gradient(0.15, 0), 1)
	testing.expect_value(t, cloud_gradient(0.5, 0), 0)
	// Cumulus: whole from 0.2 to 0.4, gone at 0.6.
	testing.expect_value(t, cloud_gradient(0.3, 0.5), 1)
	testing.expect(t, near(cloud_gradient(0.5, 0.5), 0.5, 1e-5))
	testing.expect_value(t, cloud_gradient(0.7, 0.5), 0)
	// Cumulonimbus: whole from 0.1 to 0.7, gone at the top.
	testing.expect_value(t, cloud_gradient(0.5, 1), 1)
	testing.expect(t, near(cloud_gradient(0.85, 1), 0.5, 1e-5))
	testing.expect_value(t, cloud_gradient(1, 1), 0)
	testing.expect_value(t, cloud_gradient(0, 1), 0)
	// Between types, the knots lerp: at 0.25 the top knot is between stratus's 0.3 and cumulus's 0.6.
	testing.expect(t, near(cloud_gradient(0.45, 0.25), 0, 1e-5) && cloud_gradient(0.4, 0.25) > 0)

	testing.expect_value(t, cloud_far(15000, 15000), 0)
	testing.expect_value(t, cloud_far(22500, 15000), 0.5)
	testing.expect_value(t, cloud_far(30000, 15000), 1)
	testing.expect_value(t, cloud_far(40000, 15000), 1)
	testing.expect_value(t, cloud_far_coverage(0.9, 0.5, cloud_far(30000, 15000)), 0.5)
	testing.expect_value(t, cloud_far_coverage(0.9, 0.5, cloud_far(5000, 15000)), 0.9)
}

// The shadow map is centered where the sun's rays through the camera meet the layer's bottom, so the camera reads it at
// its middle, within the texel that the center snaps to.
@(test)
the_shadow_map_is_centered_under_the_camera_along_the_sun :: proc(t: ^testing.T) {
	to_sun := linalg.normalize([3]f32{0.3, 0.8, 0.5})
	bottom_rel := BOTTOM - 1
	size := u32(512)
	center := cloud_shadow_center(to_sun, bottom_rel, {0, 0}, size)
	uv, inside := cloud_shadow_uv({0, 0, 0}, to_sun, bottom_rel, center, CLOUD_SHADOW_EXTENT)
	testing.expect(t, inside)
	texel := 0.5 / f32(size)
	testing.expectf(t, near(uv.x, 0.5, texel + 1e-5) && near(uv.y, 0.5, texel + 1e-5), "the camera reads the map at %v", uv)
	// The center is on the map's texels in the render origin's space, wherever the camera is in it.
	offset := [2]f32{123.456, -78.9}
	moved := cloud_shadow_center(to_sun, bottom_rel, offset, size)
	step := f32(CLOUD_SHADOW_EXTENT) / f32(size)
	for axis in 0 ..< 2 {
		snapped := (moved[axis] + offset[axis]) / step
		testing.expectf(t, near(snapped, math.round(snapped), 1e-3), "the center is not on a texel: %v", moved)
	}
	// A point under the map's edge reads outside it, and so does one with the sun on the horizon.
	_, inside = cloud_shadow_uv({CLOUD_SHADOW_EXTENT, 0, 0}, to_sun, bottom_rel, center, CLOUD_SHADOW_EXTENT)
	testing.expect(t, !inside)
	_, inside = cloud_shadow_uv({0, 0, 0}, {1, 0.01, 0}, bottom_rel, center, CLOUD_SHADOW_EXTENT)
	testing.expect(t, !inside)
}

// The offsets of a camera far from the weather's origin, or after hours of wind, reduce to what a near one's do.
@(test)
the_weather_and_noise_offsets_reduce_to_their_periods :: proc(t: ^testing.T) {
	size := f32(50000)
	weather, noise := cloud_offsets({123.4, 123.4}, size)
	far_weather, far_noise := cloud_offsets({1.5e11 + 123.4, 123.4}, size)
	testing.expect(t, near(weather.x, 123.4, 1e-3) && near(noise.x, 123.4, 1e-3))
	testing.expect(t, near(far_weather.x, weather.x, 1e-3) && near(far_weather.y, weather.y, 1e-3))
	testing.expect(t, near(far_noise.x, noise.x, 1e-3) && near(far_noise.y, noise.y, 1e-3))
	// A negative offset folds into the period.
	weather, noise = cloud_offsets({-100, -100}, size)
	testing.expect(t, near(weather.x, size - 100, 1e-3) && near(noise.x, CLOUD_NOISE_PERIOD - 100, 1e-3))
	// The wind blows toward its azimuth, from +z toward +x.
	wind := wind_vector(3, 90)
	testing.expect(t, near(wind.x, 3, 1e-5) && near(wind.y, 0, 1e-5))
	// The cirrus's offset wraps by whole periods in the wind's frame: a wind at 30 degrees, carried a stretched period
	// along it or a period across it, reads the same offset.
	a := f64(math.to_radians(f32(30)))
	along := [2]f64{math.sin(a), math.cos(a)}
	across := [2]f64{-along.y, along.x}
	base := cirrus_offset({123.4, -56.7}, 30)
	wrapped := cirrus_offset({123.4 + along.x * CIRRUS_PERIOD * CIRRUS_STRETCH, -56.7 + along.y * CIRRUS_PERIOD * CIRRUS_STRETCH}, 30)
	testing.expectf(t, near(wrapped.x, base.x, 1e-2) && near(wrapped.y, base.y, 1e-2), "along: %v != %v", wrapped, base)
	wrapped = cirrus_offset({123.4 + across.x * CIRRUS_PERIOD, -56.7 + across.y * CIRRUS_PERIOD}, 30)
	testing.expectf(t, near(wrapped.x, base.x, 1e-2) && near(wrapped.y, base.y, 1e-2), "across: %v != %v", wrapped, base)
}

// What one frame of the clouds did: its live passes by name, and what the frame saw.
@(private = "file")
Cloud_Run :: struct {
	passes:  map[string]int,
	clouds:  bool,
	shadow:  bool,
	valid:   bool,
	bake:    bool,
	sun:     bool,
	ok:      bool,
}

@(private = "file")
run_cloud_frame :: proc(
	t: ^testing.T,
	r: ^Renderer,
	cache: ^Texture_Cache,
	exposure: gpu.Buffer,
	s: Cloud_Settings,
	sky: Sky_Settings,
	with_sky: bool,
) -> (
	run: Cloud_Run,
) {
	platform := r.platform
	g := begin(platform, cache)
	f := new(Frame, platform.frame_allocator)
	f^ = {
		renderer = r,
		graph    = &g,
		size     = {64, 32},
		view     = {rotation = 1, vertical_fov = 1, near = 0.05},
	}
	f.view_projection = view_projection(f.view, 2)
	f.depth = create_texture(&g, {size = f.size, format = DEPTH_FORMAT, label = "depth"})
	f.scene = create_texture(&g, {size = f.size, format = SCENE_FORMAT, label = "scene"})
	f.exposure = import_buffer(&g, exposure)
	// An atmosphere, as begin_sky leaves it, with the untinted sun of its constants.
	if with_sky {
		f.sky = new(Sky_Frame, platform.frame_allocator)
		f.sky.constants.sun_illuminance = {3, 3, 3, 0}
	}
	// The sun's light record, as extract_lights writes it, which the sky names.
	lf := new(Light_Frame, platform.frame_allocator)
	lf.records = make([dynamic]Light_Record, platform.frame_allocator)
	append(&lf.records, Light_Record{type = .Directional, direction = -linalg.normalize(sky.sun_direction), color = {3, 3, 3}, shadow = -1, mask = -1})
	lf.directional_count = 1
	lf.directional[0] = sky.sun
	f.lights = lf
	prepass := add_render_pass(&g, "prepass", proc(_: ^Pass_Context) {}, nil)
	depth(&g, prepass, f.depth, .Clear)
	ambient := Ambient {
		constant = {0.3, 0.4, 0.6},
	}
	begin_clouds(f, s, sky, ambient)
	add_cloud_shadow_passes(f)
	add_cloud_passes(f)
	world := add_render_pass(&g, "world", proc(_: ^Pass_Context) {}, nil)
	color(&g, world, f.scene, .Clear)
	depth(&g, world, f.depth, .Load)
	add_cloud_composite(f)
	consumer := add_compute_pass(&g, "post", proc(_: ^Pass_Context) {}, nil)
	read(&g, consumer, f.scene)
	keep_pass(&g, consumer)
	if cf := f.clouds; cf != nil {
		run.clouds = true
		run.shadow, run.valid, run.bake, run.sun = cf.shadow != 0, cf.history.valid, cf.bake_noise, cf.sun
		testing.expect(t, (lf.records[0].flags & {.Cloud_Shadow}) != {}, "the sun's record does not cast the cloud shadow")
	}
	run.ok = execute(&g)
	run.passes = make(map[string]int, platform.frame_allocator)
	for node in g.passes {
		if node.live {
			run.passes[node.name] += 1
		}
		switch node.name {
		case "clouds noise", "clouds shadow", "clouds march", "clouds temporal":
			testing.expectf(t, node.queue == .Compute, "%s is on the %v queue", node.name, node.queue)
		case "clouds composite":
			testing.expectf(t, node.queue == .Graphics, "%s is on the %v queue", node.name, node.queue)
		}
	}
	return
}

// The first frame bakes the noise, draws the shadow map, marches, accumulates and composes, and the noise is ready once
// it executes; the next frame bakes nothing and has a history. A frame that fails leaves the noise pending. Without
// density, a pipeline, with the clouds off or without a sky, the frame has no clouds.
@(test)
the_clouds_bake_their_noise_once_and_draw_every_frame_after :: proc(t: ^testing.T) {
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
	v := &r.clouds
	for p in ([]^Shader_Pipeline{&v.noise, &v.shadow, &v.march, &v.temporal, &v.composite}) {
		p.pipeline = platform.gpu_create_compute_pipeline({compute = []byte{1}, label = "test"})
	}
	defer clouds_destroy(v, &platform)
	r.post.sampler = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, label = "test clamp"})
	defer platform.gpu_destroy_sampler(r.post.sampler)
	exposure := platform.gpu_create_buffer({size = 16, usage = {.Storage}, label = "exposure"}, nil)
	defer platform.gpu_destroy_buffer(exposure)
	cache: Texture_Cache
	defer cache_destroy(&cache, &platform)

	settings := cloud_settings(DEFAULT_CLOUDS)
	settings.density = 1
	sky := sky_settings(DEFAULT_ENVIRONMENT)
	sky.mode = .Atmosphere
	sky.sun = ecs.Entity(1)
	sky.sun_direction = {0.3, 0.8, 0.5}
	sky.sun_illuminance = {3, 3, 3}

	// A frame that fails to submit does its work again: the noise stays pending.
	platform.gpu_submit = fail_submit
	run := run_cloud_frame(t, r, &cache, exposure, settings, sky, true)
	testing.expect(t, !run.ok && run.clouds && run.bake)
	testing.expect_value(t, v.noise_state, Cloud_Noise_State.Pending)
	platform.gpu_submit = null.submit
	free_all(platform.frame_allocator)

	run = run_cloud_frame(t, r, &cache, exposure, settings, sky, true)
	testing.expect(t, run.ok && run.clouds && run.shadow && run.sun && run.bake && !run.valid)
	for name in ([]string{"clouds noise", "clouds shadow", "clouds march", "clouds temporal", "clouds composite"}) {
		testing.expectf(t, run.passes[name] == 1, "%s ran %d times", name, run.passes[name])
	}
	testing.expect_value(t, v.noise_state, Cloud_Noise_State.Ready)
	testing.expect(t, v.shadow_map != {} && v.shadow_size == CLOUD_PARAMS[.Low].shadow_size)
	free_all(platform.frame_allocator)

	run = run_cloud_frame(t, r, &cache, exposure, settings, sky, true)
	testing.expect(t, run.ok && run.clouds && run.valid && !run.bake)
	testing.expect_value(t, run.passes["clouds noise"], 0)
	testing.expect_value(t, run.passes["clouds march"], 1)
	testing.expect_value(t, run.passes["clouds composite"], 1)
	free_all(platform.frame_allocator)

	// Another level's shadow map size makes the map again.
	settings.level = .Ultra
	run = run_cloud_frame(t, r, &cache, exposure, settings, sky, true)
	testing.expect(t, run.ok && run.clouds)
	testing.expect_value(t, v.shadow_size, CLOUD_PARAMS[.Ultra].shadow_size)
	settings.level = .Low
	free_all(platform.frame_allocator)

	// No density, the clouds off, a missing pipeline, or no sky: no clouds, and the frame still executes.
	none := settings
	none.density = 0
	run = run_cloud_frame(t, r, &cache, exposure, none, sky, true)
	testing.expect(t, run.ok && !run.clouds)
	free_all(platform.frame_allocator)
	off := settings
	off.off = true
	run = run_cloud_frame(t, r, &cache, exposure, off, sky, true)
	testing.expect(t, run.ok && !run.clouds)
	free_all(platform.frame_allocator)
	march := v.march.pipeline
	v.march.pipeline = {}
	run = run_cloud_frame(t, r, &cache, exposure, settings, sky, true)
	testing.expect(t, run.ok && !run.clouds)
	v.march.pipeline = march
	free_all(platform.frame_allocator)
	run = run_cloud_frame(t, r, &cache, exposure, settings, sky, false)
	testing.expect(t, run.ok && !run.clouds)
	free_all(platform.frame_allocator)
}

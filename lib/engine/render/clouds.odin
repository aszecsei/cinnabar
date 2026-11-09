package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// Volumetric clouds (see docs/rendering/clouds.md#clouds): a ray-marched layer of clouds between two heights above the
// world, shaped by the weather and by noise that the GPU makes once, lit by the sun and the sky's ambient light, at a
// share of the frame's pixels with a history that the frame reprojects, composed over the sky before the fog over the
// background. A shadow map on the layer's bottom darkens the sun on everything that the light loop lights.

// The engine's cloud shaders, by their .meta files.
CLOUDS_NOISE_SHADER :: #load("../content/shaders/clouds_noise.hlsl.meta", string)
CLOUDS_SHADOW_SHADER :: #load("../content/shaders/clouds_shadow.hlsl.meta", string)
CLOUDS_MARCH_SHADER :: #load("../content/shaders/clouds_march.hlsl.meta", string)
CLOUDS_TEMPORAL_SHADER :: #load("../content/shaders/clouds_temporal.hlsl.meta", string)
CLOUDS_COMPOSITE_SHADER :: #load("../content/shaders/clouds_composite.hlsl.meta", string)

// The noise textures' sizes, which match clouds_noise.hlsl: the shape and the detail are 3D, the curl is 2D.
CLOUD_SHAPE_SIZE :: 128
CLOUD_DETAIL_SIZE :: 32
CLOUD_CURL_SIZE :: 128
// The least common multiple of the low layer's noise periods in the world (clouds_common.hlsli: the shape's 8000 m, the
// detail's 600 and the curl's 4000), which the noise offset is reduced by, so hours of wind lose nothing. The cirrus
// reads the shape stretched CIRRUS_STRETCH times along the wind, so its offset is reduced in the wind's frame: by
// CIRRUS_PERIOD times the stretch along it, and by CIRRUS_PERIOD across it.
CLOUD_NOISE_PERIOD :: 24000
CIRRUS_PERIOD :: 8000
CIRRUS_STRETCH :: 3
// The cloud shadow map's side in meters, on the layer's bottom.
CLOUD_SHADOW_EXTENT :: 8000
CLOUD_FORMAT :: gpu.Format.RGBA16_Float
CLOUD_DISTANCE_FORMAT :: gpu.Format.RG32_Float
CLOUD_SHADOW_FORMAT :: gpu.Format.R8_Unorm
CLOUD_NOISE_FORMAT :: gpu.Format.RGBA8_Unorm
CLOUD_GROUP_SIZE :: 8

// Cloud_Settings are a frame's Clouds, from the volumes at the camera, as plain values. A density of 0 is no clouds.
Cloud_Settings :: struct {
	density:           f32,
	weather:           Weather_Source,
	coverage:          f32,
	precipitation:     f32,
	cloud_type:        f32,
	cirrus:            f32,
	weather_map:       format.Guid,
	weather_origin:    ecs.World_Position,
	weather_size:      f32,
	wind_speed:        f32,
	wind_direction:    f32,
	// The low layer's bottom and top, and the cirrus layer's height, in meters above the ground.
	bottom:            f32,
	top:               f32,
	cirrus_height:     f32,
	base_variation:    f32,
	far_distance:      f32,
	far_coverage:      f32,
	ambient_intensity: f32,
	shadow_strength:   f32,
	// The editor turned the clouds off (see apply_debug).
	off:               bool,
	// The CLOUD_PARAMS to march with (see apply_quality).
	level:             Quality_Level,
}

// cloud_settings takes the Cloud_Settings from blended Clouds.
@(private)
cloud_settings :: proc(c: Clouds) -> Cloud_Settings {
	bottom := c.bottom.value
	return {
		density = c.density.value,
		weather = c.weather.value,
		coverage = clamp(c.coverage.value, 0, 1),
		precipitation = clamp(c.precipitation.value, 0, 1),
		cloud_type = clamp(c.cloud_type.value, 0, 1),
		cirrus = clamp(c.cirrus.value, 0, 1),
		weather_map = c.weather_map.value,
		weather_origin = c.weather_origin.value,
		weather_size = max(c.weather_size.value, 1000),
		wind_speed = c.wind_speed.value,
		wind_direction = c.wind_direction.value,
		bottom = bottom,
		top = bottom + max(c.thickness.value, 100),
		cirrus_height = c.cirrus_height.value,
		base_variation = clamp(c.base_variation.value, 0, 1),
		far_distance = max(c.far_distance.value, 1),
		far_coverage = clamp(c.far_coverage.value, 0, 1),
		ambient_intensity = c.ambient_intensity.value,
		shadow_strength = clamp(c.shadow_strength.value, 0, 1),
	}
}

// Cloud_Params are a level's march (see docs/rendering/clouds.md#levels).
Cloud_Params :: struct {
	// The cloud buffer is the frame's size over this on each side.
	divisor:        u32,
	// The most samples along a view ray through the low layer, and the samples toward the sun from a lit sample.
	steps:          u32,
	light_steps:    u32,
	// The shadow map's texels on a side, and its samples through the layer.
	shadow_size:    u32,
	shadow_steps:   u32,
	// This frame's share of the history is 1 over it.
	history_frames: f32,
}

@(rodata)
CLOUD_PARAMS := [Quality_Level]Cloud_Params {
	.Low    = {4, 48, 4, 256, 6, 8},
	.Medium = {2, 64, 5, 512, 8, 12},
	.High   = {2, 96, 6, 512, 10, 16},
	.Ultra  = {2, 128, 6, 1024, 12, 16},
}

// Volumetric_Clouds is the clouds' state between frames, in the Renderer: handles and plain data only (a code reload
// keeps it).
Volumetric_Clouds :: struct {
	noise, shadow, march, temporal, composite: Shader_Pipeline,
	// The noise textures, which the GPU makes once (see Cloud_Noise_State), their repeat sampler, made lazily.
	shape, detail, curl:                       gpu.Texture,
	noise_state:                               Cloud_Noise_State,
	noise_sampler:                             gpu.Sampler,
	// The shadow map, made again when the level's size changes.
	shadow_map:                                gpu.Texture,
	shadow_size:                               u32,
	// How far the wind has carried the weather, in meters, and when it was last advanced (platform.time_seconds), in
	// f64 so hours of wind lose nothing; the constants take it reduced modulo the periods.
	wind_offset:                               [2]f64,
	wind_time:                                 f64,
	// Counts the frames with clouds, for the blue noise's slice.
	frame:                                     u32,
}

// Cloud_Noise_State is whether the noise textures hold noise: Pending until a frame that bakes them executes, whose
// commit marks Ready. A frame that fails leaves it Pending, so the next frame bakes again.
Cloud_Noise_State :: enum u8 {
	Pending,
	Ready,
}

// Cloud_Constants matches Cloud_Constants in clouds_common.hlsli: every cloud pass's constants. right and up have the
// projection's scales in w. previous takes a point relative to this frame's camera to last frame's clip space.
// sun_direction points toward the sun, with 1 in w when a sun lights the clouds. Heights are above the ground. The
// offsets are the camera relative to the weather map's origin, less the wind's carry, reduced modulo the map's size,
// the noise period, and the cirrus's periods in the wind's frame.
@(private)
Cloud_Constants :: struct {
	right:              [4]f32,
	up:                 [4]f32,
	forward:            [4]f32,
	previous:           matrix[4, 4]f32,
	sun_direction:      [4]f32,
	sun_illuminance:    [4]f32,
	cirrus_illuminance: [4]f32,
	ambient:            [4][4]f32,
	camera_height:      f32,
	bottom:             f32,
	top:                f32,
	cirrus_height:      f32,
	planet_radius:      f32,
	inv_weather_size:   f32,
	far_distance:       f32,
	far_coverage:       f32,
	weather_offset:     [2]f32,
	noise_offset:       [2]f32,
	wind_direction:     [2]f32,
	screen_size:        [2]f32,
	coverage:           f32,
	precipitation:      f32,
	cloud_type:         f32,
	cirrus:             f32,
	density:            f32,
	history_blend:      f32,
	shadow_extent:      f32,
	near:               f32,
	shadow_center:      [2]f32,
	shadow_size:        u32,
	shadow_steps:       u32,
	steps:              u32,
	light_steps:        u32,
	divisor:            u32,
	frame:              u32,
	size:               [2]u32,
	use_map:            u32,
	shape:              u32,
	detail:             u32,
	curl:               u32,
	noise_sampler:      u32,
	weather:            u32,
	blue_noise:         u32,
	clamp_sampler:      u32,
	cirrus_offset:      [2]f32,
	base_variation:     f32,
	padding:            [3]f32,
}

#assert(size_of(Cloud_Constants) == 416)

// Cloud_Push matches Cloud_Push in clouds_common.hlsli: one pass's textures, which exist only once the frame records.
@(private = "file")
Cloud_Push :: struct {
	depth:    u32,
	current:  u32,
	distance: u32,
	history:  u32,
	output:   u32,
	kind:     u32,
	valid:    u32,
	exposure: u32,
}

#assert(size_of(Cloud_Push) <= 128)

// Cloud_Frame is what one frame's cloud passes need, in frame memory.
@(private)
Cloud_Frame :: struct {
	settings:    Cloud_Settings,
	params:      Cloud_Params,
	// Uploaded in begin_clouds, but for previous, which add_cloud_shadow_passes writes once add_scene_passes has set
	// Frame.previous_view_projection.
	constants:   Cloud_Constants,
	upload:      gpu.Upload,
	// The cloud buffer: (Frame.size + divisor - 1) / divisor.
	size:        [2]u32,
	// "clouds history": RGBA16_Float at size, the clouds' light (not pre-exposed) and their transmittance in a.
	history:     History,
	// This frame's march, and its mean distance (x) with the block's scene depth (y), transients.
	current:     Texture,
	distance:    Texture,
	// The noise textures, imported.
	shape:       Texture,
	detail:      Texture,
	curl:        Texture,
	// The imported shadow map, or 0 without a light that casts it.
	shadow:      Texture,
	shadow_fade: f32,
	// This frame adds the noise pass.
	bake_noise:  bool,
	// The resident weather map, or 0.
	weather:     gpu.Texture,
	// The scene that the composite writes, snapshotted at declaration: later passes replace Frame.scene.
	scene:       Texture,
	// Whether a sun lights the clouds.
	sun:         bool,
}

clouds_init :: proc(v: ^Volumetric_Clouds) {
	v.noise = shader_pipeline(CLOUDS_NOISE_SHADER)
	v.shadow = shader_pipeline(CLOUDS_SHADOW_SHADER)
	v.march = shader_pipeline(CLOUDS_MARCH_SHADER)
	v.temporal = shader_pipeline(CLOUDS_TEMPORAL_SHADER)
	v.composite = shader_pipeline(CLOUDS_COMPOSITE_SHADER)
}

clouds_destroy :: proc(v: ^Volumetric_Clouds, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&v.noise, &v.shadow, &v.march, &v.temporal, &v.composite}) {
		destroy_shader_pipeline(p, platform)
	}
	for t in ([]^gpu.Texture{&v.shape, &v.detail, &v.curl, &v.shadow_map}) {
		if t^ != {} {
			platform.gpu_destroy_texture(t^)
			t^ = {}
		}
	}
	if v.noise_sampler != {} {
		platform.gpu_destroy_sampler(v.noise_sampler)
		v.noise_sampler = {}
	}
	v.noise_state = .Pending
	v.shadow_size = 0
}

@(private)
sync_cloud_pipelines :: proc(r: ^Renderer, force: bool) {
	v := &r.clouds
	assets := r.residency.assets
	sync_compute_pipeline(&v.noise, r.platform, assets, {label = "clouds noise"}, force)
	sync_compute_pipeline(&v.shadow, r.platform, assets, {label = "clouds shadow"}, force)
	sync_compute_pipeline(&v.march, r.platform, assets, {label = "clouds march"}, force)
	sync_compute_pipeline(&v.temporal, r.platform, assets, {label = "clouds temporal"}, force)
	sync_compute_pipeline(&v.composite, r.platform, assets, {label = "clouds composite"}, force)
}

// ensure_cloud_noise makes the noise textures and their sampler the first time, or again after a soft restart, which
// destroys them with the rest of the Game scope. New textures hold no noise: the state says so.
@(private = "file")
ensure_cloud_noise :: proc(r: ^Renderer) -> bool {
	v := &r.clouds
	platform := r.platform
	if v.shape == {} {
		v.shape = platform.gpu_create_texture({size = {CLOUD_SHAPE_SIZE, CLOUD_SHAPE_SIZE}, depth = CLOUD_SHAPE_SIZE, format = CLOUD_NOISE_FORMAT, usage = {.Sampled, .Storage}, label = "clouds shape noise"}, nil)
	}
	if v.detail == {} {
		v.detail = platform.gpu_create_texture({size = {CLOUD_DETAIL_SIZE, CLOUD_DETAIL_SIZE}, depth = CLOUD_DETAIL_SIZE, format = CLOUD_NOISE_FORMAT, usage = {.Sampled, .Storage}, label = "clouds detail noise"}, nil)
	}
	if v.curl == {} {
		v.curl = platform.gpu_create_texture({size = {CLOUD_CURL_SIZE, CLOUD_CURL_SIZE}, format = CLOUD_NOISE_FORMAT, usage = {.Sampled, .Storage}, label = "clouds curl noise"}, nil)
	}
	if v.noise_sampler == {} {
		v.noise_sampler = platform.gpu_create_sampler({filter = .Linear, mip_filter = .Linear, address = .Repeat, label = "clouds repeat sampler"})
	}
	return v.shape != {} && v.detail != {} && v.curl != {} && v.noise_sampler != {}
}

// ensure_cloud_shadow_map makes the shadow map for a level's size, and again when the size changes.
@(private = "file")
ensure_cloud_shadow_map :: proc(r: ^Renderer, size: u32) -> bool {
	v := &r.clouds
	platform := r.platform
	if v.shadow_map != {} && v.shadow_size == size {
		return true
	}
	if v.shadow_map != {} {
		platform.gpu_destroy_texture(v.shadow_map)
	}
	v.shadow_map = platform.gpu_create_texture({size = {size, size}, format = CLOUD_SHADOW_FORMAT, usage = {.Sampled, .Storage}, label = "clouds shadow map"}, nil)
	v.shadow_size = size
	return v.shadow_map != {}
}

// wind_vector is the wind's velocity over the ground, in meters per second, toward an azimuth in degrees from +z toward
// +x, as sky_direction has it.
@(private)
wind_vector :: proc(speed, direction: f32) -> [2]f32 {
	a := math.to_radians(direction)
	return {speed * math.sin(a), speed * math.cos(a)}
}

// cloud_offsets reduces the weather's and the noise's offsets from the camera, in meters, to one period each, folded
// into [0, period), so a camera far from the weather's origin and hours of wind keep their precision in f32.
@(private)
cloud_offsets :: proc(total: [2]f64, weather_size: f32) -> (weather, noise: [2]f32) {
	fold :: proc(v: f64, period: f64) -> f32 {
		m := math.mod(v, period)
		if m < 0 {
			m += period
		}
		return f32(m)
	}
	size := f64(max(weather_size, 1))
	return {fold(total.x, size), fold(total.y, size)}, {fold(total.x, CLOUD_NOISE_PERIOD), fold(total.y, CLOUD_NOISE_PERIOD)}
}

// cirrus_offset reduces the cirrus's offset from the camera, in meters, in the wind's frame: along the wind, whose
// azimuth is in degrees from +z toward +x, to one stretched period, and across it to one period, so a wrap of either
// moves the cirrus's lookup by whole periods of the shape noise, whatever the wind's direction.
@(private)
cirrus_offset :: proc(total: [2]f64, wind_direction: f32) -> [2]f32 {
	fold :: proc(v: f64, period: f64) -> f32 {
		m := math.mod(v, period)
		if m < 0 {
			m += period
		}
		return f32(m)
	}
	a := f64(math.to_radians(wind_direction))
	along := [2]f64{math.sin(a), math.cos(a)}
	across := [2]f64{-along.y, along.x}
	return {fold(total.x * along.x + total.y * along.y, CIRRUS_PERIOD * CIRRUS_STRETCH), fold(total.x * across.x + total.y * across.y, CIRRUS_PERIOD)}
}

// The geometry on the CPU, which matches clouds_common.hlsli: a ray from a height h0 above the ground with mu, the
// cosine of its angle from the zenith, over a planet of radius R, all in meters.

@(private = "file")
sphere_above :: proc(h0, mu, H, R: f32) -> f32 {
	r := R + h0
	b := r * mu
	c := (h0 - H) * (2 * R + h0 + H)
	return -c / (b + math.sqrt(max(b * b - c, 0)))
}

@(private = "file")
sphere_below :: proc(h0, mu, H, R: f32) -> (near_t, far_t: f32, hit: bool) {
	r := R + h0
	b := r * mu
	c := (h0 - H) * (2 * R + h0 + H)
	disc := b * b - c
	if b >= 0 || disc < 0 {
		return
	}
	s := math.sqrt(disc)
	return c / (-b + s), -b + s, true
}

// cloud_shell is the segment of the ray through the layer between bottom and top, from below it, inside it, or from
// above it, or no hit.
cloud_shell :: proc(h0, mu, bottom, top, R: f32) -> (t0, t1: f32, hit: bool) {
	if h0 < bottom {
		return sphere_above(h0, mu, bottom, R), sphere_above(h0, mu, top, R), true
	}
	if h0 < top {
		t1 = sphere_above(h0, mu, top, R)
		if near_t, _, below := sphere_below(h0, mu, bottom, R); below {
			t1 = min(t1, near_t)
		}
		return 0, t1, true
	}
	near_t, far_t, reaches := sphere_below(h0, mu, top, R)
	if !reaches {
		return
	}
	t0, t1 = near_t, far_t
	if bottom_near, _, below := sphere_below(h0, mu, bottom, R); below {
		t1 = bottom_near
	}
	return t0, t1, true
}

// cloud_ground is whether the ray meets the ground, and where.
cloud_ground :: proc(h0, mu, R: f32) -> (t: f32, hit: bool) {
	r := R + h0
	b := r * mu
	c := h0 * (2 * R + h0)
	disc := b * b - c
	if mu >= 0 || disc < 0 {
		return
	}
	return c / (-b + math.sqrt(disc)), true
}

// cloud_height_at is the height above the ground at a distance along the ray.
cloud_height_at :: proc(h0, mu, t, R: f32) -> f32 {
	r := R + h0
	rise := 2 * r * mu * t + t * t
	return h0 + rise / (math.sqrt(max(r * r + rise, 0)) + r)
}

// cloud_remap is remap in clouds_common.hlsli.
@(private = "file")
cloud_remap :: proc(v, lo, hi, a, b: f32) -> f32 {
	return a + (v - lo) / max(hi - lo, 1e-4) * (b - a)
}

// cloud_gradient is how dense a cloud type is at a height fraction of the layer, from stratus (0) through cumulus (0.5)
// to cumulonimbus (1), as cloud_gradient in clouds_common.hlsli has it.
cloud_gradient :: proc(hf, type: f32) -> f32 {
	stratus := [4]f32{0, 0.1, 0.2, 0.3}
	cumulus := [4]f32{0, 0.2, 0.4, 0.6}
	cumulonimbus := [4]f32{0, 0.1, 0.7, 1.0}
	k := type < 0.5 ? stratus + (cumulus - stratus) * (type * 2) : cumulus + (cumulonimbus - cumulus) * ((type - 0.5) * 2)
	return clamp(cloud_remap(hf, k.x, k.y, 0, 1), 0, 1) * clamp(cloud_remap(hf, k.z, k.w, 1, 0), 0, 1)
}

// cloud_far is how far a distance is into the far clouds, from 0 at far_distance to 1 at twice it, where the authored
// weather has blended over to a cumulus at far_coverage: cloud_far_coverage gives the coverage there.
cloud_far :: proc(t, far_distance: f32) -> f32 {
	return clamp((t - far_distance) / max(far_distance, 1), 0, 1)
}

cloud_far_coverage :: proc(coverage, far_coverage, far: f32) -> f32 {
	return math.lerp(coverage, far_coverage, far)
}

// cloud_shadow_center is the shadow map's center relative to the camera: where the sun's rays through the camera meet
// the layer's bottom, which is bottom_rel below or above the camera, snapped to a texel in the render origin's space,
// whose offset from the camera is camera_offset, so the map does not swim as the camera moves.
cloud_shadow_center :: proc(to_sun: [3]f32, bottom_rel: f32, camera_offset: [2]f32, size: u32) -> [2]f32 {
	center := to_sun.xz * (bottom_rel / max(to_sun.y, 0.05))
	texel := f32(CLOUD_SHADOW_EXTENT) / f32(max(size, 1))
	origin := center + camera_offset
	snapped := [2]f32{math.floor(origin.x / texel + 0.5) * texel, math.floor(origin.y / texel + 0.5) * texel}
	return snapped - camera_offset
}

// cloud_shadow_uv is where a point relative to the camera reads the shadow map, along the direction toward the sun,
// as cloud_shadow in cloud_shadow.hlsli finds it, and whether it is inside the map.
cloud_shadow_uv :: proc(p, to_sun: [3]f32, bottom_rel: f32, center: [2]f32, extent: f32) -> (uv: [2]f32, inside: bool) {
	if to_sun.y <= 0.05 {
		return
	}
	q := p + to_sun * ((bottom_rel - p.y) / to_sun.y)
	uv = (q.xz - center) / extent + 0.5
	return uv, uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1
}

// begin_clouds readies the frame's clouds, from the Clouds settings at the camera, after begin_sky, whose settings and
// ambient light it takes and whose sun's light it flags, and before the lights are uploaded and the scene's constants
// are written, which take the shadow map. Frame.clouds stays nil, and nothing logs, when the clouds are off or have no
// density, when no sky draws, when a pipeline is not ready, or when the history cannot be made.
@(private)
begin_clouds :: proc(f: ^Frame, s: Cloud_Settings, sky: Sky_Settings, ambient: Ambient) {
	r := f.renderer
	v := &r.clouds
	platform := r.platform
	// An extra view has no history, and bakes no noise.
	if f.extra || s.off || s.density <= 0 || !sky_draws(f) {
		return
	}
	for p in ([]^Shader_Pipeline{&v.noise, &v.shadow, &v.march, &v.temporal, &v.composite}) {
		if !pipeline_ready(platform, p) {
			return
		}
	}
	if !ensure_cloud_noise(r) {
		return
	}
	upload, ok := platform.gpu_upload(size_of(Cloud_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	params := CLOUD_PARAMS[s.level]
	size := (f.size + params.divisor - 1) / params.divisor
	g := f.graph
	history := history_texture(g, {size = size, format = CLOUD_FORMAT, label = "clouds history"})
	if history.current == 0 {
		return
	}
	v.frame += 1

	// The wind carries the weather and the shapes between frames, by the platform's clock.
	now := platform.time_seconds != nil ? platform.time_seconds() : 0
	wind := wind_vector(s.wind_speed, s.wind_direction)
	if v.wind_time != 0 {
		elapsed := clamp(now - v.wind_time, 0, 0.1)
		v.wind_offset += {f64(wind.x) * elapsed, f64(wind.y) * elapsed}
	}
	v.wind_time = now
	camera := ecs.position_to_meters(f.view.position)
	origin := ecs.position_to_meters(s.weather_origin)
	// The lookups add the offsets to a point relative to the camera, so a feature that the wind has carried along it
	// is found by taking the carry away.
	total := [2]f64{camera.x - origin.x - v.wind_offset.x, camera.z - origin.z - v.wind_offset.y}
	weather_offset, noise_offset := cloud_offsets(total, s.weather_size)

	// Heights above the atmosphere's ground, which Sky_Settings has in every mode.
	a := sky.atmosphere
	camera_height := f32(max(f64(a.altitude) * 1000 + camera.y, 1))
	planet_radius := a.bottom * 1000

	// The sun: a linked light's record, the sky's own sun in an Atmosphere, or the first directional light under a
	// texture sky. In an Atmosphere its light is tinted by the air above the layer, from the untinted illuminance.
	cf := new(Cloud_Frame, platform.frame_allocator)
	cf.settings, cf.params, cf.size, cf.history, cf.upload = s, params, size, history, upload
	cf.bake_noise = v.noise_state == .Pending
	sun := false
	shadow_record := -1
	sun_direction, base: [3]f32
	lf := f.lights
	if lf != nil && sky.sun != 0 {
		for e, i in lf.directional[:lf.directional_count] {
			if e != sky.sun {
				continue
			}
			record := &lf.records[i]
			sun, shadow_record = true, i
			sun_direction = -record.direction
			base = f.sky != nil ? f.sky.constants.sun_illuminance.rgb : record.color
			break
		}
	}
	if !sun {
		if f.sky != nil {
			sun, sun_direction, base = true, linalg.normalize0(sky.sun_direction), sky.sun_illuminance
		} else if lf != nil && lf.directional_count > 0 {
			record := &lf.records[0]
			sun, shadow_record = true, 0
			sun_direction, base = -record.direction, record.color
		}
	}
	sun_illuminance, cirrus_illuminance := base, base
	if sun && f.sky != nil {
		tint :: proc(a: Atmosphere_Params, height_m: f32, direction: [3]f32) -> [3]f32 {
			return sky_transmittance(a, clamp(height_m / 1000, 0.001, a.top - a.bottom - 0.001), direction)
		}
		sun_illuminance = base * tint(a, (s.bottom + s.top) * 0.5, sun_direction)
		cirrus_illuminance = base * tint(a, s.cirrus_height, sun_direction)
	}
	if shadow_record >= 0 {
		lf.records[shadow_record].flags += {.Cloud_Shadow}
	}
	cf.sun = sun

	// The weather map, when it is resident; the scalars until then.
	if s.weather == .Map && s.weather_map != {} {
		if t, ready := resident_texture(&r.residency, s.weather_map); ready {
			cf.weather = t.texture
		}
	}

	// The shadow map, only for a light's record, which reads it: centered where the sun's rays through the camera meet
	// the layer's bottom.
	bottom_rel := s.bottom - camera_height
	camera_offset := ecs.position_sub(f.view.position, r.scene.origin)
	center := cloud_shadow_center(sun_direction, bottom_rel, camera_offset.xz, params.shadow_size)
	if shadow_record >= 0 && ensure_cloud_shadow_map(r, params.shadow_size) {
		cf.shadow = import_texture(g, v.shadow_map, .Storage)
		cf.shadow_fade = clamp((sun_direction.y - 0.05) / 0.1, 0, 1)
	}

	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	noise := blue_noise(r)
	cf.constants = {
		right              = {right.x, right.y, right.z, scale.x},
		up                 = {up.x, up.y, up.z, scale.y},
		forward            = {forward.x, forward.y, forward.z, 0},
		sun_direction      = {sun_direction.x, sun_direction.y, sun_direction.z, sun ? 1 : 0},
		sun_illuminance    = {sun_illuminance.r, sun_illuminance.g, sun_illuminance.b, 0},
		cirrus_illuminance = {cirrus_illuminance.r, cirrus_illuminance.g, cirrus_illuminance.b, 0},
		ambient            = ambient_constants(scale_ambient(ambient, s.ambient_intensity)),
		camera_height      = camera_height,
		bottom             = s.bottom,
		top                = s.top,
		cirrus_height      = s.cirrus_height,
		planet_radius      = planet_radius,
		inv_weather_size   = 1 / s.weather_size,
		far_distance       = s.far_distance,
		far_coverage       = s.far_coverage,
		weather_offset     = weather_offset,
		noise_offset       = noise_offset,
		wind_direction     = {math.sin(math.to_radians(s.wind_direction)), math.cos(math.to_radians(s.wind_direction))},
		screen_size        = {f32(f.size.x), f32(f.size.y)},
		coverage           = s.coverage,
		precipitation      = s.precipitation,
		cloud_type         = s.cloud_type,
		cirrus             = s.cirrus,
		density            = s.density,
		history_blend      = 1 / max(params.history_frames, 1),
		shadow_extent      = CLOUD_SHADOW_EXTENT,
		near               = f.view.near,
		shadow_center      = center,
		shadow_size        = params.shadow_size,
		shadow_steps       = params.shadow_steps,
		steps              = params.steps,
		light_steps        = params.light_steps,
		divisor            = params.divisor,
		frame              = v.frame,
		size               = size,
		use_map            = u32(cf.weather != {}),
		shape              = gpu.read_index(v.shape),
		detail             = gpu.read_index(v.detail),
		curl               = gpu.read_index(v.curl),
		noise_sampler      = gpu.sampler_index(v.noise_sampler),
		weather            = cf.weather != {} ? gpu.read_index(cf.weather) : 0,
		blue_noise         = noise != {} ? gpu.read_index(noise) : 0,
		clamp_sampler      = gpu.sampler_index(r.post.sampler),
		cirrus_offset      = cirrus_offset(total, s.wind_direction),
		base_variation     = s.base_variation,
	}
	(^Cloud_Constants)(raw_data(upload.data))^ = cf.constants
	f.clouds = cf
}

// cloud_shadow_constants gives a view's Frame_Constants the shadow map, which every pass with the light loop reads
// through cloud_shadow.hlsli. A frame without a light that casts it has none.
@(private)
cloud_shadow_constants :: proc(c: ^Frame_Constants, f: ^Frame) {
	cf := f.clouds
	if cf == nil || cf.shadow == 0 {
		return
	}
	r := f.renderer
	c.cloud_shadow = gpu.read_index(r.clouds.shadow_map)
	c.cloud_shadow_sampler = gpu.sampler_index(r.post.sampler)
	c.cloud_shadow_strength = cf.settings.shadow_strength
	c.cloud_shadow_bottom = cf.constants.bottom - cf.constants.camera_height
	c.cloud_shadow_fade = cf.shadow_fade
	c.cloud_shadow_center = cf.constants.shadow_center
	c.cloud_shadow_inv_extent = 1.0 / CLOUD_SHADOW_EXTENT
	c.cloud_shadow_top = cf.constants.top - cf.constants.camera_height
}

// declare_cloud_shadow declares that a pass reads the cloud shadow map, which it does through the light loop
// (cloud_shadow.hlsli): the forward passes of the opaque, the transparent and the sorted surfaces and the sprites
// (declare_lighting), the fog's injection (add_fog_passes), the global illumination's hit light (add_hit_light_passes),
// the voxel cones' injection (add_gi_voxel_passes) and the traced reflections' light pass
// (add_traced_reflection_passes). A reflection probe's faces have no shadow map in their constants, so they do not.
@(private)
declare_cloud_shadow :: proc(f: ^Frame, p: Pass) {
	if cf := f.clouds; cf != nil && cf.shadow != 0 {
		read(f.graph, p, cf.shadow)
	}
}

// add_cloud_shadow_passes adds the noise pass, in a frame that bakes the noise, and the shadow map's pass, after the
// prepass and before the passes that light the world, which read the map. It also gives the constants last frame's
// projection, which the scene's constants have set by now.
@(private)
add_cloud_shadow_passes :: proc(f: ^Frame) {
	cf := f.clouds
	if cf == nil {
		return
	}
	g := f.graph
	v := &f.renderer.clouds
	cf.constants.previous = f.previous_view_projection * linalg.matrix4_translate_f32(f.camera_motion)
	(^Cloud_Constants)(raw_data(cf.upload.data)).previous = cf.constants.previous
	cf.shape = import_texture(g, v.shape, .Storage)
	cf.detail = import_texture(g, v.detail, .Storage)
	cf.curl = import_texture(g, v.curl, .Storage)
	if cf.bake_noise {
		p := add_compute_pass(g, "clouds noise", run_cloud_noise, f, queue = .Compute)
		write(g, p, cf.shape)
		write(g, p, cf.detail)
		write(g, p, cf.curl)
		on_executed(g, commit_cloud_noise, f)
	}
	if cf.shadow != 0 {
		p := add_compute_pass(g, "clouds shadow", run_cloud_shadow, f, queue = .Compute)
		read(g, p, cf.shape)
		write(g, p, cf.shadow)
	}
}

// commit_cloud_noise marks the noise textures made, once the frame that baked them has executed.
@(private = "file")
commit_cloud_noise :: proc(data: rawptr) {
	f := (^Frame)(data)
	f.renderer.clouds.noise_state = .Ready
}

// add_cloud_passes adds the march and the temporal pass, after the shadow maps and before the fog, whose results the
// composite reads.
@(private)
add_cloud_passes :: proc(f: ^Frame) {
	cf := f.clouds
	if cf == nil {
		return
	}
	g := f.graph
	cf.current = create_texture(g, {size = cf.size, format = CLOUD_FORMAT, label = "clouds current"})
	cf.distance = create_texture(g, {size = cf.size, format = CLOUD_DISTANCE_FORMAT, label = "clouds distance"})
	p := add_compute_pass(g, "clouds march", run_cloud_march, f, queue = .Compute)
	read(g, p, f.depth)
	read(g, p, cf.shape)
	read(g, p, cf.detail)
	read(g, p, cf.curl)
	write(g, p, cf.current)
	write(g, p, cf.distance)

	p = add_compute_pass(g, "clouds temporal", run_cloud_temporal, f, queue = .Compute)
	read(g, p, cf.current)
	read(g, p, cf.distance)
	read(g, p, cf.history.previous)
	write(g, p, cf.history.current)
}

// add_cloud_composite adds the pass that draws the clouds over the sky after the world pass, where the sky drew, before
// the fog over the background dims them with it.
@(private)
add_cloud_composite :: proc(f: ^Frame) {
	cf := f.clouds
	if cf == nil {
		return
	}
	g := f.graph
	cf.scene = f.scene
	p := add_compute_pass(g, "clouds composite", run_cloud_composite, f)
	read(g, p, f.depth)
	read(g, p, cf.history.current)
	read(g, p, cf.distance)
	read(g, p, f.exposure)
	write(g, p, f.scene)
}

@(private = "file")
run_cloud_noise :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.clouds
	g := ctx.graph
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.clouds.noise.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, cf.upload)
	targets := [3]Texture{cf.shape, cf.detail, cf.curl}
	dispatches := [3][3]u32 {
		{CLOUD_SHAPE_SIZE / CLOUD_GROUP_SIZE, CLOUD_SHAPE_SIZE / CLOUD_GROUP_SIZE, CLOUD_SHAPE_SIZE / CLOUD_GROUP_SIZE},
		{CLOUD_DETAIL_SIZE / CLOUD_GROUP_SIZE, CLOUD_DETAIL_SIZE / CLOUD_GROUP_SIZE, CLOUD_DETAIL_SIZE / CLOUD_GROUP_SIZE},
		{CLOUD_CURL_SIZE / CLOUD_GROUP_SIZE, CLOUD_CURL_SIZE / CLOUD_GROUP_SIZE, 1},
	}
	for target, kind in targets {
		push := Cloud_Push {
			output = gpu.write_index(gpu_texture(g, target)),
			kind   = u32(kind),
		}
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch(ctx.cb, dispatches[kind])
	}
}

@(private = "file")
run_cloud_shadow :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.clouds
	push := Cloud_Push {
		output = gpu.write_index(gpu_texture(ctx.graph, cf.shadow)),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.clouds.shadow.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, cf.upload)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups({cf.params.shadow_size, cf.params.shadow_size}, CLOUD_GROUP_SIZE))
}

@(private = "file")
run_cloud_march :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.clouds
	g := ctx.graph
	push := Cloud_Push {
		depth    = gpu.read_index(gpu_texture(g, f.depth)),
		current  = gpu.write_index(gpu_texture(g, cf.current)),
		distance = gpu.write_index(gpu_texture(g, cf.distance)),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.clouds.march.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, cf.upload)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(cf.size, CLOUD_GROUP_SIZE))
}

@(private = "file")
run_cloud_temporal :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.clouds
	g := ctx.graph
	push := Cloud_Push {
		current  = gpu.read_index(gpu_texture(g, cf.current)),
		distance = gpu.read_index(gpu_texture(g, cf.distance)),
		history  = gpu.read_index(gpu_texture(g, cf.history.previous)),
		output   = gpu.write_index(gpu_texture(g, cf.history.current)),
		valid    = u32(cf.history.valid),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.clouds.temporal.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, cf.upload)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(cf.size, CLOUD_GROUP_SIZE))
}

@(private = "file")
run_cloud_composite :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.clouds
	g := ctx.graph
	push := Cloud_Push {
		depth    = gpu.read_index(gpu_texture(g, f.depth)),
		history  = gpu.read_index(gpu_texture(g, cf.history.current)),
		distance = gpu.read_index(gpu_texture(g, cf.distance)),
		output   = gpu.write_index(gpu_texture(g, cf.scene)),
		exposure = gpu.read_index(gpu_buffer(g, f.exposure)),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.clouds.composite.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, cf.upload)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, CLOUD_GROUP_SIZE))
}

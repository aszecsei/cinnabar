package render

import "core:math"
import "core:math/linalg"

import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The sky (see docs/rendering/sky.md#sky): with an Environment of Atmosphere, compute passes make Hillaire's lookup
// tables each frame, the transmittance to the top of the atmosphere, the light of multiple scattering, and the sky in
// every direction from the camera, and a pass after the world pass draws the sky, the sun, the moon and the stars
// where nothing drew. The ambient light is the same model's, which the CPU integrates, and the sun's light is dimmed
// and colored by the air between it and the camera.

// The engine's sky shaders, by their .meta files.
SKY_TRANSMITTANCE_SHADER :: #load("../content/shaders/sky_transmittance.hlsl.meta", string)
SKY_MULTISCATTER_SHADER :: #load("../content/shaders/sky_multiscatter.hlsl.meta", string)
SKY_VIEW_SHADER :: #load("../content/shaders/sky_view.hlsl.meta", string)
SKY_BACKGROUND_SHADER :: #load("../content/shaders/sky.hlsl.meta", string)

// The lookup tables' sizes, which match sky_common.hlsli.
SKY_TRANSMITTANCE_SIZE :: [2]u32{256, 64}
SKY_MULTISCATTER_SIZE :: [2]u32{32, 32}
SKY_VIEW_SIZE :: [2]u32{256, 128}
SKY_FORMAT :: gpu.Format.RGBA16_Float
SKY_GROUP_SIZE :: 8

// The sun's and the moon's angular diameters, in degrees, as they are seen from Earth.
DEFAULT_SUN_DISC :: 0.53
DEFAULT_MOON_DISC :: 0.52

// Ozone is a layer around OZONE_CENTER kilometers up, whose density falls to 0 at OZONE_HALF_WIDTH from it. Matches
// sky_common.hlsli.
OZONE_CENTER :: 25
OZONE_HALF_WIDTH :: 15

// The CPU's ambient light takes the sky in this many directions, with this many steps along each and toward each
// light.
@(private = "file")
AMBIENT_DIRECTIONS :: 64
@(private = "file")
AMBIENT_STEPS :: 12
@(private = "file")
AMBIENT_LIGHT_STEPS :: 12
// The CPU has no multiple scattering table: it adds this share of the light that each point scatters, in every
// direction alike, which stands for the light scattered more than once.
@(private = "file")
AMBIENT_MULTISCATTER :: 1

// Atmosphere_Params are an Atmosphere in the units of the model: coefficients per kilometer, and the planet's and the
// atmosphere's radii.
Atmosphere_Params :: struct {
	rayleigh_scattering: [3]f32,
	rayleigh_height:     f32,
	mie_scattering:      f32,
	mie_absorption:      f32,
	mie_anisotropy:      f32,
	mie_height:          f32,
	ozone_absorption:    [3]f32,
	ground_albedo:       [3]f32,
	bottom:              f32,
	top:                 f32,
	altitude:            f32,
}

// Sky_Settings are a frame's Environment, from the volumes at the camera. Directions point toward the sun or the moon,
// and the discs' sizes are angular radii in radians.
Sky_Settings :: struct {
	mode:              Sky_Mode,
	background:        [3]f32,
	sky:               [3]f32,
	ground:            [3]f32,
	ambient_intensity: f32,
	// A linked sun's light replaces the direction and the illuminance.
	sun:               ecs.Entity,
	sun_direction:     [3]f32,
	sun_illuminance:   [3]f32,
	sun_radius:        f32,
	atmosphere:        Atmosphere_Params,
	moon_direction:    [3]f32,
	// The full moon's, colored.
	moon_illuminance:  [3]f32,
	moon_radius:       f32,
	star_intensity:    f32,
	star_density:      f32,
	// Texture's sky, and its rotation in degrees.
	texture:           format.Guid,
	texture_intensity: f32,
	texture_rotation:  f32,
}

// Sky is the sky's state between frames, in the Renderer.
Sky :: struct {
	transmittance: Shader_Pipeline,
	multiscatter:  Shader_Pipeline,
	view:          Shader_Pipeline,
	background:    Shader_Pipeline,
	// The last ambient light, and what it came from, since the sky seldom changes between frames.
	ambient_key:   Sky_Light_Key,
	ambient:       Ambient,
	ambient_valid: bool,
	// The Texture mode's (see sky_texture.odin).
	texture:       Sky_Texture_State,
}

// Sky_Light_Key is what the ambient light of an Atmosphere depends on.
@(private)
Sky_Light_Key :: struct {
	atmosphere:       Atmosphere_Params,
	height:           f32,
	sun_direction:    [3]f32,
	sun_illuminance:  [3]f32,
	moon_direction:   [3]f32,
	moon_illuminance: [3]f32,
}

// Sky_Constants matches Sky_Constants in sky_common.hlsli: every sky pass's constants. right and up have the
// projection's scales in w. The discs' directions have the cosines of their radii in w, and their illuminances the
// radii. heights has the camera's height above the ground, the atmosphere's height, and the planet's radius.
@(private = "file")
Sky_Constants :: struct {
	right:            [4]f32,
	up:               [4]f32,
	forward:          [4]f32,
	sun_direction:    [4]f32,
	sun_illuminance:  [4]f32,
	moon_direction:   [4]f32,
	moon_illuminance: [4]f32,
	// The moon's light on the sky, at its phase.
	moon_light:       [4]f32,
	// Rayleigh's coefficients and height; Mie's scattering, absorption, anisotropy and height; ozone's coefficients.
	rayleigh:         [4]f32,
	mie:              [4]f32,
	ozone:            [4]f32,
	// The ground's albedo, and the stars' intensity in w.
	ground_albedo:    [4]f32,
	heights:          [4]f32,
	// The stars' density, and the frame's size.
	star_density:     f32,
	padding:          u32,
	size:             [2]u32,
}

// Sky_Push matches Sky_Push in sky_common.hlsli: the textures of one sky pass.
@(private = "file")
Sky_Push :: struct {
	transmittance: u32,
	multiscatter:  u32,
	view:          u32,
	output:        u32,
	depth:         u32,
	exposure:      u32,
	sampler_index: u32,
	padding:       u32,
}

// Sky_Frame is what one frame's sky passes need, in frame memory.
@(private)
Sky_Frame :: struct {
	constants:     Sky_Constants,
	upload:        gpu.Upload,
	transmittance: Texture,
	multiscatter:  Texture,
	view:          Texture,
	// The scene that the background pass draws into: later passes replace Frame.scene before the passes record.
	scene:         Texture,
}

sky_init :: proc(s: ^Sky) {
	s.transmittance = shader_pipeline(SKY_TRANSMITTANCE_SHADER)
	s.multiscatter = shader_pipeline(SKY_MULTISCATTER_SHADER)
	s.view = shader_pipeline(SKY_VIEW_SHADER)
	s.background = shader_pipeline(SKY_BACKGROUND_SHADER)
	sky_texture_init(&s.texture)
}

sky_destroy :: proc(s: ^Sky, r: ^Renderer) {
	for p in ([]^Shader_Pipeline{&s.transmittance, &s.multiscatter, &s.view, &s.background}) {
		destroy_shader_pipeline(p, r.platform)
	}
	sky_texture_destroy(&s.texture, r)
}

@(private)
sync_sky_pipelines :: proc(r: ^Renderer, force: bool) {
	s := &r.sky
	assets := r.residency.assets
	sync_compute_pipeline(&s.transmittance, r.platform, assets, {label = "sky transmittance"}, force)
	sync_compute_pipeline(&s.multiscatter, r.platform, assets, {label = "sky multiscatter"}, force)
	sync_compute_pipeline(&s.view, r.platform, assets, {label = "sky view"}, force)
	sync_compute_pipeline(&s.background, r.platform, assets, {label = "sky"}, force)
	sync_sky_texture_pipelines(r, force)
}

// sky_settings takes the Sky_Settings from a blended Environment.
@(private)
sky_settings :: proc(env: Environment) -> Sky_Settings {
	a := env.atmosphere
	n := env.night
	bottom := max(a.planet_radius.value, 1)
	return {
		mode = env.mode.value,
		background = env.background.value,
		sky = env.sky.value,
		ground = env.ground.value,
		ambient_intensity = env.ambient_intensity.value,
		sun = env.sun.value,
		sun_direction = sky_direction(env.sun_azimuth.value, env.sun_elevation.value),
		sun_illuminance = env.sun_illuminance.value,
		sun_radius = math.to_radians(env.sun_disc_size.value) * 0.5,
		atmosphere = {
			rayleigh_scattering = a.rayleigh_scattering.value * 1e-3,
			rayleigh_height = max(a.rayleigh_height.value, 0.01),
			mie_scattering = a.mie_scattering.value * 1e-3,
			mie_absorption = a.mie_absorption.value * 1e-3,
			mie_anisotropy = clamp(a.mie_anisotropy.value, 0, 0.99),
			mie_height = max(a.mie_height.value, 0.01),
			ozone_absorption = a.ozone_absorption.value * 1e-3,
			ground_albedo = a.ground_albedo.value,
			bottom = bottom,
			top = bottom + max(a.atmosphere_height.value, 0.1),
			altitude = a.altitude.value,
		},
		moon_direction = sky_direction(n.moon_azimuth.value, n.moon_elevation.value),
		moon_illuminance = n.moon_color.value * n.moon_illuminance.value,
		moon_radius = math.to_radians(n.moon_disc_size.value) * 0.5,
		star_intensity = n.star_intensity.value,
		star_density = clamp(n.star_density.value, 0, 1),
		texture = env.texture.value,
		texture_intensity = max(env.texture_intensity.value, 0),
		texture_rotation = env.texture_rotation.value,
	}
}

// sky_direction is the direction toward an azimuth from +z toward +x and an elevation above the horizon, in degrees.
sky_direction :: proc(azimuth, elevation: f32) -> [3]f32 {
	az, el := math.to_radians(azimuth), math.to_radians(elevation)
	return {math.cos(el) * math.sin(az), math.sin(el), math.cos(el) * math.cos(az)}
}

// begin_sky readies the frame's sky, after the lights are extracted and before they are uploaded, and gives the frame's
// ambient light. With Atmosphere, it tints a linked sun's light by the air that it crosses to reach the camera.
// Without Atmosphere or its pipelines, Frame.sky stays nil and the world pass clears to the background color. Texture
// is begin_sky_texture's.
@(private)
begin_sky :: proc(f: ^Frame, s: Sky_Settings) -> Ambient {
	switch s.mode {
	case .Flat:
		return scale_ambient(flat_ambient(s.sky, s.ground), s.ambient_intensity)
	case .Texture:
		return begin_sky_texture(f, s)
	case .Atmosphere:
	}
	r := f.renderer
	a := s.atmosphere
	height := clamp(a.altitude + f32(ecs.position_to_meters(f.view.position).y / 1000), 0.001, a.top - a.bottom - 0.001)
	sun_direction, sun_illuminance := linalg.normalize0(s.sun_direction), s.sun_illuminance
	if s.sun != 0 && f.lights != nil {
		lf := f.lights
		for e, i in lf.directional[:lf.directional_count] {
			if e != s.sun {
				continue
			}
			record := &lf.records[i]
			sun_direction, sun_illuminance = -record.direction, record.color
			record.color *= sky_transmittance(a, height, sun_direction)
			break
		}
	}
	// The moon is lit as much as the sun reaches the face that it turns to the camera.
	moon_direction := linalg.normalize0(s.moon_direction)
	phase := (1 - linalg.dot(sun_direction, moon_direction)) * 0.5
	moon_light := s.moon_illuminance * phase

	key := Sky_Light_Key{a, height, sun_direction, sun_illuminance, moon_direction, moon_light}
	if !r.sky.ambient_valid || r.sky.ambient_key != key {
		r.sky.ambient = sky_ambient(a, height, {{sun_direction, sun_illuminance}, {moon_direction, moon_light}})
		r.sky.ambient_key, r.sky.ambient_valid = key, true
	}
	ambient := scale_ambient(r.sky.ambient, s.ambient_intensity)

	platform := r.platform
	for p in ([]^Shader_Pipeline{&r.sky.transmittance, &r.sky.multiscatter, &r.sky.view, &r.sky.background}) {
		if !pipeline_ready(platform, p) {
			return ambient
		}
	}
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	sf := new(Sky_Frame, platform.frame_allocator)
	sf.constants = {
		right            = {right.x, right.y, right.z, scale.x},
		up               = {up.x, up.y, up.z, scale.y},
		forward          = {forward.x, forward.y, forward.z, 0},
		sun_direction    = {sun_direction.x, sun_direction.y, sun_direction.z, math.cos(s.sun_radius)},
		sun_illuminance  = {sun_illuminance.r, sun_illuminance.g, sun_illuminance.b, s.sun_radius},
		moon_direction   = {moon_direction.x, moon_direction.y, moon_direction.z, math.cos(s.moon_radius)},
		moon_illuminance = {s.moon_illuminance.r, s.moon_illuminance.g, s.moon_illuminance.b, s.moon_radius},
		moon_light       = {moon_light.r, moon_light.g, moon_light.b, 0},
		rayleigh         = {a.rayleigh_scattering.r, a.rayleigh_scattering.g, a.rayleigh_scattering.b, a.rayleigh_height},
		mie              = {a.mie_scattering, a.mie_absorption, a.mie_anisotropy, a.mie_height},
		ozone            = {a.ozone_absorption.r, a.ozone_absorption.g, a.ozone_absorption.b, 0},
		ground_albedo    = {a.ground_albedo.r, a.ground_albedo.g, a.ground_albedo.b, s.star_intensity},
		heights          = {height, a.top - a.bottom, a.bottom, 0},
		star_density     = s.star_density,
		size             = f.size,
	}
	upload, ok := platform.gpu_upload(size_of(Sky_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return ambient
	}
	(^Sky_Constants)(raw_data(upload.data))^ = sf.constants
	sf.upload = upload
	f.sky = sf
	return ambient
}

// add_sky_passes adds the lookup tables' passes, which only the background pass reads.
@(private)
add_sky_passes :: proc(f: ^Frame) {
	sf := f.sky
	if sf == nil {
		return
	}
	g := f.graph
	sf.transmittance = create_texture(g, {size = SKY_TRANSMITTANCE_SIZE, format = SKY_FORMAT, label = "sky transmittance"})
	sf.multiscatter = create_texture(g, {size = SKY_MULTISCATTER_SIZE, format = SKY_FORMAT, label = "sky multiscatter"})
	sf.view = create_texture(g, {size = SKY_VIEW_SIZE, format = SKY_FORMAT, label = "sky view"})
	p := add_compute_pass(g, "sky transmittance", run_sky_transmittance, f)
	write(g, p, sf.transmittance)
	p = add_compute_pass(g, "sky multiscatter", run_sky_multiscatter, f)
	read(g, p, sf.transmittance)
	write(g, p, sf.multiscatter)
	p = add_compute_pass(g, "sky view", run_sky_view, f)
	read(g, p, sf.transmittance)
	read(g, p, sf.multiscatter)
	write(g, p, sf.view)
}

// add_sky_background adds the pass that draws the sky after the world pass, where nothing drew, before the fog covers
// it.
@(private)
add_sky_background :: proc(f: ^Frame) {
	sf := f.sky
	if sf == nil {
		return
	}
	g := f.graph
	sf.scene = f.scene
	p := add_compute_pass(g, "sky", run_sky_background, f)
	read(g, p, sf.transmittance)
	read(g, p, sf.view)
	read(g, p, f.depth)
	read(g, p, f.exposure)
	write(g, p, f.scene)
}

@(private = "file")
sky_push :: proc(ctx: ^Pass_Context, f: ^Frame) -> Sky_Push {
	gpu.cmd_set_pass_constants(ctx.cb, f.sky.upload)
	return {sampler_index = gpu.sampler_index(f.renderer.post.sampler)}
}

@(private = "file")
run_sky_transmittance :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	push := sky_push(ctx, f)
	push.output = gpu.write_index(gpu_texture(ctx.graph, f.sky.transmittance))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sky.transmittance.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(SKY_TRANSMITTANCE_SIZE, SKY_GROUP_SIZE))
}

@(private = "file")
run_sky_multiscatter :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := sky_push(ctx, f)
	push.transmittance = gpu.read_index(gpu_texture(g, f.sky.transmittance))
	push.output = gpu.write_index(gpu_texture(g, f.sky.multiscatter))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sky.multiscatter.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(SKY_MULTISCATTER_SIZE, SKY_GROUP_SIZE))
}

@(private = "file")
run_sky_view :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := sky_push(ctx, f)
	push.transmittance = gpu.read_index(gpu_texture(g, f.sky.transmittance))
	push.multiscatter = gpu.read_index(gpu_texture(g, f.sky.multiscatter))
	push.output = gpu.write_index(gpu_texture(g, f.sky.view))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sky.view.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(SKY_VIEW_SIZE, SKY_GROUP_SIZE))
}

@(private = "file")
run_sky_background :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := sky_push(ctx, f)
	push.transmittance = gpu.read_index(gpu_texture(g, f.sky.transmittance))
	push.view = gpu.read_index(gpu_texture(g, f.sky.view))
	push.depth = gpu.read_index(gpu_texture(g, f.depth))
	push.exposure = gpu.read_index(gpu_buffer(g, f.exposure))
	push.output = gpu.write_index(gpu_texture(g, f.sky.scene))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sky.background.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, SKY_GROUP_SIZE))
}

@(private)
scale_ambient :: proc(a: Ambient, scale: f32) -> Ambient {
	return {constant = a.constant * scale, x = a.x * scale, y = a.y * scale, z = a.z * scale}
}

// Sky_Light is a light that the atmosphere scatters: the direction toward it and its illuminance.
@(private)
Sky_Light :: struct {
	direction:   [3]f32,
	illuminance: [3]f32,
}

// The model on the CPU, in f64, which needs none of the care that the shaders take with the planet's large radius.
// Points are relative to the planet's center, with y up.

@(private = "file")
Medium :: struct {
	rayleigh:   [3]f64,
	mie:        f64,
	extinction: [3]f64,
}

@(private = "file")
medium_at :: proc(a: Atmosphere_Params, height: f64) -> Medium {
	rayleigh := math.exp(-height / f64(a.rayleigh_height))
	mie := math.exp(-height / f64(a.mie_height))
	ozone := max(0, 1 - abs(height - OZONE_CENTER) / OZONE_HALF_WIDTH)
	m := Medium {
		rayleigh = to_f64(a.rayleigh_scattering) * rayleigh,
		mie      = f64(a.mie_scattering) * mie,
	}
	m.extinction = m.rayleigh + f64(a.mie_scattering + a.mie_absorption) * mie + to_f64(a.ozone_absorption) * ozone
	return m
}

@(private = "file")
to_f64 :: proc(v: [3]f32) -> [3]f64 {
	return {f64(v.x), f64(v.y), f64(v.z)}
}

// ray_exit is the distance along a ray from inside a sphere around the center to where it leaves it.
@(private = "file")
ray_exit :: proc(origin, direction: [3]f64, radius: f64) -> f64 {
	b := linalg.dot(origin, direction)
	c := linalg.dot(origin, origin) - radius * radius
	return -b + math.sqrt(max(b * b - c, 0))
}

// ray_ground is the distance along a ray from above the ground to where it meets it, or -1 if it does not.
@(private = "file")
ray_ground :: proc(origin, direction: [3]f64, radius: f64) -> f64 {
	b := linalg.dot(origin, direction)
	c := linalg.dot(origin, origin) - radius * radius
	h := b * b - c
	if h < 0 || b > 0 {
		return -1
	}
	return -b - math.sqrt(h)
}

@(private = "file")
transmittance_from :: proc(a: Atmosphere_Params, origin, direction: [3]f64, steps: int) -> [3]f64 {
	if ray_ground(origin, direction, f64(a.bottom)) >= 0 {
		return 0
	}
	length := ray_exit(origin, direction, f64(a.top))
	dt := length / f64(steps)
	depth: [3]f64
	for i in 0 ..< steps {
		p := origin + direction * ((f64(i) + 0.5) * dt)
		depth += medium_at(a, linalg.length(p) - f64(a.bottom)).extinction * dt
	}
	return {math.exp(-depth.x), math.exp(-depth.y), math.exp(-depth.z)}
}

// sky_transmittance is the share of light that reaches a height above the ground, in kilometers, from a direction,
// such as the sun's: 0 from below the horizon.
sky_transmittance :: proc(a: Atmosphere_Params, height: f32, direction: [3]f32) -> [3]f32 {
	t := transmittance_from(a, {0, f64(a.bottom + height), 0}, to_f64(linalg.normalize0(direction)), 32)
	return {f32(t.x), f32(t.y), f32(t.z)}
}

@(private = "file")
rayleigh_phase :: proc(cos_theta: f64) -> f64 {
	return 3 / (16 * math.PI) * (1 + cos_theta * cos_theta)
}

// mie_phase is Cornette and Shanks's phase function.
@(private = "file")
mie_phase :: proc(cos_theta, g: f64) -> f64 {
	g2 := g * g
	return 3 / (8 * math.PI) * (1 - g2) * (1 + cos_theta * cos_theta) / ((2 + g2) * math.pow(1 + g2 - 2 * g * cos_theta, 1.5))
}

// sky_radiance is the light that reaches the camera from a direction: what the air scatters toward it, and the
// ground's.
@(private = "file")
sky_radiance :: proc(a: Atmosphere_Params, height: f64, direction: [3]f64, lights: []Sky_Light) -> [3]f64 {
	origin := [3]f64{0, f64(a.bottom) + height, 0}
	ground := ray_ground(origin, direction, f64(a.bottom))
	length := ground >= 0 ? ground : ray_exit(origin, direction, f64(a.top))
	dt := length / AMBIENT_STEPS
	g := f64(a.mie_anisotropy)
	result: [3]f64
	transmittance := [3]f64{1, 1, 1}
	for i in 0 ..< AMBIENT_STEPS {
		p := origin + direction * ((f64(i) + 0.5) * dt)
		m := medium_at(a, linalg.length(p) - f64(a.bottom))
		scattered: [3]f64
		for l in lights {
			if l.illuminance == {} {
				continue
			}
			toward := to_f64(l.direction)
			cos_theta := linalg.dot(direction, toward)
			reaching := transmittance_from(a, p, toward, AMBIENT_LIGHT_STEPS) * to_f64(l.illuminance)
			phase := m.rayleigh * rayleigh_phase(cos_theta) + m.mie * mie_phase(cos_theta, g)
			scattered += reaching * (phase + (m.rayleigh + m.mie) * (AMBIENT_MULTISCATTER / (4 * math.PI)))
		}
		step: [3]f64
		for c in 0 ..< 3 {
			step[c] = math.exp(-m.extinction[c] * dt)
			result[c] += transmittance[c] * scattered[c] * (1 - step[c]) / max(m.extinction[c], 1e-9)
		}
		transmittance *= step
	}
	if ground >= 0 {
		p := origin + direction * ground
		normal := linalg.normalize(p)
		lit: [3]f64
		for l in lights {
			toward := to_f64(l.direction)
			lit += transmittance_from(a, p + normal * 1e-3, toward, AMBIENT_LIGHT_STEPS) * to_f64(l.illuminance) * max(linalg.dot(normal, toward), 0)
		}
		result += transmittance * to_f64(a.ground_albedo) * lit / math.PI
	}
	return result
}

// sky_ambient is the ambient light of an atmosphere at a height above the ground, in kilometers: the light that
// reaches a surface from the whole sky, by its normal, over pi. It takes the sky's first spherical harmonics, from
// directions spread evenly over the sphere, and convolves them with the cosine: the constant is the sky's average
// light, and the gradient twice the average of the light times its direction.
sky_ambient :: proc(a: Atmosphere_Params, height: f32, lights: []Sky_Light) -> Ambient {
	golden := math.PI * (3 - math.sqrt(f64(5)))
	gradient: [3][3]f64
	total: [3]f64
	for i in 0 ..< AMBIENT_DIRECTIONS {
		y := 1 - (f64(i) + 0.5) / AMBIENT_DIRECTIONS * 2
		radius := math.sqrt(1 - y * y)
		angle := golden * f64(i)
		d := [3]f64{math.cos(angle) * radius, y, math.sin(angle) * radius}
		light := sky_radiance(a, f64(height), d, lights)
		total += light
		for axis in 0 ..< 3 {
			gradient[axis] += light * d[axis]
		}
	}
	n := f64(AMBIENT_DIRECTIONS)
	to_f32 :: proc(v: [3]f64) -> [3]f32 {
		return {f32(v.x), f32(v.y), f32(v.z)}
	}
	return {
		constant = to_f32(total / n),
		x = to_f32(gradient[0] * (2 / n)),
		y = to_f32(gradient[1] * (2 / n)),
		z = to_f32(gradient[2] * (2 / n)),
	}
}

package render

import "core:math"
import "core:mem"

import "cinnabar:core/gpu"
import format "cinnabar:engine/asset/format"

// The Texture sky (see docs/rendering/sky.md#texture): an hdr texture of the light from every direction,
// equirectangular, which a pass draws where nothing drew, pre-exposed. Its ambient light is the same linear function of
// the direction as the atmosphere's: a pass on the GPU integrates it from a small mip of the texture once for each of
// the texture's versions, the CPU reads it back, and each frame turns it by the rotation and scales it. Until it is
// back, and while the texture is not resident, the ambient light and the background are Flat's.

// The engine's texture sky shaders, by their .meta files.
SKY_TEXTURE_SHADER :: #load("../content/shaders/sky_texture.hlsl.meta", string)
SKY_TEXTURE_AMBIENT_SHADER :: #load("../content/shaders/sky_texture_ambient.hlsl.meta", string)
// The ambient light integrates the largest mip at most this wide, which finds the sun's texel there too. The sun is
// then found in a window around it of the largest mip at most SKY_SUN_WIDTH wide: in a coarser one, the light around
// the sun moves it, by 16 degrees of elevation in Jungle Ruins' sky at 128 texels, and 1 at 1024.
SKY_AMBIENT_WIDTH :: 128
SKY_SUN_WIDTH :: 2048
// The integral's result, which sky_texture_ambient.hlsl writes: the constant and the x, y and z gradients as float4s,
// the sun's direction with its brightest luminance over the average, then the ticket that it was asked for.
SKY_AMBIENT_RESULT_SIZE :: 96
// A texture has a sun when its brightest texel is at least this many times as bright as its average, so an overcast
// sky's brightest cloud is not one.
SKY_SUN_RATIO :: 10
// An integral that has not come back after this many frames is asked for again.
SKY_AMBIENT_RETRY_FRAMES :: 120

// Sky_Texture_Key is the texture that an ambient light was integrated from: a new version streams into a new texture.
@(private)
Sky_Texture_Key :: struct {
	guid:    format.Guid,
	texture: gpu.Texture,
}

// Sky_Texture_State is the Texture sky's state between frames, in Sky.
@(private)
Sky_Texture_State :: struct {
	background: Shader_Pipeline,
	ambient:    Shader_Pipeline,
	// The integral's result, and its copy that the CPU reads.
	result:     gpu.Buffer,
	readback:   gpu.Buffer,
	// The ambient light of key's texture, before its rotation and intensity, and the direction toward its sun, with how
	// much brighter the sun is than the average.
	key:        Sky_Texture_Key,
	light:      Ambient,
	sun:        [3]f32,
	sun_ratio:  f32,
	valid:      bool,
	// The sun in the world, by the rotation of the last frame that drew the texture, and that frame.
	world_sun:  [3]f32,
	sun_frame:  u64,
	// The integral in flight, of pending_key's texture, and its ticket.
	pending:       bool,
	pending_key:   Sky_Texture_Key,
	pending_frame: u64,
	ticket:        u32,
}

// Sky_Texture_Constants matches Sky_Texture_Constants in sky_texture.hlsl. right and up have the projection's scales in
// w. turn has the rotation's cosine and sine, the intensity, and the texture's width in w.
@(private = "file")
Sky_Texture_Constants :: struct {
	right:         [4]f32,
	up:            [4]f32,
	forward:       [4]f32,
	turn:          [4]f32,
	size:          [2]u32,
	texture:       u32,
	sampler_index: u32,
}

// Sky_Texture_Push matches Sky_Texture_Push in sky_texture.hlsli: the frame's textures for the background, or the
// integral's mip, its size and the ticket, and the sun's mip and its size.
@(private = "file")
Sky_Texture_Push :: struct {
	texture:    u32,
	depth:      u32,
	output:     u32,
	exposure:   u32,
	mip:        u32,
	ticket:     u32,
	width:      u32,
	height:     u32,
	sun_mip:    u32,
	sun_width:  u32,
	sun_height: u32,
	padding:    u32,
}

// Sky_Texture_Frame is what one frame's texture sky passes need, in frame memory.
@(private)
Sky_Texture_Frame :: struct {
	texture:   gpu.Texture,
	constants: gpu.Upload,
	// The integral to run this frame, of this mip.
	integrate: bool,
	mip:       u32,
	mip_size:  [2]u32,
	sun_mip:   u32,
	sun_size:  [2]u32,
	ticket:    u32,
	result:    Buffer,
	readback:  Buffer,
	scene:     Texture,
}

@(private)
sky_texture_init :: proc(s: ^Sky_Texture_State) {
	s.background = shader_pipeline(SKY_TEXTURE_SHADER)
	s.ambient = shader_pipeline(SKY_TEXTURE_AMBIENT_SHADER)
}

@(private)
sky_texture_destroy :: proc(s: ^Sky_Texture_State, r: ^Renderer) {
	destroy_shader_pipeline(&s.background, r.platform)
	destroy_shader_pipeline(&s.ambient, r.platform)
	r.platform.gpu_destroy_buffer(s.result)
	r.platform.gpu_destroy_buffer(s.readback)
	s.result, s.readback, s.pending, s.valid = {}, {}, false, false
}

@(private)
sync_sky_texture_pipelines :: proc(r: ^Renderer, force: bool) {
	s := &r.sky.texture
	sync_compute_pipeline(&s.background, r.platform, r.residency.assets, {label = "sky texture"}, force)
	sync_compute_pipeline(&s.ambient, r.platform, r.residency.assets, {label = "sky texture ambient"}, force)
}

// begin_sky_texture readies the frame's texture sky and gives its ambient light: the texture's, turned and scaled,
// once its integral is back, and Flat's until then. It takes the integral's result when it is back, and asks for one
// when the texture has none.
@(private)
begin_sky_texture :: proc(f: ^Frame, settings: Sky_Settings) -> Ambient {
	r := f.renderer
	s := &r.sky.texture
	platform := r.platform
	flat := scale_ambient(flat_ambient(settings.sky, settings.ground), settings.ambient_intensity)
	t, ready := resident_texture(&r.residency, settings.texture)
	if !ready {
		return flat
	}
	key := Sky_Texture_Key{settings.texture, t.texture}
	if s.pending {
		if data, back := platform.gpu_read_buffer(s.readback); back && len(data) >= SKY_AMBIENT_RESULT_SIZE {
			values := mem.slice_data_cast([]f32, data[:SKY_AMBIENT_RESULT_SIZE])
			if transmute(u32)values[20] == s.ticket {
				for v, i in ([]^[3]f32{&s.light.constant, &s.light.x, &s.light.y, &s.light.z}) {
					v^ = {values[i * 4], values[i * 4 + 1], values[i * 4 + 2]}
				}
				s.sun, s.sun_ratio = {values[16], values[17], values[18]}, values[19]
				s.key, s.valid, s.pending = s.pending_key, true, false
			}
		}
		// An integral that never came back, as one whose frame did not run, is asked for again.
		if s.pending && r.scene.frame - s.pending_frame > SKY_AMBIENT_RETRY_FRAMES {
			s.pending = false
		}
	}
	sf := new(Sky_Texture_Frame, platform.frame_allocator)
	sf.texture = t.texture
	if (!s.valid || s.key != key) && !s.pending && pipeline_ready(platform, &s.ambient) && ensure_sky_texture_buffers(r) {
		s.ticket += 1
		s.pending, s.pending_key, s.pending_frame = true, key, r.scene.frame
		mip := u32(0)
		for mip + 1 < t.mip_count && t.size.x >> mip > SKY_AMBIENT_WIDTH {
			mip += 1
		}
		sf.integrate, sf.mip, sf.ticket = true, mip, s.ticket
		sf.mip_size = {max(t.size.x >> mip, 1), max(t.size.y >> mip, 1)}
		sun_mip := u32(0)
		for sun_mip + 1 < t.mip_count && t.size.x >> sun_mip > SKY_SUN_WIDTH {
			sun_mip += 1
		}
		sf.sun_mip, sf.sun_size = sun_mip, {max(t.size.x >> sun_mip, 1), max(t.size.y >> sun_mip, 1)}
	}
	ambient := flat
	if s.valid && s.key == key {
		turn := math.to_radians(settings.texture_rotation)
		ambient = scale_ambient(turn_ambient(s.light, turn), settings.texture_intensity * settings.ambient_intensity)
		s.world_sun, s.sun_frame = turn_direction(s.sun, turn), r.scene.frame
	}

	if pipeline_ready(platform, &s.background) {
		right, up, forward := view_axes(f.view)
		scale := projection_scale(f.view_projection)
		turn := math.to_radians(settings.texture_rotation)
		upload, ok := platform.gpu_upload(size_of(Sky_Texture_Constants), gpu.PASS_CONSTANTS_ALIGN)
		if ok {
			(^Sky_Texture_Constants)(raw_data(upload.data))^ = {
				right         = {right.x, right.y, right.z, scale.x},
				up            = {up.x, up.y, up.z, scale.y},
				forward       = {forward.x, forward.y, forward.z, 0},
				turn          = {math.cos(turn), math.sin(turn), settings.texture_intensity, f32(t.size.x)},
				size          = f.size,
				texture       = gpu.read_index(t.texture),
				sampler_index = gpu.sampler_index(r.materials.sampler),
			}
			sf.constants = upload
		}
	}
	if sf.integrate || sf.constants.data != nil {
		f.sky_texture = sf
	}
	return ambient
}

// turn_ambient turns an ambient light about +y: a direction at an azimuth sees the texture's light from the azimuth
// less the rotation, so its gradient's x and z turn by it.
@(private)
turn_ambient :: proc(a: Ambient, angle: f32) -> Ambient {
	c, s := math.cos(angle), math.sin(angle)
	return {constant = a.constant, x = a.x * c + a.z * s, y = a.y, z = a.z * c - a.x * s}
}

// turn_direction is where a direction of the texture is in the world, by its rotation: at the azimuth plus the
// rotation.
@(private)
turn_direction :: proc(d: [3]f32, angle: f32) -> [3]f32 {
	c, s := math.cos(angle), math.sin(angle)
	return {d.x * c + d.z * s, d.y, d.z * c - d.x * s}
}

// Sky_Sun_State is whether the frame's sky has a sun that sky_texture_sun can give.
Sky_Sun_State :: enum u8 {
	Found,
	// The last frame's sky was not a texture's.
	No_Texture_Sky,
	// The texture is not resident, or its integral is not back yet.
	Not_Ready,
	// No texel is SKY_SUN_RATIO times as bright as the average.
	No_Sun,
}

// sky_texture_sun is the direction toward the sun of the last frame's texture sky, in the world: where its brightest
// texels are (see docs/rendering/sky.md#texture). The editor aims a light at it.
sky_texture_sun :: proc(r: ^Renderer) -> (direction: [3]f32, state: Sky_Sun_State) {
	s := &r.sky.texture
	switch {
	case r.last_sky_mode != .Texture:
		return {}, .No_Texture_Sky
	case !s.valid || r.scene.frame > s.sun_frame + 1:
		return {}, .Not_Ready
	case s.sun_ratio < SKY_SUN_RATIO:
		return {}, .No_Sun
	}
	return s.world_sun, .Found
}

// ensure_sky_texture_buffers creates the integral's buffers the first time.
@(private = "file")
ensure_sky_texture_buffers :: proc(r: ^Renderer) -> bool {
	s := &r.sky.texture
	if s.result == {} {
		s.result = r.platform.gpu_create_buffer({size = SKY_AMBIENT_RESULT_SIZE, usage = {.Storage}, label = "sky texture ambient"}, nil)
		s.readback = r.platform.gpu_create_buffer({size = SKY_AMBIENT_RESULT_SIZE, usage = {.Readback}, label = "sky texture ambient readback"}, nil)
	}
	return s.result != {} && s.readback != {}
}

// add_sky_texture_passes adds the integral of the texture's ambient light and its copy to the readback buffer, when the
// frame asked for one.
@(private)
add_sky_texture_passes :: proc(f: ^Frame) {
	sf := f.sky_texture
	if sf == nil || !sf.integrate {
		return
	}
	g := f.graph
	s := &f.renderer.sky.texture
	sf.result = import_buffer(g, s.result)
	sf.readback = import_buffer(g, s.readback)
	p := add_compute_pass(g, "sky texture ambient", run_sky_texture_ambient, f)
	write(g, p, sf.result)
	p = add_compute_pass(g, "sky texture ambient readback", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		sf := f.sky_texture
		gpu.cmd_copy_buffer(ctx.cb, gpu_buffer(ctx.graph, sf.result), 0, gpu_buffer(ctx.graph, sf.readback), 0, SKY_AMBIENT_RESULT_SIZE)
	}, f)
	copy_source(g, p, sf.result)
	copy_dest(g, p, sf.readback)
}

// add_sky_texture_background adds the pass that draws the texture after the world pass, where nothing drew, before the
// fog covers it.
@(private)
add_sky_texture_background :: proc(f: ^Frame) {
	sf := f.sky_texture
	if sf == nil || sf.constants.data == nil {
		return
	}
	g := f.graph
	sf.scene = f.scene
	p := add_compute_pass(g, "sky texture", run_sky_texture_background, f)
	read(g, p, f.depth)
	read(g, p, f.exposure)
	write(g, p, f.scene)
}

// sky_texture_draws is whether the texture sky draws the frame's background, so the world pass clears to black under
// it.
@(private)
sky_texture_draws :: proc(f: ^Frame) -> bool {
	return f.sky_texture != nil && f.sky_texture.constants.data != nil
}

@(private = "file")
run_sky_texture_ambient :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.sky_texture
	push := Sky_Texture_Push {
		texture    = gpu.read_index(sf.texture),
		output     = gpu.write_index(gpu_buffer(ctx.graph, sf.result)),
		mip        = sf.mip,
		ticket     = sf.ticket,
		width      = sf.mip_size.x,
		height     = sf.mip_size.y,
		sun_mip    = sf.sun_mip,
		sun_width  = sf.sun_size.x,
		sun_height = sf.sun_size.y,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sky.texture.ambient.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, {1, 1, 1})
}

@(private = "file")
run_sky_texture_background :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.sky_texture
	g := ctx.graph
	push := Sky_Texture_Push {
		depth    = gpu.read_index(gpu_texture(g, f.depth)),
		output   = gpu.write_index(gpu_texture(g, sf.scene)),
		exposure = gpu.read_index(gpu_buffer(g, f.exposure)),
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.sky.texture.background.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, sf.constants)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, SKY_GROUP_SIZE))
}

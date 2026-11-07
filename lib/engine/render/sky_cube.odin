package render

import "core:math"

import "cinnabar:core/gpu"

// The sky's cubemap (see docs/rendering/sky.md#specular-light): the Environment's sky in every direction, prefiltered by
// roughness into a GGX mip chain, which the specular light takes along the reflection in place of the linear ambient
// light. A capture draws the sky into a source cube, every mip of it, and a prefilter convolves the source into each
// mip of a cube of three in a ring: the current one, which the readers sample, the previous one, which it blends in
// over, and the next one, which a build fills a mip a frame when the sky changes. It runs at every quality, at the
// reflections' level.

// The engine's sky cubemap shaders, by their .meta files.
SKY_CUBE_CAPTURE_SHADER :: #load("../content/shaders/sky_cube_capture.hlsl.meta", string)
SKY_CUBE_ATMOSPHERE_SHADER :: #load("../content/shaders/sky_cube_atmosphere.hlsl.meta", string)
CUBE_PREFILTER_SHADER :: #load("../content/shaders/cube_prefilter.hlsl.meta", string)

// The mips go down to faces this wide: a coarser one shows its texels in the roughest reflections.
SKY_CUBE_MIN_FACE :: 4
SKY_CUBE_MAX_MIPS :: 8
// A capture's texel averages at most this many directions across, squared: one per texel of mip 0 below it.
SKY_CUBE_MAX_SUBSAMPLES :: 8
SKY_CUBE_GROUP_SIZE :: 8

// Sky_Cube_Params are the cubemap's at a level: its faces' size, its format, and the prefilter's samples per texel.
Sky_Cube_Params :: struct {
	face:    u32,
	format:  gpu.Format,
	samples: u32,
}

// Every sky's light fits RG11B10_Float's range, which is RGBA16_Float's. The higher levels keep its precision.
@(rodata)
SKY_CUBE_PARAMS := [Quality_Level]Sky_Cube_Params {
	.Low = {face = 64, format = .RG11B10_Float, samples = 32},
	.Medium = {face = 128, format = .RG11B10_Float, samples = 64},
	.High = {face = 128, format = .RGBA16_Float, samples = 64},
	.Ultra = {face = 256, format = .RGBA16_Float, samples = 128},
}

// Sky_Cube_Source is what the capture draws. Matches SOURCE_TEXTURE in sky_cube_capture.hlsl.
Sky_Cube_Source :: enum u8 {
	// The frame's linear ambient light: Flat's colors, or the ambient light of a sky whose own source is not ready.
	Ambient,
	// The sky view table.
	Atmosphere,
	// The Texture sky's texture, once it is resident.
	Texture,
}

// Sky_Cube_Key is what a cubemap was captured from: its source, and that source's inputs.
@(private)
Sky_Cube_Key :: struct {
	source:    Sky_Cube_Source,
	ambient:   Ambient,
	light:     Sky_Light_Key,
	texture:   Sky_Texture_Key,
	rotation:  f32,
	intensity: f32,
}

// Sky_Cube_Texture is a cube and the write views of its mips.
@(private)
Sky_Cube_Texture :: struct {
	texture: gpu.Texture,
	views:   [SKY_CUBE_MAX_MIPS]gpu.Texture,
}

// Sky_Cube is the cubemap's state between frames, in Sky.
Sky_Cube :: struct {
	capture:    Shader_Pipeline,
	atmosphere: Shader_Pipeline,
	prefilter:  Shader_Pipeline,
	// The textures, made for params, or not made when they could not be.
	params:     Sky_Cube_Params,
	made:       bool,
	mips:       u32,
	source:     Sky_Cube_Texture,
	// The ring: current, the one after it that a build fills, and previous after that.
	cubes:      [3]Sky_Cube_Texture,
	// What the cubes hold. It changes only when a frame executes (see begin_sky_cube).
	ring:       Sky_Cube_Ring,
}

// Sky_Cube_Ring is what the ring's cubes hold, as of the last frame that executed.
@(private)
Sky_Cube_Ring :: struct {
	current:      u32,
	// Whether current holds a cubemap, key's, and whether previous holds the one that it blends in over.
	valid:        bool,
	has_previous: bool,
	key:          Sky_Cube_Key,
	// A build of build_key's sky, which has prefiltered step mips.
	building:     bool,
	build_key:    Sky_Cube_Key,
	step:         u32,
	// The frames that current has blended in over.
	blend_frames: u32,
}

// Sky_Cube_Reads are what the readers sample: the current cube's and the previous one's read indices, how far current
// has blended in, and the mips, 0 without a cubemap.
Sky_Cube_Reads :: struct {
	current:  u32,
	previous: u32,
	blend:    f32,
	mips:     f32,
}

// Sky_Cube_Push matches Sky_Cube_Push in sky_cube_capture.hlsl.
@(private = "file")
Sky_Cube_Push :: struct {
	ambient:       [4][4]f32,
	turn:          [4]f32,
	output:        u32,
	face:          u32,
	subsamples:    u32,
	source:        u32,
	texture:       u32,
	cube:          u32,
	sampler_index: u32,
}

// Cube_Prefilter_Push matches Cube_Prefilter_Push in cube_prefilter.hlsl. The output's faces start at its layer
// first_layer, 0 for a cube, and a multiple of six for a cube of a cube array.
@(private)
Cube_Prefilter_Push :: struct {
	source:        u32,
	output:        u32,
	face:          u32,
	source_face:   u32,
	source_mips:   u32,
	samples:       u32,
	sampler_index: u32,
	roughness:     f32,
	first_layer:   u32,
}

// Sky_Cube_Frame is what one frame's sky cubemap needs, in frame memory: what the readers sample, and this frame's
// work, a capture and mip_count mips from first_mip, into the ring's cube target.
@(private)
Sky_Cube_Frame :: struct {
	reads:       Sky_Cube_Reads,
	current:     Texture,
	previous:    Texture,
	capture:     bool,
	source:      Sky_Cube_Source,
	push:        Sky_Cube_Push,
	intensity:   f32,
	target:      u32,
	first_mip:   u32,
	mip_count:   u32,
	source_cube: Texture,
	target_cube: Texture,
	// The ring once this frame's work is done, which commit_sky_cube keeps when the frame executes.
	next:        Sky_Cube_Ring,
}

// sky_cube_mips is a cubemap's mip count: from the face down to SKY_CUBE_MIN_FACE.
sky_cube_mips :: proc(face: u32) -> u32 {
	mips := u32(1)
	for mips < SKY_CUBE_MAX_MIPS && face >> mips >= SKY_CUBE_MIN_FACE {
		mips += 1
	}
	return mips
}

// sky_cube_roughness is a mip's roughness: 0, a mirror, at mip 0, and 1 at the last. The readers take the mip at
// their roughness the same way.
sky_cube_roughness :: proc(mip, mips: u32) -> f32 {
	return mips > 1 ? f32(mip) / f32(mips - 1) : 0
}

@(private)
sky_cube_init :: proc(c: ^Sky_Cube) {
	c.capture = shader_pipeline(SKY_CUBE_CAPTURE_SHADER)
	c.atmosphere = shader_pipeline(SKY_CUBE_ATMOSPHERE_SHADER)
	c.prefilter = shader_pipeline(CUBE_PREFILTER_SHADER)
}

@(private)
sky_cube_destroy :: proc(c: ^Sky_Cube, r: ^Renderer) {
	for p in ([]^Shader_Pipeline{&c.capture, &c.atmosphere, &c.prefilter}) {
		destroy_shader_pipeline(p, r.platform)
	}
	destroy_sky_cube_textures(c, r)
}

@(private)
sync_sky_cube_pipelines :: proc(r: ^Renderer, force: bool) {
	c := &r.sky.cube
	assets := r.residency.assets
	sync_compute_pipeline(&c.capture, r.platform, assets, {label = "sky cube capture"}, force)
	sync_compute_pipeline(
		&c.atmosphere,
		r.platform,
		assets,
		{label = "sky cube atmosphere"},
		force,
	)
	sync_compute_pipeline(&c.prefilter, r.platform, assets, {label = "cube prefilter"}, force)
}

@(private = "file")
destroy_sky_cube_textures :: proc(c: ^Sky_Cube, r: ^Renderer) {
	for t in ([]^Sky_Cube_Texture{&c.source, &c.cubes[0], &c.cubes[1], &c.cubes[2]}) {
		for view in t.views {
			r.platform.gpu_destroy_texture(view)
		}
		r.platform.gpu_destroy_texture(t.texture)
		t^ = {}
	}
	c.made, c.ring = false, {}
}

// ensure_sky_cube makes the cubemap's textures for a level's params, again when they change, which starts over.
@(private = "file")
ensure_sky_cube :: proc(r: ^Renderer, params: Sky_Cube_Params) -> bool {
	c := &r.sky.cube
	if c.params == params && c.source.texture != {} {
		return true
	}
	if c.params == params && c.made {
		return false
	}
	destroy_sky_cube_textures(c, r)
	c.params, c.made, c.mips = params, true, sky_cube_mips(params.face)
	labels := [4]string{"sky cube source", "sky cube", "sky cube", "sky cube"}
	for t, i in ([]^Sky_Cube_Texture{&c.source, &c.cubes[0], &c.cubes[1], &c.cubes[2]}) {
		if !make_sky_cube_texture(
			t,
			r.platform.gpu_create_texture,
			r.platform.gpu_create_texture_view,
			params,
			c.mips,
			labels[i],
		) {
			destroy_sky_cube_textures(c, r)
			c.made = true
			return false
		}
	}
	return true
}

// make_sky_cube_texture makes a cube of params' faces and format, or a cube array of cubes, with mips and their views.
@(private)
make_sky_cube_texture :: proc(
	t: ^Sky_Cube_Texture,
	create: proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture,
	create_view: proc(desc: gpu.Texture_View_Desc) -> gpu.Texture,
	params: Sky_Cube_Params,
	mips: u32,
	label: string,
	cubes: u32 = 1,
) -> bool {
	desc := gpu.Texture_Desc {
		size      = {params.face, params.face},
		layers    = 6 * cubes,
		cube      = true,
		format    = params.format,
		mip_count = mips,
		usage     = {.Sampled, .Storage},
		label     = label,
	}
	t.texture = create(desc, nil)
	if t.texture == {} || create_view == nil {
		return false
	}
	for mip in 0 ..< mips {
		t.views[mip] = create_view({texture = t.texture, mip = mip, label = label})
		if t.views[mip] == {} {
			return false
		}
	}
	return true
}

// begin_sky_cube readies the frame's cubemap, after begin_sky and before the scene's and the global illumination's
// constants, which take its reads. When the cubemap is not valid, as in the first frame, every mip is made this frame,
// and the readers sample it from the next one. When the sky changes, a build of the next cube starts: its first frame
// captures the source and prefilters mip 0, and each frame after prefilters one more. When it ends, the ring turns,
// and the new cube blends in over as many frames, so a sky that changes every frame changes the reflections smoothly.
// The ring changes only when the frame executes, so a frame that fails does its work again.
@(private)
begin_sky_cube :: proc(f: ^Frame, s: Sky_Settings, level: Quality_Level, ambient: Ambient) {
	r := f.renderer
	c := &r.sky.cube
	if !ensure_sky_cube(r, SKY_CUBE_PARAMS[level]) {
		return
	}
	g := f.graph
	cf := new(Sky_Cube_Frame, r.platform.frame_allocator)
	f.sky_cube = cf
	cf.next = c.ring
	on_executed(g, commit_sky_cube, f)
	n := &cf.next
	if n.valid {
		current := c.cubes[n.current].texture
		previous, blend := current, f32(1)
		if n.has_previous {
			previous = c.cubes[(n.current + 2) % 3].texture
			blend = min(1, f32(n.blend_frames + 1) / f32(c.mips))
		}
		n.blend_frames += 1
		cf.current = import_texture(g, current, .Storage)
		cf.previous = import_texture(g, previous, .Storage)
		cf.reads = {gpu.read_index(current), gpu.read_index(previous), blend, f32(c.mips)}
	}
	if !pipeline_ready(r.platform, &c.prefilter) {
		return
	}
	key, has_source := sky_cube_source(f, s, ambient, cf)
	switch {
	case !n.valid:
		if !has_source {
			return
		}
		n.building = false
		cf.capture, cf.target, cf.first_mip, cf.mip_count = true, n.current, 0, c.mips
		n.valid, n.has_previous, n.key = true, false, key
		return
	case n.building:
		cf.target, cf.first_mip, cf.mip_count = (n.current + 1) % 3, n.step, 1
		n.step += 1
	case has_source && key != n.key:
		cf.capture, cf.target, cf.first_mip, cf.mip_count = true, (n.current + 1) % 3, 0, 1
		n.building, n.build_key, n.step = true, key, 1
	case:
		return
	}
	if n.step == c.mips {
		n.current = (n.current + 1) % 3
		n.key, n.has_previous, n.building, n.blend_frames = n.build_key, true, false, 0
	}
}

// commit_sky_cube keeps the ring that the frame's work made.
@(private = "file")
commit_sky_cube :: proc(data: rawptr) {
	f := (^Frame)(data)
	f.renderer.sky.cube.ring = f.sky_cube.next
}

// sky_cube_source chooses what the capture draws and gives its key: the atmosphere once its tables are made this frame,
// the texture once it is resident, and otherwise the ambient light. It is false when no capture pipeline for it is
// ready.
@(private = "file")
sky_cube_source :: proc(
	f: ^Frame,
	s: Sky_Settings,
	ambient: Ambient,
	cf: ^Sky_Cube_Frame,
) -> (
	Sky_Cube_Key,
	bool,
) {
	r := f.renderer
	c := &r.sky.cube
	platform := r.platform
	#partial switch s.mode {
	case .Atmosphere:
		if f.sky != nil && pipeline_ready(platform, &c.atmosphere) {
			cf.source, cf.intensity = .Atmosphere, s.ambient_intensity
			return {
					source = .Atmosphere,
					light = r.sky.ambient_key,
					intensity = s.ambient_intensity,
				},
				true
		}
	case .Texture:
		t, ready := resident_texture_of(&r.residency, s.texture, .D2, .Cube)
		if ready && pipeline_ready(platform, &c.capture) {
			cube := t.dimension == .Cube
			around := cube ? t.size.x * 4 : t.size.x
			turn := math.to_radians(s.texture_rotation)
			intensity := s.texture_intensity * s.ambient_intensity
			cf.source = .Texture
			cf.push = {
				turn          = {math.cos(turn), math.sin(turn), intensity, f32(around)},
				source        = u32(Sky_Cube_Source.Texture),
				texture       = gpu.read_index(t.texture),
				cube          = u32(cube),
				sampler_index = gpu.sampler_index(r.materials.sampler),
			}
			return {
					source = .Texture,
					texture = {s.texture, t.texture},
					rotation = s.texture_rotation,
					intensity = intensity,
				},
				true
		}
	}
	if !pipeline_ready(platform, &c.capture) {
		return {}, false
	}
	cf.source = .Ambient
	cf.push = {
		ambient = ambient_constants(ambient),
		source  = u32(Sky_Cube_Source.Ambient),
	}
	return {source = .Ambient, ambient = ambient}, true
}

// add_sky_cube_passes adds this frame's capture and prefilter, after the sky's tables, which the atmosphere's capture
// reads. The readers sample cubes that earlier frames finished, so they need nothing from these passes.
@(private)
add_sky_cube_passes :: proc(f: ^Frame) {
	cf := f.sky_cube
	if cf == nil || cf.mip_count == 0 {
		return
	}
	g := f.graph
	c := &f.renderer.sky.cube
	cf.source_cube = import_texture(g, c.source.texture, .Storage)
	cf.target_cube = import_texture(g, c.cubes[cf.target].texture, .Storage)
	if cf.capture {
		p := add_compute_pass(g, "sky cube capture", run_sky_cube_capture, f)
		if cf.source == .Atmosphere {
			read(g, p, f.sky.view)
		}
		write(g, p, cf.source_cube)
	}
	p := add_compute_pass(g, "sky cube prefilter", run_sky_cube_prefilter, f)
	read(g, p, cf.source_cube)
	write(g, p, cf.target_cube)
}

// declare_sky_cube_reads declares a pass's reads of the cubes that its shaders sample.
@(private)
declare_sky_cube_reads :: proc(f: ^Frame, p: Pass) {
	cf := f.sky_cube
	if cf == nil || cf.current == 0 {
		return
	}
	read(f.graph, p, cf.current)
	read(f.graph, p, cf.previous)
}

// sky_cube_reads are the frame's reads of the cubemap: no mips without one.
@(private)
sky_cube_reads :: proc(f: ^Frame) -> Sky_Cube_Reads {
	return f.sky_cube != nil ? f.sky_cube.reads : {}
}

@(private)
cube_groups :: proc(face: u32) -> [3]u32 {
	gs := groups({face, face}, SKY_CUBE_GROUP_SIZE)
	gs.z = 6
	return gs
}

// Each source mip's texel averages a direction per texel of mip 0 under it, up to SKY_CUBE_MAX_SUBSAMPLES across.
@(private = "file")
run_sky_cube_capture :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.sky_cube
	r := f.renderer
	c := &r.sky.cube
	g := ctx.graph
	atmosphere := cf.source == .Atmosphere
	if atmosphere {
		gpu.cmd_set_pipeline(ctx.cb, c.atmosphere.pipeline)
		gpu.cmd_set_pass_constants(ctx.cb, f.sky.upload)
	} else {
		gpu.cmd_set_pipeline(ctx.cb, c.capture.pipeline)
	}
	for mip in 0 ..< c.mips {
		face := max(c.params.face >> mip, 1)
		subsamples := min(u32(1) << mip, SKY_CUBE_MAX_SUBSAMPLES)
		output := gpu.write_index(c.source.views[mip])
		if atmosphere {
			push := Sky_Push {
				view          = gpu.read_index(gpu_texture(g, f.sky.view)),
				output        = output,
				sampler_index = gpu.sampler_index(r.post.sampler),
				face          = face,
				subsamples    = subsamples,
				intensity     = cf.intensity,
			}
			gpu.cmd_push_constants(ctx.cb, &push)
		} else {
			push := cf.push
			push.output, push.face, push.subsamples = output, face, subsamples
			gpu.cmd_push_constants(ctx.cb, &push)
		}
		gpu.cmd_dispatch(ctx.cb, cube_groups(face))
	}
}

@(private = "file")
run_sky_cube_prefilter :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	cf := f.sky_cube
	r := f.renderer
	c := &r.sky.cube
	gpu.cmd_set_pipeline(ctx.cb, c.prefilter.pipeline)
	for mip in cf.first_mip ..< cf.first_mip + cf.mip_count {
		face := max(c.params.face >> mip, 1)
		push := Cube_Prefilter_Push {
			source        = gpu.read_index(c.source.texture),
			output        = gpu.write_index(c.cubes[cf.target].views[mip]),
			face          = face,
			source_face   = c.params.face,
			source_mips   = c.mips,
			samples       = c.params.samples,
			sampler_index = gpu.sampler_index(r.post.sampler),
			roughness     = sky_cube_roughness(mip, c.mips),
		}
		gpu.cmd_push_constants(ctx.cb, &push)
		gpu.cmd_dispatch(ctx.cb, cube_groups(face))
	}
}

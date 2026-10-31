package render

import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Global illumination (see docs/rendering/global-illumination.md#global-illumination): screen-space radiance cascades. After the prepass,
// on the compute queue, the cascades' probes trace their intervals through the depth buffer into last frame's lit
// scene, merge from the last cascade to the first with the ambient sky beyond, and each pixel gathers its diffuse and
// specular light from them into history textures, which the forward pass reads in place of the ambient light. After
// the world pass, the scene is kept, without its pre-exposure, for the next frame's rays. With Split_Cascades, the world
// probes (gi_probes.odin) give the light beyond the screen and beyond the last cascade in the ambient sky's place, and
// the split cascades (gi_split.odin) take the screen cascades' place.

// The engine's global illumination shaders, by their .meta files.
GI_TRACE_SHADER :: #load("../content/shaders/gi_trace.hlsl.meta", string)
GI_MERGE_SHADER :: #load("../content/shaders/gi_merge.hlsl.meta", string)
GI_GATHER_SHADER :: #load("../content/shaders/gi_gather.hlsl.meta", string)
GI_LIT_SHADER :: #load("../content/shaders/gi_lit.hlsl.meta", string)

GI_FORMAT :: gpu.Format.RGBA16_Float
// The first cascade's interval is this many probe spacings long, at the probe's depth, with 4 directions across. A
// direction's texel is narrower with more directions, so the interval grows with them, and reaches as far.
GI_INTERVAL_SCALE :: 2
// The cascades' texture is at most this large on each side, Direct3D 12's limit.
GI_MAX_TEXTURE_SIZE :: 16384

// Gi_Params are the cascades at a level. Cascade k has a probe every spacing << k pixels, with (directions << k)^2
// directions. Each cascade's interval is four times as long as the one before, from a length that scales with the
// spacing and the directions, so fewer probes need fewer cascades to reach as far. steps are each ray's steps through
// the depth buffer. The histories average at most history_frames frames, so the light follows a change within a few;
// fewer probes average over more.
Gi_Params :: struct {
	cascades:       u32,
	spacing:        u32,
	directions:     u32,
	steps:          u32,
	history_frames: f32,
}

@(rodata)
GI_PARAMS := [Quality_Level]Gi_Params {
	.Low    = {cascades = 4, spacing = 16, directions = 4, steps = 4, history_frames = 16},
	.Medium = {cascades = 5, spacing = 8, directions = 4, steps = 6, history_frames = 12},
	.High   = {cascades = 5, spacing = 8, directions = 4, steps = 8, history_frames = 12},
	// Ultra's probes are as far apart as High's, with four times the directions: 8 across at spacing 4 would be four
	// times the texels, past the texture's size at 4K.
	.Ultra  = {cascades = 5, spacing = 8, directions = 8, steps = 12, history_frames = 10},
}

// Gi_Settings are a frame's global illumination, in Frame_Settings, from the Global_Illumination settings.
Gi_Settings :: struct {
	// Without it, the indirect light is the Environment's ambient light.
	off:       bool,
	// Split_Cascades adds the world probes and the split cascades.
	technique: Gi_Technique,
	// The cascades' GI_PARAMS, and the world probes' GI_PROBE_PARAMS.
	level:     Quality_Level,
}

// Gi_Passes is the global illumination's state between frames, in the Renderer.
Gi_Passes :: struct {
	trace:  Shader_Pipeline,
	merge:  Shader_Pipeline,
	gather: Shader_Pipeline,
	lit:    Shader_Pipeline,
	// Counts the frames, for the noise.
	frame:  u32,
	probes: Gi_Probes,
	split:  Gi_Split,
}

// Gi_Constants matches Gi_Constants in gi_common.hlsli.
@(private = "file")
Gi_Constants :: struct {
	previous:         matrix[4, 4]f32,
	right:            [4]f32,
	up:               [4]f32,
	forward:          [4]f32,
	projection:       [4]f32,
	ambient:          [4][4]f32,
	depth:            u32,
	stencil:          u32,
	normals:          u32,
	velocity:         u32,
	lit:              u32,
	lit_valid:        u32,
	cascades:         u32,
	sampler_index:    u32,
	history_diffuse:  u32,
	history_specular: u32,
	out_diffuse:      u32,
	out_specular:     u32,
	valid:            u32,
	frame:            u32,
	cascade:          u32,
	cascade_count:    u32,
	size:             [2]u32,
	lit_size:         [2]u32,
	region:           [2]u32,
	scene:            u32,
	exposure:         u32,
	interval_scale:   f32,
	max_frames:       f32,
	spacing:          u32,
	steps:            u32,
	probes:           u32,
	probe_grid:       u32,
	probe_grid_offset: u32,
	directions:       u32,
}

// Gi_Frame is what one frame's global illumination passes need, in frame memory.
@(private)
Gi_Frame :: struct {
	constants: Gi_Constants,
	params:    Gi_Params,
	region:    [2]u32,
	lit_size:  [2]u32,
	cascades:  Texture,
	lit:       History,
	diffuse:   History,
	specular:  History,
	// The scene that the lit pass keeps: later passes replace Frame.scene before the passes record.
	scene:     Texture,
	settings:  Gi_Settings,
	// The world probes, once add_gi_world_probes has updated them, or nil.
	probes:    ^Gi_Probe_Frame,
	// The split cascades' probes as the Gi_Probes debug view shows them, which their gather draws when the view is on.
	probe_view: Texture,
}

// Gi_Merge is one merge pass, of one cascade.
@(private = "file")
Gi_Merge :: struct {
	frame:   ^Frame,
	cascade: u32,
}

gi_init :: proc(gi: ^Gi_Passes) {
	gi.trace = shader_pipeline(GI_TRACE_SHADER)
	gi.merge = shader_pipeline(GI_MERGE_SHADER)
	gi.gather = shader_pipeline(GI_GATHER_SHADER)
	gi.lit = shader_pipeline(GI_LIT_SHADER)
	gi_probes_init(&gi.probes)
	gi_split_init(&gi.split)
}

gi_destroy :: proc(gi: ^Gi_Passes, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&gi.trace, &gi.merge, &gi.gather, &gi.lit}) {
		destroy_shader_pipeline(p, platform)
	}
	gi_probes_destroy(&gi.probes, platform)
	gi_split_destroy(&gi.split, platform)
}

@(private)
sync_gi_pipelines :: proc(r: ^Renderer, force: bool) {
	gi := &r.gi
	assets := r.residency.assets
	sync_compute_pipeline(&gi.trace, r.platform, assets, {label = "gi trace"}, force)
	sync_compute_pipeline(&gi.merge, r.platform, assets, {label = "gi merge"}, force)
	sync_compute_pipeline(&gi.gather, r.platform, assets, {label = "gi gather"}, force)
	sync_compute_pipeline(&gi.lit, r.platform, assets, {label = "gi lit"}, force)
	sync_gi_probe_pipelines(r, force)
	sync_gi_split_pipelines(r, force)
}

// gi_region is the size of one cascade's rows: the most texels that a cascade's probes and directions take.
gi_region :: proc(size: [2]u32, params: Gi_Params) -> (region: [2]u32) {
	for k in u32(0) ..< params.cascades {
		spacing, directions := params.spacing << k, params.directions << k
		probes := (size + spacing - 1) / spacing
		region = {max(region.x, probes.x * directions), max(region.y, probes.y * directions)}
	}
	return
}

// gi_fit drops a level's last cascades while the cascades' texture would be larger than GI_MAX_TEXTURE_SIZE, so a
// very large view still has its nearer cascades.
gi_fit :: proc(size: [2]u32, params: Gi_Params) -> Gi_Params {
	p := params
	for p.cascades > 1 {
		region := gi_region(size, p)
		if region.x <= GI_MAX_TEXTURE_SIZE && region.y * p.cascades <= GI_MAX_TEXTURE_SIZE {
			break
		}
		p.cascades -= 1
	}
	return p
}

// begin_gi decides whether the frame has global illumination, before the scene's constants are written, which say so.
// With Split_Cascades and the probes' pipelines, it requests the ray scene, which the probes trace.
@(private)
begin_gi :: proc(f: ^Frame, settings: Gi_Settings, ambient: Ambient) {
	r := f.renderer
	gi := &r.gi
	platform := r.platform
	for p in ([]^Shader_Pipeline{&gi.trace, &gi.merge, &gi.gather, &gi.lit}) {
		if !pipeline_ready(platform, p) {
			return
		}
	}
	if settings.off {
		return
	}
	g := f.graph
	gf := new(Gi_Frame, platform.frame_allocator)
	gf.lit_size = (f.size + 1) / 2
	gf.params = gi_fit(f.size, GI_PARAMS[settings.level])
	gf.region = gi_region(f.size, gf.params)
	gf.lit = history_texture(g, {size = gf.lit_size, format = GI_FORMAT, label = "gi lit scene"})
	gf.diffuse = history_texture(g, {size = f.size, format = GI_FORMAT, label = "gi diffuse"})
	gf.specular = history_texture(g, {size = f.size, format = GI_FORMAT, label = "gi specular"})
	if gf.lit.current == 0 || gf.diffuse.current == 0 || gf.specular.current == 0 {
		return
	}
	gi.frame += 1
	gf.settings = settings
	if settings.technique == .Split_Cascades && gi_probes_ready(r) {
		request_ray_scene(f)
	}
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	gf.constants = {
		right          = {right.x, right.y, right.z, 0},
		up             = {up.x, up.y, up.z, 0},
		forward        = {forward.x, forward.y, forward.z, 0},
		projection     = {scale.x, scale.y, f.view.near, 0},
		ambient        = ambient_constants(ambient),
		lit_valid      = u32(gf.lit.valid),
		valid          = u32(gf.diffuse.valid && gf.specular.valid),
		frame          = gi.frame,
		cascade_count  = gf.params.cascades,
		size           = f.size,
		lit_size       = gf.lit_size,
		region         = gf.region,
		interval_scale = GI_INTERVAL_SCALE * f32(gf.params.directions) / 4,
		max_frames     = gf.params.history_frames,
		spacing        = gf.params.spacing,
		steps          = gf.params.steps,
		directions     = gf.params.directions,
	}
	f.gi = gf
}

// add_gi_world_probes updates the world probes after the prepass, before the cascades, which read them.
@(private)
add_gi_world_probes :: proc(f: ^Frame) {
	gf := f.gi
	if gf == nil {
		return
	}
	gf.probes = add_gi_probe_passes(f, gf.settings, gf.lit)
	if gf.probes != nil {
		gf.constants.probes = 1
		gf.constants.probe_grid = gpu.read_index(gf.probes.upload.buffer)
		gf.constants.probe_grid_offset = gf.probes.upload.offset
	}
}

// add_gi_passes adds the cascades' trace, their merges and the gather after the prepass, on the compute queue, and
// sets Frame.gi_diffuse and Frame.gi_specular, which the forward pass reads. With the world probes, each reads them,
// and the split cascades take their place when they can.
@(private)
add_gi_passes :: proc(f: ^Frame) {
	gf := f.gi
	if gf == nil {
		return
	}
	g := f.graph
	platform := f.renderer.platform
	// Last frame's projection is known once the scene's constants are written.
	gf.constants.previous = f.previous_view_projection * linalg.matrix4_translate_f32(f.camera_motion)
	// With the world probes, the split cascades take the screen cascades' place.
	if add_gi_split_passes(f) {
		f.gi_diffuse, f.gi_specular = gf.diffuse.current, gf.specular.current
		return
	}
	gf.cascades = create_texture(g, {size = {gf.region.x, gf.region.y * gf.params.cascades}, format = GI_FORMAT, label = "gi cascades"})
	p := add_compute_pass(g, "gi trace", run_gi_trace, f, queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, gf.lit.previous)
	write(g, p, gf.cascades)
	declare_probe_reads(f, p)
	for k := int(gf.params.cascades) - 1; k >= 0; k -= 1 {
		p = add_compute_pass(g, "gi merge", run_gi_merge, new_clone(Gi_Merge{f, u32(k)}, platform.frame_allocator), queue = .Compute)
		read(g, p, f.depth)
		write(g, p, gf.cascades)
		declare_probe_reads(f, p)
	}
	p = add_compute_pass(g, "gi gather", run_gi_gather, f, queue = .Compute)
	read(g, p, gf.cascades)
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, f.velocity)
	read(g, p, gf.diffuse.previous)
	read(g, p, gf.specular.previous)
	write(g, p, gf.diffuse.current)
	write(g, p, gf.specular.current)
	declare_probe_reads(f, p)
	f.gi_diffuse, f.gi_specular = gf.diffuse.current, gf.specular.current
}

// add_gi_lit adds the pass that keeps the scene for the next frame's rays, after the world pass.
@(private)
add_gi_lit :: proc(f: ^Frame) {
	gf := f.gi
	if gf == nil {
		return
	}
	g := f.graph
	gf.scene = f.scene
	p := add_compute_pass(g, "gi lit scene", run_gi_lit, f)
	read(g, p, f.scene)
	read(g, p, f.exposure)
	write(g, p, gf.lit.current)
}

// gi_constants are the frame's constants with the textures that exist once the passes record.
@(private)
gi_constants :: proc(ctx: ^Pass_Context, f: ^Frame) -> Gi_Constants {
	gf := f.gi
	g := ctx.graph
	c := gf.constants
	depth := gpu_texture(g, f.depth)
	c.depth = gpu.read_index(depth)
	c.stencil = gpu.stencil_index(depth)
	c.normals = gpu.read_index(gpu_texture(g, f.normals))
	c.sampler_index = gpu.sampler_index(f.renderer.post.sampler)
	return c
}

@(private)
upload_gi_constants :: proc(ctx: ^Pass_Context, f: ^Frame, c: Gi_Constants) -> bool {
	upload, ok := f.renderer.platform.gpu_upload(size_of(Gi_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return false
	}
	(^Gi_Constants)(raw_data(upload.data))^ = c
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	return true
}

@(private = "file")
run_gi_trace :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	gf := f.gi
	g := ctx.graph
	c := gi_constants(ctx, f)
	c.lit = gpu.read_index(gpu_texture(g, gf.lit.previous))
	c.cascades = gpu.write_index(gpu_texture(g, gf.cascades))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.gi.trace.pipeline)
	if upload_gi_constants(ctx, f, c) {
		groups := groups(gf.region, POST_GROUP_SIZE)
		gpu.cmd_dispatch(ctx.cb, {groups.x, groups.y, gf.params.cascades})
	}
}

@(private = "file")
run_gi_merge :: proc(ctx: ^Pass_Context) {
	m := (^Gi_Merge)(ctx.data)
	f := m.frame
	gf := f.gi
	c := gi_constants(ctx, f)
	c.cascades = gpu.write_index(gpu_texture(ctx.graph, gf.cascades))
	c.cascade = m.cascade
	spacing, directions := gf.params.spacing << m.cascade, gf.params.directions << m.cascade
	texels := (f.size + spacing - 1) / spacing * directions
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.gi.merge.pipeline)
	if upload_gi_constants(ctx, f, c) {
		gpu.cmd_dispatch(ctx.cb, groups(texels, POST_GROUP_SIZE))
	}
}

@(private = "file")
run_gi_gather :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	gf := f.gi
	g := ctx.graph
	c := gi_constants(ctx, f)
	c.cascades = gpu.read_index(gpu_texture(g, gf.cascades))
	c.velocity = gpu.read_index(gpu_texture(g, f.velocity))
	c.history_diffuse = gpu.read_index(gpu_texture(g, gf.diffuse.previous))
	c.history_specular = gpu.read_index(gpu_texture(g, gf.specular.previous))
	c.out_diffuse = gpu.write_index(gpu_texture(g, gf.diffuse.current))
	c.out_specular = gpu.write_index(gpu_texture(g, gf.specular.current))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.gi.gather.pipeline)
	if upload_gi_constants(ctx, f, c) {
		gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
	}
}

@(private = "file")
run_gi_lit :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	gf := f.gi
	g := ctx.graph
	c := gf.constants
	c.scene = gpu.read_index(gpu_texture(g, gf.scene))
	c.exposure = gpu.read_index(gpu_buffer(g, f.exposure))
	c.lit = gpu.write_index(gpu_texture(g, gf.lit.current))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.gi.lit.pipeline)
	if upload_gi_constants(ctx, f, c) {
		gpu.cmd_dispatch(ctx.cb, groups(gf.lit_size, POST_GROUP_SIZE))
	}
}

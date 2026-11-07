package render

import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Stochastic screen-space reflections (see docs/rendering/lighting-and-shadows.md#screen-space-reflections):
// Reflection_Technique.Screen. After the prepass, on the compute queue, a pass builds a pyramid of the nearest depth,
// rays from each pixel's surface, sampled by its roughness from the spatiotemporal blue noise, march it and take last
// frame's lit scene where they hit, a resolve reuses each pixel's neighbors' rays, weighed by its own lobe, and a
// temporal pass accumulates the result where the reflected point was last frame. The result is Frame.reflections,
// whose rgb is the specular light along the reflection, filtered for the pixel's roughness and pre-exposed, and whose
// alpha is its weight: the forward pass puts it in front of the probes, the global illumination or the sky's cubemap.
// After the world pass, another pass keeps the lit scene for the next frame's rays, unless the global illumination's
// serves.

// The engine's screen-space reflection shaders, by their .meta files.
SSR_DEPTH_SHADER :: #load("../content/shaders/ssr_depth.hlsl.meta", string)
SSR_TRACE_SHADER :: #load("../content/shaders/ssr_trace.hlsl.meta", string)
SSR_RESOLVE_SHADER :: #load("../content/shaders/ssr_resolve.hlsl.meta", string)
SSR_TEMPORAL_SHADER :: #load("../content/shaders/ssr_temporal.hlsl.meta", string)
SSR_LIT_SHADER :: #load("../content/shaders/ssr_lit.hlsl.meta", string)

// The reflections, their history, their lit scene and the trace's rays and light. Match GI_FORMAT, so the global
// illumination's lit scene serves at half resolution.
SSR_FORMAT :: gpu.Format.RGBA16_Float
SSR_DISTANCE_FORMAT :: gpu.Format.R16_Float
// The depth pyramid: level 0 is the depth at the scene's size, and each level after is half the one before, rounded
// up. A dispatch of the depth pass writes four levels, so the pyramid has 1 + 4 + 4. Match the levels in ssr_depth.hlsl.
SSR_DEPTH_LEVELS :: 9
SSR_DEPTH_FORMAT :: gpu.Format.R32_Float
// A depth dispatch's group covers 16x16 texels of its source: 8x8 threads of 2x2.
SSR_DEPTH_GROUP_SIZE :: 16
// The temporal pass's history lengths, in frames: on a mirror, whose reflection changes with every move, and at the
// cutoff, whose noise needs the most averaging.
SSR_MIN_FRAMES :: 2
SSR_MAX_FRAMES :: 16
// At half resolution, the pixel of each 2x2 block that the rays start from, in turn from frame to frame.
@(rodata)
SSR_HALF_OFFSETS := [4][2]u32{{0, 0}, {1, 1}, {1, 0}, {0, 1}}

// Screen_Reflections is the screen-space reflections' state between frames, in the Renderer.
Screen_Reflections :: struct {
	depth:      Shader_Pipeline,
	trace:      Shader_Pipeline,
	resolve:    Shader_Pipeline,
	temporal:   Shader_Pipeline,
	lit:        Shader_Pipeline,
	// Counts the frames, for the noise and the half resolution's pixel.
	frame:      u32,
}

// Ssr_Constants matches Ssr_Constants in ssr_common.hlsli.
@(private = "file")
Ssr_Constants :: struct {
	previous:      matrix[4, 4]f32,
	right:         [4]f32,
	up:            [4]f32,
	forward:       [4]f32,
	projection:    [4]f32,
	depth:         u32,
	stencil:       u32,
	normals:       u32,
	roughness:     u32,
	velocity:      u32,
	lit:           u32,
	lit_valid:     u32,
	sampler_index: u32,
	noise:         u32,
	frame:         u32,
	exposure:      u32,
	scene:         u32,
	size:          [2]u32,
	trace_size:    [2]u32,
	lit_size:      [2]u32,
	offset:        [2]u32,
	ray_count:     u32,
	steps:         u32,
	cutoff:        f32,
	level_count:   u32,
	levels:        [3][4]u32,
	rays:          [4]u32,
	resolved:      u32,
	distance:      u32,
	history:       u32,
	output:        u32,
	jitter:        [2]f32,
	history_valid: u32,
	first:         u32,
	source:        u32,
	min_frames:    f32,
	max_frames:    f32,
	padding:       u32,
}

#assert(size_of(Ssr_Constants) == 336)

// Ssr_Frame is what one frame's screen-space reflections need, in frame memory.
@(private)
Ssr_Frame :: struct {
	constants:  Ssr_Constants,
	params:     Reflection_Params,
	trace_size: [2]u32,
	lit_size:   [2]u32,
	// The lit scene: the reflections' own, or the global illumination's, which the lit pass then leaves to it.
	lit:        History,
	shares_lit: bool,
	history:    History,
	levels:     [SSR_DEPTH_LEVELS]Texture,
	rays:       [2]Texture,
	radiance:   [2]Texture,
	resolved:   Texture,
	distance:   Texture,
	// The scene that the lit pass keeps: later passes replace Frame.scene before the passes record.
	scene:      Texture,
	depth:      [2]Ssr_Depth_Pass,
}

// Ssr_Depth_Pass is one dispatch of the depth pass.
@(private)
Ssr_Depth_Pass :: struct {
	frame: ^Frame,
	first: bool,
}

screen_reflections_init :: proc(s: ^Screen_Reflections) {
	s.depth = shader_pipeline(SSR_DEPTH_SHADER)
	s.trace = shader_pipeline(SSR_TRACE_SHADER)
	s.resolve = shader_pipeline(SSR_RESOLVE_SHADER)
	s.temporal = shader_pipeline(SSR_TEMPORAL_SHADER)
	s.lit = shader_pipeline(SSR_LIT_SHADER)
}

screen_reflections_destroy :: proc(s: ^Screen_Reflections, platform: ^core.Platform_API) {
	for p in screen_reflection_pipelines(s) {
		destroy_shader_pipeline(p, platform)
	}
}

@(private = "file")
screen_reflection_pipelines :: proc(s: ^Screen_Reflections) -> [5]^Shader_Pipeline {
	return {&s.depth, &s.trace, &s.resolve, &s.temporal, &s.lit}
}

// sync_screen_reflections updates the pipelines.
@(private)
sync_screen_reflections :: proc(r: ^Renderer, force: bool) {
	s := &r.ssr
	assets := r.residency.assets
	sync_compute_pipeline(&s.depth, r.platform, assets, {label = "reflections depth"}, force)
	sync_compute_pipeline(&s.trace, r.platform, assets, {label = "reflections trace"}, force)
	sync_compute_pipeline(&s.resolve, r.platform, assets, {label = "reflections resolve"}, force)
	sync_compute_pipeline(&s.temporal, r.platform, assets, {label = "reflections temporal"}, force)
	sync_compute_pipeline(&s.lit, r.platform, assets, {label = "reflections lit scene"}, force)
}

// ssr_level_size is the size of a level of the depth pyramid.
ssr_level_size :: proc(size: [2]u32, level: int) -> [2]u32 {
	round := u32(1) << u32(level) - 1
	return {(size.x + round) >> u32(level), (size.y + round) >> u32(level)}
}

// begin_screen_reflections decides whether the frame has screen-space reflections, before the scene's constants are
// written, which say so, and after begin_gi, whose lit scene serves at half resolution. Without the Screen technique,
// with off, or without its pipelines or its noise, it does nothing, and Frame.ssr stays nil.
@(private)
begin_screen_reflections :: proc(f: ^Frame, settings: Reflection_Settings) {
	r := f.renderer
	s := &r.ssr
	platform := r.platform
	if settings.off || settings.technique != .Screen {
		return
	}
	for p in screen_reflection_pipelines(s) {
		if !pipeline_ready(platform, p) {
			return
		}
	}
	noise := blue_noise(r)
	if noise == {} {
		return
	}
	g := f.graph
	sf := new(Ssr_Frame, platform.frame_allocator)
	sf.params = REFLECTION_PARAMS[.Screen][settings.level]
	half := (f.size + 1) / 2
	sf.trace_size = sf.params.half ? half : f.size
	if sf.params.half && f.gi != nil {
		sf.lit, sf.lit_size, sf.shares_lit = f.gi.lit, f.gi.lit_size, true
	} else {
		sf.lit_size = sf.params.half ? half : f.size
		sf.lit = history_texture(g, {size = sf.lit_size, format = SSR_FORMAT, label = "reflections lit scene"})
	}
	sf.history = history_texture(g, {size = f.size, format = SSR_FORMAT, label = "reflections"})
	if sf.lit.current == 0 || sf.history.current == 0 {
		return
	}
	s.frame += 1
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	sf.constants = {
		right         = {right.x, right.y, right.z, 0},
		up            = {up.x, up.y, up.z, 0},
		forward       = {forward.x, forward.y, forward.z, 0},
		projection    = {scale.x, scale.y, f.view.near, 0},
		lit_valid     = u32(sf.lit.valid),
		noise         = gpu.read_index(noise),
		frame         = s.frame,
		size          = f.size,
		trace_size    = sf.trace_size,
		lit_size      = sf.lit_size,
		offset        = sf.params.half ? SSR_HALF_OFFSETS[s.frame % 4] : {},
		ray_count     = max(min(sf.params.rays, 2), 1),
		steps         = sf.params.steps,
		cutoff        = sf.params.cutoff,
		level_count   = SSR_DEPTH_LEVELS,
		jitter        = f.jitter,
		history_valid = u32(sf.history.valid),
		min_frames    = SSR_MIN_FRAMES,
		max_frames    = SSR_MAX_FRAMES,
	}
	f.ssr = sf
}

// add_screen_reflection_passes adds the depth pyramid, the trace, the resolve and the temporal pass after the prepass,
// on the compute queue, and sets Frame.reflections, which the forward pass reads.
@(private)
add_screen_reflection_passes :: proc(f: ^Frame) {
	sf := f.ssr
	if sf == nil {
		return
	}
	g := f.graph
	// Last frame's projection is known once the scene's constants are written.
	sf.constants.previous = f.previous_view_projection * linalg.matrix4_translate_f32(f.camera_motion)
	for &level, i in sf.levels {
		level = create_texture(g, {size = ssr_level_size(f.size, i), format = SSR_DEPTH_FORMAT, label = "reflections depth"})
	}
	sf.depth[0] = {f, true}
	p := add_compute_pass(g, "reflections depth", run_ssr_depth, &sf.depth[0], queue = .Compute)
	read(g, p, f.depth)
	for level in sf.levels[:5] {
		write(g, p, level)
	}
	sf.depth[1] = {f, false}
	p = add_compute_pass(g, "reflections depth", run_ssr_depth, &sf.depth[1], queue = .Compute)
	read(g, p, sf.levels[4])
	for level in sf.levels[5:] {
		write(g, p, level)
	}

	rays := int(sf.constants.ray_count)
	for i in 0 ..< rays {
		sf.rays[i] = create_texture(g, {size = sf.trace_size, format = SSR_FORMAT, label = "reflections rays"})
		sf.radiance[i] = create_texture(g, {size = sf.trace_size, format = SSR_FORMAT, label = "reflections radiance"})
	}
	p = add_compute_pass(g, "reflections trace", run_ssr_trace, f, queue = .Compute)
	declare_ssr_surface(f, p)
	for level in sf.levels {
		read(g, p, level)
	}
	read(g, p, sf.lit.previous)
	read(g, p, f.exposure)
	for i in 0 ..< rays {
		write(g, p, sf.rays[i])
		write(g, p, sf.radiance[i])
	}

	sf.resolved = create_texture(g, {size = f.size, format = SSR_FORMAT, label = "reflections resolved"})
	sf.distance = create_texture(g, {size = f.size, format = SSR_DISTANCE_FORMAT, label = "reflections distance"})
	p = add_compute_pass(g, "reflections resolve", run_ssr_resolve, f, queue = .Compute)
	declare_ssr_surface(f, p)
	for i in 0 ..< rays {
		read(g, p, sf.rays[i])
		read(g, p, sf.radiance[i])
	}
	write(g, p, sf.resolved)
	write(g, p, sf.distance)

	p = add_compute_pass(g, "reflections temporal", run_ssr_temporal, f, queue = .Compute)
	declare_ssr_surface(f, p)
	read(g, p, f.velocity)
	read(g, p, sf.resolved)
	read(g, p, sf.distance)
	read(g, p, sf.history.previous)
	read(g, p, f.exposure)
	write(g, p, sf.history.current)
	f.reflections = sf.history.current
}

// add_screen_reflection_lit adds the pass that keeps the scene for the next frame's rays, after the world pass, unless
// the global illumination's lit scene serves.
@(private)
add_screen_reflection_lit :: proc(f: ^Frame) {
	sf := f.ssr
	if sf == nil || sf.shares_lit {
		return
	}
	g := f.graph
	sf.scene = f.scene
	p := add_compute_pass(g, "reflections lit scene", run_ssr_lit, f)
	read(g, p, f.scene)
	read(g, p, f.exposure)
	write(g, p, sf.lit.current)
}

// declare_ssr_surface declares the prepass's targets that a pass reads its pixels' surfaces from.
@(private = "file")
declare_ssr_surface :: proc(f: ^Frame, p: Pass) {
	g := f.graph
	read(g, p, f.depth)
	read(g, p, f.normals)
	read(g, p, f.roughness)
}

// ssr_constants are the frame's constants with the prepass's targets, which exist once the passes record.
@(private = "file")
ssr_constants :: proc(ctx: ^Pass_Context, f: ^Frame) -> Ssr_Constants {
	g := ctx.graph
	c := f.ssr.constants
	depth := gpu_texture(g, f.depth)
	c.depth = gpu.read_index(depth)
	c.stencil = gpu.stencil_index(depth)
	c.normals = gpu.read_index(gpu_texture(g, f.normals))
	c.roughness = gpu.read_index(gpu_texture(g, f.roughness))
	c.sampler_index = gpu.sampler_index(f.renderer.post.sampler)
	return c
}

@(private = "file")
dispatch_ssr :: proc(ctx: ^Pass_Context, f: ^Frame, pipeline: gpu.Pipeline, c: Ssr_Constants, size: [2]u32, group: u32) {
	upload, ok := f.renderer.platform.gpu_upload(size_of(Ssr_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Ssr_Constants)(raw_data(upload.data))^ = c
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(size, group))
}

@(private = "file")
run_ssr_depth :: proc(ctx: ^Pass_Context) {
	d := (^Ssr_Depth_Pass)(ctx.data)
	f := d.frame
	sf := f.ssr
	g := ctx.graph
	c := sf.constants
	c.first = u32(d.first)
	first, last := 0, 4
	if d.first {
		depth := gpu_texture(g, f.depth)
		c.depth = gpu.read_index(depth)
		c.stencil = gpu.stencil_index(depth)
	} else {
		c.source = gpu.read_index(gpu_texture(g, sf.levels[4]))
		first, last = 5, 8
	}
	for i in first ..= last {
		c.levels[i / 4][i % 4] = gpu.write_index(gpu_texture(g, sf.levels[i]))
	}
	// A group covers 16x16 texels of the level before its first.
	source := d.first ? f.size : ssr_level_size(f.size, 4)
	dispatch_ssr(ctx, f, f.renderer.ssr.depth.pipeline, c, source, SSR_DEPTH_GROUP_SIZE)
}

@(private = "file")
run_ssr_trace :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.ssr
	g := ctx.graph
	c := ssr_constants(ctx, f)
	for level, i in sf.levels {
		c.levels[i / 4][i % 4] = gpu.read_index(gpu_texture(g, level))
	}
	c.lit = gpu.read_index(gpu_texture(g, sf.lit.previous))
	c.exposure = gpu.read_index(gpu_buffer(g, f.exposure))
	for i in 0 ..< int(c.ray_count) {
		c.rays[i] = gpu.write_index(gpu_texture(g, sf.rays[i]))
		c.rays[2 + i] = gpu.write_index(gpu_texture(g, sf.radiance[i]))
	}
	dispatch_ssr(ctx, f, f.renderer.ssr.trace.pipeline, c, sf.trace_size, POST_GROUP_SIZE)
}

@(private = "file")
run_ssr_resolve :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.ssr
	g := ctx.graph
	c := ssr_constants(ctx, f)
	for i in 0 ..< int(c.ray_count) {
		c.rays[i] = gpu.read_index(gpu_texture(g, sf.rays[i]))
		c.rays[2 + i] = gpu.read_index(gpu_texture(g, sf.radiance[i]))
	}
	c.resolved = gpu.write_index(gpu_texture(g, sf.resolved))
	c.distance = gpu.write_index(gpu_texture(g, sf.distance))
	dispatch_ssr(ctx, f, f.renderer.ssr.resolve.pipeline, c, f.size, POST_GROUP_SIZE)
}

@(private = "file")
run_ssr_temporal :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.ssr
	g := ctx.graph
	c := ssr_constants(ctx, f)
	c.velocity = gpu.read_index(gpu_texture(g, f.velocity))
	c.resolved = gpu.read_index(gpu_texture(g, sf.resolved))
	c.distance = gpu.read_index(gpu_texture(g, sf.distance))
	c.history = gpu.read_index(gpu_texture(g, sf.history.previous))
	c.exposure = gpu.read_index(gpu_buffer(g, f.exposure))
	c.output = gpu.write_index(gpu_texture(g, sf.history.current))
	dispatch_ssr(ctx, f, f.renderer.ssr.temporal.pipeline, c, f.size, POST_GROUP_SIZE)
}

@(private = "file")
run_ssr_lit :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	sf := f.ssr
	g := ctx.graph
	c := sf.constants
	c.scene = gpu.read_index(gpu_texture(g, sf.scene))
	c.exposure = gpu.read_index(gpu_buffer(g, f.exposure))
	c.output = gpu.write_index(gpu_texture(g, sf.lit.current))
	dispatch_ssr(ctx, f, f.renderer.ssr.lit.pipeline, c, sf.lit_size, POST_GROUP_SIZE)
}

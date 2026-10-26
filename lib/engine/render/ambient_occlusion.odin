package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// Ambient occlusion (see docs/rendering/ambient-occlusion.md#ambient-occlusion): GTAO, after Intel's XeGTAO, from the prepass's depth and
// normals on the compute queue. A pass turns the depth into view depth and four smaller levels, the main pass finds
// the occlusion and the edges between surfaces, and the denoiser blurs it within each surface. It keeps no history:
// with temporal AA, its noise changes from frame to frame and temporal AA averages it. The forward pass scales the
// indirect light by it.

// The engine's ambient occlusion shaders, by their .meta files.
AO_DEPTH_SHADER :: #load("../content/shaders/gtao_depth.hlsl.meta", string)
AO_SHADER :: #load("../content/shaders/gtao.hlsl.meta", string)
AO_DENOISE_SHADER :: #load("../content/shaders/gtao_denoise.hlsl.meta", string)

// The view depth's levels, each half the size of the one before. Matches LEVELS in gtao.hlsl.
AO_DEPTH_LEVELS :: 5
AO_DEPTH_FORMAT :: gpu.Format.R32_Float
// The occlusion, noisy and denoised. It is not clamped to 1 until the forward pass reads it.
AO_FORMAT :: gpu.Format.R16_Float
// How much each pixel's four neighbors are on its surface, two bits each.
AO_EDGES_FORMAT :: gpu.Format.R8_Unorm
// The depth pass's group covers this many pixels on each side: 8x8 threads of 2x2 pixels.
AO_DEPTH_GROUP_SIZE :: 16
// The search's radius in meters, and the power that the visibility is raised to, which darkens the occlusion.
DEFAULT_AO_RADIUS :: 1
DEFAULT_AO_POWER :: 2.2
// How much a pixel's own value weighs in the denoiser against its neighbors': XeGTAO's, and a fifth of it in the
// passes before the last.
AO_BLUR :: 1.2
// The denoiser's passes with temporal AA, which averages the rest over time, and without it.
AO_DENOISE_PASSES_TEMPORAL :: 1
AO_DENOISE_PASSES :: 2

// Gtao_Params are GTAO's search at a level: how many slices turn around the view direction, and how many steps each
// takes on each side. These are XeGTAO's presets; Ultra was the only one before levels.
Gtao_Params :: struct {
	slices: u32,
	steps:  u32,
}

@(rodata)
GTAO_PARAMS := [Quality_Level]Gtao_Params {
	.Low    = {slices = 1, steps = 2},
	.Medium = {slices = 2, steps = 2},
	.High   = {slices = 3, steps = 3},
	.Ultra  = {slices = 9, steps = 3},
}

// Ao_Settings are a frame's ambient occlusion, in Frame_Settings, from the Ambient_Occlusion settings. Zero gives the defaults.
Ao_Settings :: struct {
	off:    bool,
	// In meters. 0 gives DEFAULT_AO_RADIUS.
	radius: f32,
	// 0 gives DEFAULT_AO_POWER.
	power:  f32,
	// The search's GTAO_PARAMS.
	level:  Quality_Level,
}

// Ao_Passes is the ambient occlusion's state between frames, in the Renderer.
Ao_Passes :: struct {
	depth:   Shader_Pipeline,
	gtao:    Shader_Pipeline,
	denoise: Shader_Pipeline,
	// Counts the frames, for the noise.
	frame:   u32,
}

// Ao_Depth_Constants matches Depth_Constants in gtao_depth.hlsl.
@(private = "file")
Ao_Depth_Constants :: struct {
	levels:          [4]u32,
	level4:          u32,
	depth:           u32,
	stencil:         u32,
	radius:          f32,
	size:            [2]u32,
	near:            f32,
	view_model_near: f32,
}

// Ao_Constants matches Constants in gtao.hlsl.
@(private = "file")
Ao_Constants :: struct {
	right:       [4]f32,
	up:          [4]f32,
	forward:     [4]f32,
	projection:  [4]f32,
	view_model:  [4]f32,
	levels:      [4]u32,
	level4:      u32,
	normals:     u32,
	output:      u32,
	edges:       u32,
	size:        [2]u32,
	jitter:      [2]f32,
	radius:      f32,
	power:       f32,
	noise_index: u32,
	slices:      u32,
	steps:       u32,
	padding:     [3]u32,
}

// Ao_Denoise_Push matches Push in gtao_denoise.hlsl.
@(private = "file")
Ao_Denoise_Push :: struct {
	source: u32,
	edges:  u32,
	output: u32,
	blur:   f32,
	size:   [2]u32,
}

// Ao_Frame is what one frame's ambient occlusion passes need, in frame memory.
@(private)
Ao_Frame :: struct {
	depth_constants: Ao_Depth_Constants,
	constants:       Ao_Constants,
	levels:          [AO_DEPTH_LEVELS]Texture,
	raw:             Texture,
	edges:           Texture,
	denoise:         [AO_DENOISE_PASSES]Ao_Denoise_Pass,
}

// Ao_Denoise_Pass is one of the denoiser's passes, which reads source and writes output.
@(private)
Ao_Denoise_Pass :: struct {
	frame:  ^Frame,
	source: Texture,
	output: Texture,
	blur:   f32,
}

#assert(size_of(Ao_Denoise_Push) <= 128)

ao_init :: proc(a: ^Ao_Passes) {
	a.depth = shader_pipeline(AO_DEPTH_SHADER)
	a.gtao = shader_pipeline(AO_SHADER)
	a.denoise = shader_pipeline(AO_DENOISE_SHADER)
}

ao_destroy :: proc(a: ^Ao_Passes, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&a.depth, platform)
	destroy_shader_pipeline(&a.gtao, platform)
	destroy_shader_pipeline(&a.denoise, platform)
}

@(private)
sync_ao_pipelines :: proc(r: ^Renderer, force: bool) {
	sync_compute_pipeline(&r.ao.depth, r.platform, r.residency.assets, {label = "gtao depth"}, force)
	sync_compute_pipeline(&r.ao.gtao, r.platform, r.residency.assets, {label = "gtao"}, force)
	sync_compute_pipeline(&r.ao.denoise, r.platform, r.residency.assets, {label = "gtao denoise"}, force)
}

// add_ao_passes adds the ambient occlusion's passes after the prepass, on the compute queue, and sets
// Frame.ambient_occlusion to the denoiser's result, which the forward pass reads. Without its pipelines or with off,
// it adds nothing. It reads f.post.temporal, so it runs after begin_post.
@(private)
add_ao_passes :: proc(f: ^Frame, settings: Ao_Settings) {
	r := f.renderer
	a := &r.ao
	platform := r.platform
	if settings.off ||
	   !pipeline_ready(platform, &a.depth) ||
	   !pipeline_ready(platform, &a.gtao) ||
	   !pipeline_ready(platform, &a.denoise) {
		return
	}
	g := f.graph
	af := new(Ao_Frame, platform.frame_allocator)
	for &level, i in af.levels {
		round := u32(1) << u32(i) - 1
		size := [2]u32{(f.size.x + round) >> u32(i), (f.size.y + round) >> u32(i)}
		level = create_texture(g, {size = size, format = AO_DEPTH_FORMAT, label = "ambient occlusion depth"})
	}
	af.raw = create_texture(g, {size = f.size, format = AO_FORMAT, label = "ambient occlusion raw"})
	af.edges = create_texture(g, {size = f.size, format = AO_EDGES_FORMAT, label = "ambient occlusion edges"})
	a.frame += 1
	temporal := f.post.temporal

	right, up, forward := view_axes(f.view)
	aspect := f32(f.size.x) / f32(max(f.size.y, 1))
	scale := projection_scale(f.view_projection)
	view_model := view_model_view(f.view)
	view_model_scale := projection_scale(view_projection(view_model, aspect))
	radius := settings.radius > 0 ? settings.radius : DEFAULT_AO_RADIUS
	af.depth_constants = {
		radius          = radius,
		size            = f.size,
		near            = f.view.near,
		view_model_near = view_model.near,
	}
	af.constants = {
		right       = {right.x, right.y, right.z, 0},
		up          = {up.x, up.y, up.z, 0},
		forward     = {forward.x, forward.y, forward.z, 0},
		projection  = {scale.x, scale.y, f.view.near, 0},
		view_model  = {view_model_scale.x, view_model_scale.y, view_model.near, 0},
		size        = f.size,
		jitter      = f.jitter,
		radius      = radius,
		power       = settings.power > 0 ? settings.power : DEFAULT_AO_POWER,
		// Without temporal AA nothing averages the noise over time, so it stays where it is.
		noise_index = temporal ? a.frame % 64 : 0,
		slices      = GTAO_PARAMS[settings.level].slices,
		steps       = GTAO_PARAMS[settings.level].steps,
	}
	f.ao = af

	p := add_compute_pass(g, "gtao depth", run_ao_depth, f, queue = .Compute)
	read(g, p, f.depth)
	for level in af.levels {
		write(g, p, level)
	}
	p = add_compute_pass(g, "gtao", run_gtao, f, queue = .Compute)
	for level in af.levels {
		read(g, p, level)
	}
	read(g, p, f.normals)
	write(g, p, af.raw)
	write(g, p, af.edges)

	passes := temporal ? AO_DENOISE_PASSES_TEMPORAL : AO_DENOISE_PASSES
	source := af.raw
	for i in 0 ..< passes {
		last := i == passes - 1
		d := &af.denoise[i]
		d^ = {
			frame  = f,
			source = source,
			output = create_texture(g, {size = f.size, format = AO_FORMAT, label = "ambient occlusion"}),
			blur   = last ? AO_BLUR : AO_BLUR / 5,
		}
		p = add_compute_pass(g, "gtao denoise", run_ao_denoise, d, queue = .Compute)
		read(g, p, d.source)
		read(g, p, af.edges)
		write(g, p, d.output)
		source = d.output
	}
	f.ambient_occlusion = source
}

@(private = "file")
run_ao_depth :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	constants := f.ao.depth_constants
	depth := gpu_texture(g, f.depth)
	constants.depth = gpu.read_index(depth)
	constants.stencil = gpu.stencil_index(depth)
	for level, i in f.ao.levels {
		index := gpu.write_index(gpu_texture(g, level))
		if i < 4 {
			constants.levels[i] = index
		} else {
			constants.level4 = index
		}
	}
	upload, ok := f.renderer.platform.gpu_upload(size_of(Ao_Depth_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Ao_Depth_Constants)(raw_data(upload.data))^ = constants
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.ao.depth.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, AO_DEPTH_GROUP_SIZE))
}

@(private = "file")
run_gtao :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	constants := f.ao.constants
	for level, i in f.ao.levels {
		index := gpu.read_index(gpu_texture(g, level))
		if i < 4 {
			constants.levels[i] = index
		} else {
			constants.level4 = index
		}
	}
	constants.normals = gpu.read_index(gpu_texture(g, f.normals))
	constants.output = gpu.write_index(gpu_texture(g, f.ao.raw))
	constants.edges = gpu.write_index(gpu_texture(g, f.ao.edges))
	upload, ok := f.renderer.platform.gpu_upload(size_of(Ao_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Ao_Constants)(raw_data(upload.data))^ = constants
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.ao.gtao.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

@(private = "file")
run_ao_denoise :: proc(ctx: ^Pass_Context) {
	d := (^Ao_Denoise_Pass)(ctx.data)
	f := d.frame
	g := ctx.graph
	push := Ao_Denoise_Push {
		source = gpu.read_index(gpu_texture(g, d.source)),
		edges  = gpu.read_index(gpu_texture(g, f.ao.edges)),
		output = gpu.write_index(gpu_texture(g, d.output)),
		blur   = d.blur,
		size   = f.size,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.ao.denoise.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

package render

import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"

// Ambient occlusion (see docs/rendering.md#ambient-occlusion): GTAO from the prepass's depth and normals, then a
// temporal denoiser into a history texture, both on the compute queue. The forward pass scales the indirect light by
// it.

// The engine's ambient occlusion shaders, by their .meta files.
AO_SHADER :: #load("../content/shaders/gtao.hlsl.meta", string)
AO_DENOISE_SHADER :: #load("../content/shaders/gtao_denoise.hlsl.meta", string)

// GTAO's noisy result, and the denoiser's history: the occlusion, the view depth it was found at and the frames it
// averages.
AO_FORMAT :: gpu.Format.R16_Float
AO_HISTORY_FORMAT :: gpu.Format.RGBA16_Float
// The search's radius in meters, and the power that the visibility is raised to, which darkens the occlusion.
DEFAULT_AO_RADIUS :: 1
DEFAULT_AO_POWER :: 2.2
// The history averages at most this many frames.
AO_HISTORY_FRAMES :: 16

// Ao_Settings are a frame's ambient occlusion, in Frame_Settings, from the Ambient_Occlusion settings. Zero gives the defaults.
Ao_Settings :: struct {
	off:    bool,
	// In meters. 0 gives DEFAULT_AO_RADIUS.
	radius: f32,
	// 0 gives DEFAULT_AO_POWER.
	power:  f32,
}

// Ao_Passes is the ambient occlusion's state between frames, in the Renderer.
Ao_Passes :: struct {
	gtao:    Shader_Pipeline,
	denoise: Shader_Pipeline,
	// Counts the frames, for the noise.
	frame:   u32,
}

// Ao_Push matches Push in gtao.hlsl.
@(private = "file")
Ao_Push :: struct {
	right:      [4]f32,
	up:         [4]f32,
	forward:    [4]f32,
	projection: [4]f32,
	view_model: [4]f32,
	depth:      u32,
	stencil:    u32,
	normals:    u32,
	output:     u32,
	size:       [2]u32,
	radius:     f32,
	power:      f32,
	frame:      u32,
	jitter:     [2]f32,
}

// Denoise_Constants matches Denoise_Constants in gtao_denoise.hlsl.
@(private = "file")
Denoise_Constants :: struct {
	previous:   matrix[4, 4]f32,
	right:      [4]f32,
	up:         [4]f32,
	forward:    [4]f32,
	projection: [4]f32,
	view_model: [4]f32,
	raw:        u32,
	depth:      u32,
	stencil:    u32,
	velocity:   u32,
	history:    u32,
	output:     u32,
	valid:      u32,
	max_frames: f32,
	size:       [2]u32,
	padding:    [2]u32,
}

// Ao_Frame is what one frame's ambient occlusion passes need, in frame memory.
@(private)
Ao_Frame :: struct {
	push:      Ao_Push,
	constants: Denoise_Constants,
	raw:       Texture,
	history:   History,
}

#assert(size_of(Ao_Push) <= 128)

ao_init :: proc(a: ^Ao_Passes) {
	a.gtao = shader_pipeline(AO_SHADER)
	a.denoise = shader_pipeline(AO_DENOISE_SHADER)
}

ao_destroy :: proc(a: ^Ao_Passes, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&a.gtao, platform)
	destroy_shader_pipeline(&a.denoise, platform)
}

@(private)
sync_ao_pipelines :: proc(r: ^Renderer, force: bool) {
	sync_compute_pipeline(&r.ao.gtao, r.platform, r.residency.assets, {label = "gtao"}, force)
	sync_compute_pipeline(&r.ao.denoise, r.platform, r.residency.assets, {label = "gtao denoise"}, force)
}

// add_ao_passes adds GTAO and its denoiser after the prepass, on the compute queue, and sets Frame.ambient_occlusion
// to the denoiser's history, which the forward pass reads. Without its pipelines or with off, it adds nothing.
@(private)
add_ao_passes :: proc(f: ^Frame, settings: Ao_Settings) {
	r := f.renderer
	a := &r.ao
	platform := r.platform
	if settings.off || !pipeline_ready(platform, &a.gtao) || !pipeline_ready(platform, &a.denoise) {
		return
	}
	g := f.graph
	af := new(Ao_Frame, platform.frame_allocator)
	af.history = history_texture(g, {size = f.size, format = AO_HISTORY_FORMAT, label = "ambient occlusion history"})
	if af.history.current == 0 {
		return
	}
	af.raw = create_texture(g, {size = f.size, format = AO_FORMAT, label = "ambient occlusion"})
	a.frame += 1

	right, up, forward := view_axes(f.view)
	aspect := f32(f.size.x) / f32(max(f.size.y, 1))
	scale := projection_scale(f.view_projection)
	view_model := view_model_view(f.view)
	view_model_scale := projection_scale(view_projection(view_model, aspect))
	af.push = {
		right      = {right.x, right.y, right.z, 0},
		up         = {up.x, up.y, up.z, 0},
		forward    = {forward.x, forward.y, forward.z, 0},
		projection = {scale.x, scale.y, f.view.near, 0},
		view_model = {view_model_scale.x, view_model_scale.y, view_model.near, 0},
		size       = f.size,
		radius     = settings.radius > 0 ? settings.radius : DEFAULT_AO_RADIUS,
		power      = settings.power > 0 ? settings.power : DEFAULT_AO_POWER,
		frame      = a.frame,
		jitter     = f.jitter,
	}
	af.constants = {
		previous   = f.previous_view_projection * linalg.matrix4_translate_f32(f.camera_motion),
		right      = af.push.right,
		up         = af.push.up,
		forward    = af.push.forward,
		projection = af.push.projection,
		view_model = af.push.view_model,
		valid      = u32(af.history.valid),
		max_frames = AO_HISTORY_FRAMES,
		size       = f.size,
	}
	f.ao = af

	p := add_compute_pass(g, "gtao", run_gtao, f, queue = .Compute)
	read(g, p, f.depth)
	read(g, p, f.normals)
	write(g, p, af.raw)
	p = add_compute_pass(g, "gtao denoise", run_ao_denoise, f, queue = .Compute)
	read(g, p, af.raw)
	read(g, p, f.depth)
	read(g, p, f.velocity)
	read(g, p, af.history.previous)
	write(g, p, af.history.current)
	f.ambient_occlusion = af.history.current
}

@(private = "file")
run_gtao :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := f.ao.push
	depth := gpu_texture(g, f.depth)
	push.depth = gpu.read_index(depth)
	push.stencil = gpu.stencil_index(depth)
	push.normals = gpu.read_index(gpu_texture(g, f.normals))
	push.output = gpu.write_index(gpu_texture(g, f.ao.raw))
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.ao.gtao.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

@(private = "file")
run_ao_denoise :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	af := f.ao
	g := ctx.graph
	constants := af.constants
	depth := gpu_texture(g, f.depth)
	constants.raw = gpu.read_index(gpu_texture(g, af.raw))
	constants.depth = gpu.read_index(depth)
	constants.stencil = gpu.stencil_index(depth)
	constants.velocity = gpu.read_index(gpu_texture(g, f.velocity))
	constants.history = gpu.read_index(gpu_texture(g, af.history.previous))
	constants.output = gpu.write_index(gpu_texture(g, af.history.current))
	upload, ok := f.renderer.platform.gpu_upload(size_of(Denoise_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Denoise_Constants)(raw_data(upload.data))^ = constants
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.ao.denoise.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

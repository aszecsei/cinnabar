package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// Ambient occlusion (see docs/rendering/ambient-occlusion.md#ambient-occlusion): GTAO after Intel's XeGTAO, HBAO or SSAO, as the
// quality chooses, from the prepass's depth and normals on the compute queue. A pass turns the depth into view depth
// and four smaller levels, the technique's search finds the occlusion and the edges between surfaces, and the denoiser
// blurs it within each surface. It keeps no history: with temporal AA, its noise changes from frame to frame and
// temporal AA averages it. The forward pass scales the indirect light by it.

// The engine's ambient occlusion shaders, by their .meta files: the depth levels and the denoiser that every technique
// shares, and each technique's search.
AO_DEPTH_SHADER :: #load("../content/shaders/gtao_depth.hlsl.meta", string)
AO_DENOISE_SHADER :: #load("../content/shaders/gtao_denoise.hlsl.meta", string)
AO_SEARCH_SHADERS :: [Ao_Technique]string {
	.Off  = "",
	.Gtao = #load("../content/shaders/gtao.hlsl.meta", string),
	.Ssao = #load("../content/shaders/ssao.hlsl.meta", string),
	.Hbao = #load("../content/shaders/hbao.hlsl.meta", string),
}

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

// Ao_Params are a technique's search at a level. samples are GTAO's slices around the view direction, HBAO's directions
// on the screen, or SSAO's points in the hemisphere; steps are each slice's steps on each side, or each direction's,
// which SSAO does not take.
Ao_Params :: struct {
	samples: u32,
	steps:   u32,
}

// The levels of each technique, from its cost: GTAO's are XeGTAO's presets, and its Ultra was the only search before
// levels. HBAO takes about as many depth reads as GTAO a level up, and SSAO as many as GTAO's slices times its steps.
@(rodata)
AO_PARAMS := [Ao_Technique][Quality_Level]Ao_Params {
	.Off = {},
	.Gtao = {
		.Low    = {samples = 1, steps = 2},
		.Medium = {samples = 2, steps = 2},
		.High   = {samples = 3, steps = 3},
		.Ultra  = {samples = 9, steps = 3},
	},
	.Ssao = {
		.Low    = {samples = 6},
		.Medium = {samples = 8},
		.High   = {samples = 12},
		.Ultra  = {samples = 16},
	},
	.Hbao = {
		.Low    = {samples = 4, steps = 3},
		.Medium = {samples = 4, steps = 4},
		.High   = {samples = 6, steps = 4},
		.Ultra  = {samples = 8, steps = 6},
	},
}

// Ao_Settings are a frame's ambient occlusion, in Frame_Settings, from the Ambient_Occlusion settings. Zero gives the defaults.
Ao_Settings :: struct {
	off:    bool,
	// In meters. 0 gives DEFAULT_AO_RADIUS.
	radius: f32,
	// 0 gives DEFAULT_AO_POWER.
	power:  f32,
	// The search, and its AO_PARAMS. A frame whose quality turns the ambient occlusion off has off set instead.
	technique: Ao_Technique,
	level:     Quality_Level,
}

// Ao_Passes is the ambient occlusion's state between frames, in the Renderer.
Ao_Passes :: struct {
	depth:    Shader_Pipeline,
	// Each technique's search. Every one is synced, so switching technique does not wait for a compile.
	searches: [Ao_Technique]Shader_Pipeline,
	denoise:  Shader_Pipeline,
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
	// The near and the far plane of the camera's projection and of the view model's (see View_Projection).
	near:            f32,
	view_model_near: f32,
	far:             f32,
	view_model_far:  f32,
}

// Ao_Constants matches Constants in ao_common.hlsli.
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
	noise:       u32,
	noise_slice: u32,
	samples:     u32,
	steps:       u32,
	padding:     [2]u32,
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

// Ao_Frame is what one view's ambient occlusion passes need, in frame memory: the camera's, in Frame.ao, or a
// reflection probe capture's face's (see ao_face). depth and normals are the view's prepass's, output is the
// denoiser's result, which the view's forward pass reads, and queue and names are the passes' queue and names: the
// depth's, the search's and the denoiser's.
@(private)
Ao_Frame :: struct {
	frame:           ^Frame,
	depth_constants: Ao_Depth_Constants,
	constants:       Ao_Constants,
	search:          gpu.Pipeline,
	names:           [3]string,
	queue:           gpu.Queue,
	size:            [2]u32,
	depth:           Texture,
	normals:         Texture,
	levels:          [AO_DEPTH_LEVELS]Texture,
	raw:             Texture,
	edges:           Texture,
	denoise:         [AO_DENOISE_PASSES]Ao_Denoise_Pass,
	denoise_count:   int,
	output:          Texture,
}

// Ao_Denoise_Pass is one of the denoiser's passes, which reads source and writes output.
@(private)
Ao_Denoise_Pass :: struct {
	view:   ^Ao_Frame,
	source: Texture,
	output: Texture,
	blur:   f32,
}

#assert(size_of(Ao_Denoise_Push) <= 128)

ao_init :: proc(a: ^Ao_Passes) {
	a.depth = shader_pipeline(AO_DEPTH_SHADER)
	shaders := AO_SEARCH_SHADERS
	for &search, technique in a.searches {
		if technique != .Off {
			search = shader_pipeline(shaders[technique])
		}
	}
	a.denoise = shader_pipeline(AO_DENOISE_SHADER)
}

ao_destroy :: proc(a: ^Ao_Passes, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&a.depth, platform)
	for &search in a.searches {
		destroy_shader_pipeline(&search, platform)
	}
	destroy_shader_pipeline(&a.denoise, platform)
}

// The searches' pipelines' labels, which name their passes too.
@(private = "file")
AO_SEARCH_LABELS := [Ao_Technique]string {
	.Off  = "",
	.Gtao = "gtao",
	.Ssao = "ssao",
	.Hbao = "hbao",
}

@(private)
sync_ao_pipelines :: proc(r: ^Renderer, force: bool) {
	sync_compute_pipeline(&r.ao.depth, r.platform, r.residency.assets, {label = "gtao depth"}, force)
	for &search, technique in r.ao.searches {
		if technique != .Off {
			sync_compute_pipeline(&search, r.platform, r.residency.assets, {label = AO_SEARCH_LABELS[technique]}, force)
		}
	}
	sync_compute_pipeline(&r.ao.denoise, r.platform, r.residency.assets, {label = "gtao denoise"}, force)
}

// add_ao_passes adds the ambient occlusion's passes after the prepass, on the compute queue, and sets
// Frame.ambient_occlusion to the denoiser's result, which the forward pass reads. Without its pipelines or the blue
// noise, or with off, it adds nothing. It reads f.post, so it runs after begin_post.
@(private)
add_ao_passes :: proc(f: ^Frame, settings: Ao_Settings) {
	r := f.renderer
	a := &r.ao
	platform := r.platform
	if settings.off ||
	   settings.technique == .Off ||
	   !pipeline_ready(platform, &a.depth) ||
	   !pipeline_ready(platform, &a.searches[settings.technique]) ||
	   !pipeline_ready(platform, &a.denoise) {
		return
	}
	noise := blue_noise(r)
	if noise == {} {
		return
	}
	f.state.ao_frame += 1
	// An upscaler averages the noise over time as temporal AA does.
	temporal := f.post.temporal || f.post.upscaler != {}

	right, up, forward := view_axes(f.view)
	radius := settings.radius > 0 ? settings.radius : DEFAULT_AO_RADIUS
	af := new(Ao_Frame, platform.frame_allocator)
	af^ = {
		frame         = f,
		search        = a.searches[settings.technique].pipeline,
		names         = {"gtao depth", AO_SEARCH_LABELS[settings.technique], "gtao denoise"},
		queue         = .Compute,
		size          = f.size,
		depth         = f.depth,
		normals       = f.normals,
		denoise_count = temporal ? AO_DENOISE_PASSES_TEMPORAL : AO_DENOISE_PASSES,
	}
	af.depth_constants = {
		radius          = radius,
		size            = f.size,
		near            = f.projection.z,
		view_model_near = f.view_model_projection.z,
		far             = f.projection.w,
		view_model_far  = f.view_model_projection.w,
	}
	af.constants = {
		right       = {right.x, right.y, right.z, 0},
		up          = {up.x, up.y, up.z, 0},
		forward     = {forward.x, forward.y, forward.z, 0},
		projection  = f.projection,
		view_model  = f.view_model_projection,
		size        = f.size,
		jitter      = f.jitter,
		radius      = radius,
		power       = settings.power > 0 ? settings.power : DEFAULT_AO_POWER,
		noise       = gpu.read_index(noise),
		// Without temporal AA nothing averages the noise over time, so it stays where it is.
		noise_slice = temporal ? f.state.ao_frame % BLUE_NOISE_SLICES : 0,
		samples     = AO_PARAMS[settings.technique][settings.level].samples,
		steps       = AO_PARAMS[settings.technique][settings.level].steps,
	}
	create_ao_textures(f.graph, af)
	add_ao_view_passes(f.graph, af)
	f.ao = af
	f.ambient_occlusion = af.output
}

// ao_face adds a reflection probe capture's face's ambient occlusion, from the camera's (see
// docs/rendering/lighting-and-shadows.md#reflection-probes): the same search, radius and power, from the face's own
// depth and normals, a 90° view of size pixels along axes (right, up and forward) from REFLECTION_PROBE_NEAR, with no
// jitter and a noise that stays, since nothing averages a capture over time, so the denoiser takes all of its passes.
// It runs on the graphics queue, between the face's prepass and its forward pass, in passes named for the probes. first is the frame's first face's,
// whose textures the frame's faces share, or nil for the first face. It is nil without the camera's ambient occlusion.
@(private)
ao_face :: proc(f: ^Frame, axes: [3][3]f32, size: u32, depth, normals: Texture, first: ^Ao_Frame) -> ^Ao_Frame {
	if f.ao == nil {
		return nil
	}
	af := new_clone(f.ao^, f.renderer.platform.frame_allocator)
	right, up, forward := axes[0], axes[1], axes[2]
	af.queue = .Graphics
	af.names = {"reflection probe ao depth", "reflection probe ao", "reflection probe ao denoise"}
	af.size = {size, size}
	af.depth, af.normals = depth, normals
	af.denoise_count = AO_DENOISE_PASSES
	af.depth_constants.size = af.size
	af.depth_constants.near, af.depth_constants.view_model_near = REFLECTION_PROBE_NEAR, REFLECTION_PROBE_NEAR
	af.depth_constants.far, af.depth_constants.view_model_far = 0, 0
	af.constants.right = {right.x, right.y, right.z, 0}
	af.constants.up = {up.x, up.y, up.z, 0}
	af.constants.forward = {forward.x, forward.y, forward.z, 0}
	af.constants.projection = {1, 1, REFLECTION_PROBE_NEAR, 0}
	af.constants.view_model = af.constants.projection
	af.constants.size = af.size
	af.constants.jitter = {}
	af.constants.noise_slice = 0
	if first != nil {
		af.levels, af.raw, af.edges = first.levels, first.raw, first.edges
		for i in 0 ..< af.denoise_count {
			af.denoise[i].output = first.denoise[i].output
		}
	} else {
		create_ao_textures(f.graph, af)
	}
	add_ao_view_passes(f.graph, af)
	return af
}

// create_ao_textures makes a view's depth levels, its search's results and its denoiser's outputs.
@(private = "file")
create_ao_textures :: proc(g: ^Graph, af: ^Ao_Frame) {
	for &level, i in af.levels {
		round := u32(1) << u32(i) - 1
		size := [2]u32{(af.size.x + round) >> u32(i), (af.size.y + round) >> u32(i)}
		level = create_texture(g, {size = size, format = AO_DEPTH_FORMAT, label = "ambient occlusion depth"})
	}
	af.raw = create_texture(g, {size = af.size, format = AO_FORMAT, label = "ambient occlusion raw"})
	af.edges = create_texture(g, {size = af.size, format = AO_EDGES_FORMAT, label = "ambient occlusion edges"})
	for i in 0 ..< af.denoise_count {
		af.denoise[i].output = create_texture(g, {size = af.size, format = AO_FORMAT, label = "ambient occlusion"})
	}
}

// add_ao_view_passes adds a view's depth levels, its search and its denoiser, and sets its output.
@(private = "file")
add_ao_view_passes :: proc(g: ^Graph, af: ^Ao_Frame) {
	p := add_compute_pass(g, af.names[0], run_ao_depth, af, queue = af.queue)
	read(g, p, af.depth)
	for level in af.levels {
		write(g, p, level)
	}
	p = add_compute_pass(g, af.names[1], run_ao_search, af, queue = af.queue)
	for level in af.levels {
		read(g, p, level)
	}
	read(g, p, af.normals)
	write(g, p, af.raw)
	write(g, p, af.edges)

	source := af.raw
	for i in 0 ..< af.denoise_count {
		d := &af.denoise[i]
		d.view, d.source = af, source
		d.blur = i == af.denoise_count - 1 ? AO_BLUR : AO_BLUR / 5
		p = add_compute_pass(g, af.names[2], run_ao_denoise, d, queue = af.queue)
		read(g, p, d.source)
		read(g, p, af.edges)
		write(g, p, d.output)
		source = d.output
	}
	af.output = source
}

@(private = "file")
run_ao_depth :: proc(ctx: ^Pass_Context) {
	af := (^Ao_Frame)(ctx.data)
	g := ctx.graph
	r := af.frame.renderer
	constants := af.depth_constants
	depth := gpu_texture(g, af.depth)
	constants.depth = gpu.read_index(depth)
	constants.stencil = gpu.stencil_index(depth)
	for level, i in af.levels {
		index := gpu.write_index(gpu_texture(g, level))
		if i < 4 {
			constants.levels[i] = index
		} else {
			constants.level4 = index
		}
	}
	upload, ok := r.platform.gpu_upload(size_of(Ao_Depth_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Ao_Depth_Constants)(raw_data(upload.data))^ = constants
	gpu.cmd_set_pipeline(ctx.cb, r.ao.depth.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(af.size, AO_DEPTH_GROUP_SIZE))
}

@(private = "file")
run_ao_search :: proc(ctx: ^Pass_Context) {
	af := (^Ao_Frame)(ctx.data)
	g := ctx.graph
	constants := af.constants
	for level, i in af.levels {
		index := gpu.read_index(gpu_texture(g, level))
		if i < 4 {
			constants.levels[i] = index
		} else {
			constants.level4 = index
		}
	}
	constants.normals = gpu.read_index(gpu_texture(g, af.normals))
	constants.output = gpu.write_index(gpu_texture(g, af.raw))
	constants.edges = gpu.write_index(gpu_texture(g, af.edges))
	upload, ok := af.frame.renderer.platform.gpu_upload(size_of(Ao_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Ao_Constants)(raw_data(upload.data))^ = constants
	gpu.cmd_set_pipeline(ctx.cb, af.search)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(af.size, POST_GROUP_SIZE))
}

@(private = "file")
run_ao_denoise :: proc(ctx: ^Pass_Context) {
	d := (^Ao_Denoise_Pass)(ctx.data)
	af := d.view
	g := ctx.graph
	push := Ao_Denoise_Push {
		source = gpu.read_index(gpu_texture(g, d.source)),
		edges  = gpu.read_index(gpu_texture(g, af.edges)),
		output = gpu.write_index(gpu_texture(g, d.output)),
		blur   = d.blur,
		size   = af.size,
	}
	gpu.cmd_set_pipeline(ctx.cb, af.frame.renderer.ao.denoise.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(af.size, POST_GROUP_SIZE))
}

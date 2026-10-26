package render

import "cinnabar:core"
import "cinnabar:core/gpu"

// Spatial anti-aliasing (see docs/rendering/anti-aliasing.md#anti-aliasing): FXAA or SMAA 1x, as the quality chooses in
// place of temporal AA. Both find edges by luma, so they run on the scene tone mapped into the display's sRGB-encoded
// colors: the tone map pass writes it, where the output pass tone maps otherwise, and the output pass blends the UI
// over their result, so the UI is not smoothed.

// The engine's spatial AA shaders, by their .meta files.
TONE_MAP_SHADER :: #load("../content/shaders/tone_map.hlsl.meta", string)
FXAA_SHADER :: #load("../content/shaders/fxaa.hlsl.meta", string)
SMAA_EDGES_SHADER :: #load("../content/shaders/smaa_edges.hlsl.meta", string)
SMAA_WEIGHTS_SHADER :: #load("../content/shaders/smaa_weights.hlsl.meta", string)
SMAA_BLEND_SHADER :: #load("../content/shaders/smaa_blend.hlsl.meta", string)

// The tone-mapped scene: sRGB-encoded, and above 1 in HDR output, where it is relative to paper white.
DISPLAY_FORMAT :: gpu.Format.RGBA16_Float
// SMAA's edges, to the left and above, and its blend weights with the four neighbors.
SMAA_EDGES_FORMAT :: gpu.Format.RG8_Unorm
SMAA_WEIGHTS_FORMAT :: gpu.Format.RGBA8_Unorm
// SMAA's lookup tables from its reference implementation (see vendor/smaa/README.md): the areas, RG8_Unorm, and the
// search's lengths, R8_Unorm.
SMAA_AREA_SIZE :: [2]u32{160, 560}
SMAA_SEARCH_SIZE :: [2]u32{64, 16}
smaa_area_table := #load("../../../vendor/smaa/area.bin")
smaa_search_table := #load("../../../vendor/smaa/search.bin")

// Spatial_Aa is the spatial AA's state between frames, in Post.
Spatial_Aa :: struct {
	tone_map:      Shader_Pipeline,
	fxaa:          Shader_Pipeline,
	smaa_edges:    Shader_Pipeline,
	smaa_weights:  Shader_Pipeline,
	smaa_blend:    Shader_Pipeline,
	smaa_area:     gpu.Texture,
	smaa_search:   gpu.Texture,
	// SMAA reads its tables and its edges with point samples as well as bilinear ones.
	point_sampler: gpu.Sampler,
}

// Fxaa_Push matches Push in fxaa.hlsl.
@(private = "file")
Fxaa_Push :: struct {
	input:         u32,
	output:        u32,
	sampler_index: u32,
	padding:       u32,
	size:          [2]u32,
	texel:         [2]f32,
}

// Smaa_Push matches Push in smaa.hlsli. metrics is the size's inverse, then the size.
@(private = "file")
Smaa_Push :: struct {
	color:          u32,
	edges:          u32,
	weights:        u32,
	area:           u32,
	search:         u32,
	linear_sampler: u32,
	point_sampler:  u32,
	padding:        u32,
	metrics:        [4]f32,
}

// The SMAA passes, by the target that each draws.
@(private = "file")
Smaa_Step :: enum u8 {
	Edges,
	Weights,
	Blend,
}

@(private = "file")
Smaa_Pass :: struct {
	frame: ^Frame,
	step:  Smaa_Step,
}

spatial_aa_init :: proc(s: ^Spatial_Aa, platform: ^core.Platform_API) {
	s.tone_map = shader_pipeline(TONE_MAP_SHADER)
	s.fxaa = shader_pipeline(FXAA_SHADER)
	s.smaa_edges = shader_pipeline(SMAA_EDGES_SHADER)
	s.smaa_weights = shader_pipeline(SMAA_WEIGHTS_SHADER)
	s.smaa_blend = shader_pipeline(SMAA_BLEND_SHADER)
	assert(len(smaa_area_table) == int(SMAA_AREA_SIZE.x * SMAA_AREA_SIZE.y * 2), "render: vendor/smaa/area.bin is not SMAA_AREA_SIZE in RG8")
	assert(len(smaa_search_table) == int(SMAA_SEARCH_SIZE.x * SMAA_SEARCH_SIZE.y), "render: vendor/smaa/search.bin is not SMAA_SEARCH_SIZE in R8")
	s.smaa_area = platform.gpu_create_texture({size = SMAA_AREA_SIZE, format = .RG8_Unorm, usage = {.Sampled}, label = "smaa area"}, smaa_area_table)
	s.smaa_search = platform.gpu_create_texture({size = SMAA_SEARCH_SIZE, format = .R8_Unorm, usage = {.Sampled}, label = "smaa search"}, smaa_search_table)
	s.point_sampler = platform.gpu_create_sampler({filter = .Nearest, mip_filter = .Nearest, address = .Clamp, label = "smaa point sampler"})
}

spatial_aa_destroy :: proc(s: ^Spatial_Aa, platform: ^core.Platform_API) {
	for pipeline in ([]^Shader_Pipeline{&s.tone_map, &s.fxaa, &s.smaa_edges, &s.smaa_weights, &s.smaa_blend}) {
		destroy_shader_pipeline(pipeline, platform)
	}
	platform.gpu_destroy_texture(s.smaa_area)
	platform.gpu_destroy_texture(s.smaa_search)
	platform.gpu_destroy_sampler(s.point_sampler)
}

// sync_spatial_aa_pipelines syncs both techniques' pipelines, whichever the frame uses, so the quality can switch
// between them without waiting for a compile.
@(private)
sync_spatial_aa_pipelines :: proc(r: ^Renderer, force: bool) {
	s := &r.post.spatial
	assets := r.residency.assets
	sync_compute_pipeline(&s.tone_map, r.platform, assets, {label = "tone map"}, force)
	sync_compute_pipeline(&s.fxaa, r.platform, assets, {label = "fxaa"}, force)
	smaa := [Smaa_Step]^Shader_Pipeline {
		.Edges   = &s.smaa_edges,
		.Weights = &s.smaa_weights,
		.Blend   = &s.smaa_blend,
	}
	formats := [Smaa_Step]gpu.Format {
		.Edges   = SMAA_EDGES_FORMAT,
		.Weights = SMAA_WEIGHTS_FORMAT,
		.Blend   = DISPLAY_FORMAT,
	}
	labels := [Smaa_Step]string {
		.Edges   = "smaa edges",
		.Weights = "smaa weights",
		.Blend   = "smaa blend",
	}
	for step in Smaa_Step {
		desc := gpu.Graphics_Pipeline_Desc {
			colors = {{format = formats[step]}},
			label  = labels[step],
		}
		sync_graphics_pipeline(smaa[step], r.platform, assets, {.Vertex, .Pixel}, desc, force)
	}
}

// spatial_aa_ready is whether a technique is spatial and its pipelines are compiled. Until they are, the frame has no
// anti-aliasing.
@(private)
spatial_aa_ready :: proc(platform: ^core.Platform_API, s: ^Spatial_Aa, technique: Aa_Technique) -> bool {
	#partial switch technique {
	case .Fxaa:
		return pipeline_ready(platform, &s.tone_map) && pipeline_ready(platform, &s.fxaa)
	case .Smaa:
		ready := pipeline_ready(platform, &s.tone_map)
		for p in ([]^Shader_Pipeline{&s.smaa_edges, &s.smaa_weights, &s.smaa_blend}) {
			ready &&= pipeline_ready(platform, p)
		}
		return ready
	}
	return false
}

// add_spatial_aa adds the tone map pass and the frame's technique's passes, after the lookup table's bake, and gives
// their result to the output pass as Frame.display.
@(private)
add_spatial_aa :: proc(f: ^Frame) {
	pf := f.post
	if pf.spatial == .Off {
		return
	}
	g := f.graph
	platform := f.renderer.platform
	pf.tone_mapped = create_texture(g, {size = f.scene_size, format = DISPLAY_FORMAT, label = "tone mapped scene"})
	pass := add_compute_pass(g, "tone map", run_tone_map, f)
	read(g, pass, f.scene)
	read(g, pass, f.lut)
	if f.bloom != 0 {
		read(g, pass, f.bloom)
	}
	write(g, pass, pf.tone_mapped)

	result := create_texture(g, {size = f.scene_size, format = DISPLAY_FORMAT, label = "anti-aliased scene"})
	#partial switch pf.spatial {
	case .Fxaa:
		pass = add_compute_pass(g, "fxaa", run_fxaa, f)
		read(g, pass, pf.tone_mapped)
		write(g, pass, result)
	case .Smaa:
		pf.smaa_edges = create_texture(g, {size = f.scene_size, format = SMAA_EDGES_FORMAT, label = "smaa edges"})
		pf.smaa_weights = create_texture(g, {size = f.scene_size, format = SMAA_WEIGHTS_FORMAT, label = "smaa weights"})
		pass = add_render_pass(g, "smaa edges", run_smaa, new_clone(Smaa_Pass{f, .Edges}, platform.frame_allocator))
		read(g, pass, pf.tone_mapped)
		color(g, pass, pf.smaa_edges, .Clear)
		pass = add_render_pass(g, "smaa weights", run_smaa, new_clone(Smaa_Pass{f, .Weights}, platform.frame_allocator))
		read(g, pass, pf.smaa_edges)
		color(g, pass, pf.smaa_weights, .Clear)
		pass = add_render_pass(g, "smaa blend", run_smaa, new_clone(Smaa_Pass{f, .Blend}, platform.frame_allocator))
		read(g, pass, pf.tone_mapped)
		read(g, pass, pf.smaa_weights)
		color(g, pass, result, .Discard)
	}
	f.display = result
}

@(private = "file")
run_tone_map :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := output_push(f, gpu_texture(g, f.scene), f.output.mode)
	tone_map_inputs(f, g, &push)
	push.output = gpu.write_index(gpu_texture(g, f.post.tone_mapped))
	push.size = f.scene_size
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.spatial.tone_map.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.scene_size, POST_GROUP_SIZE))
}

@(private = "file")
run_fxaa :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := Fxaa_Push {
		input         = gpu.read_index(gpu_texture(g, f.post.tone_mapped)),
		output        = gpu.write_index(gpu_texture(g, f.display)),
		sampler_index = gpu.sampler_index(f.renderer.post.sampler),
		size          = f.scene_size,
		texel         = {1 / f32(f.scene_size.x), 1 / f32(f.scene_size.y)},
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.spatial.fxaa.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.scene_size, POST_GROUP_SIZE))
}

@(private = "file")
run_smaa :: proc(ctx: ^Pass_Context) {
	pass := (^Smaa_Pass)(ctx.data)
	f := pass.frame
	pf := f.post
	g := ctx.graph
	s := &f.renderer.post.spatial
	push := Smaa_Push {
		area           = gpu.read_index(s.smaa_area),
		search         = gpu.read_index(s.smaa_search),
		linear_sampler = gpu.sampler_index(f.renderer.post.sampler),
		point_sampler  = gpu.sampler_index(s.point_sampler),
		metrics        = {1 / f32(f.scene_size.x), 1 / f32(f.scene_size.y), f32(f.scene_size.x), f32(f.scene_size.y)},
	}
	pipeline: gpu.Pipeline
	switch pass.step {
	case .Edges:
		push.color = gpu.read_index(gpu_texture(g, pf.tone_mapped))
		pipeline = s.smaa_edges.pipeline
	case .Weights:
		push.edges = gpu.read_index(gpu_texture(g, pf.smaa_edges))
		pipeline = s.smaa_weights.pipeline
	case .Blend:
		push.color = gpu.read_index(gpu_texture(g, pf.tone_mapped))
		push.weights = gpu.read_index(gpu_texture(g, pf.smaa_weights))
		pipeline = s.smaa_blend.pipeline
	}
	gpu.cmd_set_pipeline(ctx.cb, pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, 3)
}

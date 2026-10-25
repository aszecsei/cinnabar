package render

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// Volumetric fog (see docs/rendering.md#volumetric-fog): a froxel volume with the clusters' depth slices, halved. A
// compute pass injects each froxel's density and the light that reaches it, and blends it with last frame's in a
// history texture. Another integrates the volume along each view ray, and the forward pass dims each pixel by it and
// adds its light. A last pass fogs the background, where the forward pass drew nothing.

// The engine's fog shaders, by their .meta files. The traced injection traces the lights that have a channel of the
// shadow mask, and needs Ray_Query.
FOG_INJECT_SHADER :: #load("../content/shaders/fog_inject.hlsl.meta", string)
FOG_INJECT_TRACED_SHADER :: #load("../content/shaders/fog_inject_traced.hlsl.meta", string)
FOG_INTEGRATE_SHADER :: #load("../content/shaders/fog_integrate.hlsl.meta", string)
FOG_BACKGROUND_SHADER :: #load("../content/shaders/fog_background.hlsl.meta", string)

// A froxel is a screen tile of FOG_TILE pixels in one of FOG_SLICES depth slices, two for each of the clusters' slices.
// Matches fog_inject.hlsli and material_lighting.hlsli.
FOG_TILE :: 16
FOG_SLICES :: CLUSTER_SLICES * 2
FOG_FORMAT :: gpu.Format.RGBA16_Float
FOG_GROUP_SIZE :: 4
// This frame's share of the injected volume. The history holds the rest.
FOG_BLEND :: 0.1

// Volumetric_Fog is the fog's state between frames, in the Renderer.
Volumetric_Fog :: struct {
	inject:        Shader_Pipeline,
	inject_traced: Shader_Pipeline,
	integrate:     Shader_Pipeline,
	background:    Shader_Pipeline,
	// Counts the frames with fog, for the jitter within each slice.
	frame:         u32,
}

// Fog_Push matches Fog_Push in fog_inject.hlsli.
@(private = "file")
Fog_Push :: struct {
	shadow_atlas:   u32,
	shadow_mask:    u32,
	history:        u32,
	output:         u32,
	right:          [4]f32,
	up:             [4]f32,
	forward:        [4]f32,
	albedo:         [3]f32,
	density:        f32,
	height_falloff: f32,
	base_height:    f32,
	anisotropy:     f32,
	jitter:         f32,
	grid:           [3]u32,
	valid:          u32,
	accel:          u32,
	blend:          f32,
}

// Integrate_Push matches Push in fog_integrate.hlsl.
@(private = "file")
Integrate_Push :: struct {
	input:       u32,
	output:      u32,
	grid:        [2]u32,
	scale:       [2]f32,
	slices:      [2]f32,
	screen_size: [2]f32,
	slice_count: u32,
	padding:     u32,
}

// Background_Push matches Push in fog_background.hlsl.
@(private = "file")
Background_Push :: struct {
	depth:         u32,
	scene:         u32,
	fog:           u32,
	sampler_index: u32,
	exposure:      u32,
	padding:       u32,
	size:          [2]u32,
	fog_scale:     [2]f32,
}

#assert(size_of(Fog_Push) <= 128)

// Fog_Frame is what one frame's fog passes need, in frame memory.
@(private)
Fog_Frame :: struct {
	push:     Fog_Push,
	traced:   bool,
	grid:     [3]u32,
	// The share of the volume's width and height that the screen covers.
	scale:    [2]f32,
	history:  History,
	// The integrated volume, which the forward pass reads, and the scene that the background pass fogs: later passes
	// replace Frame.scene before the passes record.
	volume:   Texture,
	scene:    Texture,
	accel:    Accel,
}

fog_init :: proc(v: ^Volumetric_Fog) {
	v.inject = shader_pipeline(FOG_INJECT_SHADER)
	v.inject_traced = shader_pipeline(FOG_INJECT_TRACED_SHADER)
	v.integrate = shader_pipeline(FOG_INTEGRATE_SHADER)
	v.background = shader_pipeline(FOG_BACKGROUND_SHADER)
}


fog_destroy :: proc(v: ^Volumetric_Fog, platform: ^core.Platform_API) {
	for p in ([]^Shader_Pipeline{&v.inject, &v.inject_traced, &v.integrate, &v.background}) {
		destroy_shader_pipeline(p, platform)
	}
}

@(private)
sync_fog_pipelines :: proc(r: ^Renderer, force: bool) {
	v := &r.fog
	assets := r.residency.assets
	// A device without Ray_Query cannot create the traced pipeline, and has no shadow mask to trace for.
	if r.shadows.ray_query {
		sync_compute_pipeline(&v.inject_traced, r.platform, assets, {label = "fog inject (traced)"}, force)
	} else {
		sync_compute_pipeline(&v.inject, r.platform, assets, {label = "fog inject"}, force)
	}
	sync_compute_pipeline(&v.integrate, r.platform, assets, {label = "fog integrate"}, force)
	sync_compute_pipeline(&v.background, r.platform, assets, {label = "fog background"}, force)
}

// begin_fog readies the frame's fog volume, from the Fog settings at the camera, before the scene's constants are
// written, which say whether there is fog. Without fog or its pipelines, Frame.fog stays nil.
@(private)
begin_fog :: proc(f: ^Frame, fog: Fog_Settings) {
	r := f.renderer
	v := &r.fog
	platform := r.platform
	traced := r.shadows.ray_query
	if !pipeline_ready(platform, traced ? &v.inject_traced : &v.inject) || !pipeline_ready(platform, &v.integrate) {
		return
	}
	if fog.density <= 0 {
		return
	}
	grid := [3]u32{(f.size.x + FOG_TILE - 1) / FOG_TILE, (f.size.y + FOG_TILE - 1) / FOG_TILE, FOG_SLICES}
	history := history_texture(f.graph, {size = grid.xy, depth = grid.z, format = FOG_FORMAT, label = "fog history"})
	if history.current == 0 {
		return
	}
	v.frame += 1
	right, up, forward := view_axes(f.view)
	scale := projection_scale(f.view_projection)
	ff := new(Fog_Frame, platform.frame_allocator)
	ff^ = {
		traced = traced,
		grid = grid,
		scale = {f32(f.size.x) / f32(grid.x * FOG_TILE), f32(f.size.y) / f32(grid.y * FOG_TILE)},
		history = history,
		push = {
			right = {right.x, right.y, right.z, scale.x},
			up = {up.x, up.y, up.z, scale.y},
			forward = {forward.x, forward.y, forward.z, 0},
			albedo = fog.albedo,
			density = fog.density,
			height_falloff = fog.height_falloff,
			// Relative to the camera, in f64 so a camera far from the origin keeps it exact.
			base_height = f32(f64(fog.base_height) - ecs.position_to_meters(f.view.position).y),
			anisotropy = clamp(fog.anisotropy, -0.95, 0.95),
			jitter = halton(v.frame % JITTER_SAMPLES + 1, 2),
			grid = grid,
			valid = u32(history.valid),
			blend = FOG_BLEND,
		},
	}
	f.fog = ff
}

// add_fog_passes adds the injection and the integration, after the clusters and the shadows, whose results they read.
// The integrated volume becomes Frame.fog_volume.
@(private)
add_fog_passes :: proc(f: ^Frame) {
	ff := f.fog
	sf := f.scene_frame
	if ff == nil || sf == nil || len(sf.view_constants) == 0 {
		f.fog = nil
		return
	}
	g := f.graph
	p := add_compute_pass(g, "fog inject", run_fog_inject, f)
	if f.lights.clustered {
		read(g, p, f.lights.clusters)
		read(g, p, f.lights.indices)
	}
	if f.shadows.atlas != 0 {
		read(g, p, f.shadows.atlas)
	}
	if ff.traced && f.shadows.mask_count > 0 {
		ff.accel = f.shadows.accel
		read_accel(g, p, ff.accel)
	}
	read(g, p, ff.history.previous)
	write(g, p, ff.history.current)

	ff.volume = create_texture(g, {size = ff.grid.xy, depth = ff.grid.z, format = FOG_FORMAT, label = "fog volume"})
	p = add_compute_pass(g, "fog integrate", run_fog_integrate, f)
	read(g, p, ff.history.current)
	write(g, p, ff.volume)
	f.fog_volume = ff.volume
}

// add_fog_background adds the pass that fogs the background after the world pass, where the scene holds the clear
// color.
@(private)
add_fog_background :: proc(f: ^Frame) {
	if f.fog == nil || !pipeline_ready(f.renderer.platform, &f.renderer.fog.background) {
		return
	}
	g := f.graph
	f.fog.scene = f.scene
	p := add_compute_pass(g, "fog background", run_fog_background, f)
	read(g, p, f.depth)
	read(g, p, f.fog_volume)
	read(g, p, f.exposure)
	write(g, p, f.scene)
}

@(private = "file")
run_fog_inject :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	ff := f.fog
	g := ctx.graph
	r := f.renderer
	push := ff.push
	white := gpu.read_index(r.materials.defaults[.White])
	push.shadow_atlas, push.shadow_mask = white, white
	if f.shadows.atlas != 0 {
		push.shadow_atlas = gpu.read_index(gpu_texture(g, f.shadows.atlas))
	}
	if ff.accel != 0 {
		push.accel = gpu.read_index(gpu_accel(g, ff.accel))
	}
	push.history = gpu.read_index(gpu_texture(g, ff.history.previous))
	push.output = gpu.write_index(gpu_texture(g, ff.history.current))
	gpu.cmd_set_pipeline(ctx.cb, ff.traced ? r.fog.inject_traced.pipeline : r.fog.inject.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, (ff.grid + FOG_GROUP_SIZE - 1) / FOG_GROUP_SIZE)
}

@(private = "file")
run_fog_integrate :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	ff := f.fog
	g := ctx.graph
	scale, bias := slice_constants(f.view.near)
	push := Integrate_Push {
		input       = gpu.read_index(gpu_texture(g, ff.history.current)),
		output      = gpu.write_index(gpu_texture(g, ff.volume)),
		grid        = ff.grid.xy,
		scale       = {ff.push.right.w, ff.push.up.w},
		slices      = {scale, bias},
		screen_size = {f32(f.size.x), f32(f.size.y)},
		slice_count = FOG_SLICES,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.fog.integrate.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(ff.grid.xy, POST_GROUP_SIZE))
}

@(private = "file")
run_fog_background :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	r := f.renderer
	push := Background_Push {
		depth         = gpu.read_index(gpu_texture(g, f.depth)),
		scene         = gpu.write_index(gpu_texture(g, f.fog.scene)),
		fog           = gpu.read_index(gpu_texture(g, f.fog_volume)),
		sampler_index = gpu.sampler_index(r.post.sampler),
		exposure      = gpu.read_index(gpu_buffer(g, f.exposure)),
		size          = f.size,
		fog_scale     = f.fog.scale,
	}
	gpu.cmd_set_pipeline(ctx.cb, r.fog.background.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

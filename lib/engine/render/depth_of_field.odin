package render

import "cinnabar:core/gpu"

// The depth of field (see docs/rendering/post-processing.md#depth-of-field): the blur of a physical lens, from the
// view's Lens, in front of temporal AA at the scene's size. A setup pass finds each pixel's circle of confusion and
// halves the scene, a pass finds the largest near circle in each tile, a gather blurs the half-size scene, and a
// composite blends the blur into the scene by each pixel's own circle and by the near blur that spreads over it.

DOF_SHADER :: #load("../content/shaders/depth_of_field.hlsl.meta", string)

// The smallest tile of the near field's largest circle, in half-size pixels. The gather reads the 3x3 tiles around its
// own, so a tile is at least the largest radius too (see begin_dof).
DOF_MIN_TILE :: 8
DOF_HALF_FORMAT :: gpu.Format.RGBA16_Float
DOF_DEPTH_FORMAT :: gpu.Format.R32_Float
DOF_TILE_FORMAT :: gpu.Format.R16_Float

// The modes of depth_of_field.hlsl.
@(private)
DOF_SETUP :: 0
@(private)
DOF_TILES :: 1
@(private)
DOF_GATHER :: 2
@(private)
DOF_COMPOSITE :: 3

// Dof_Params are a technique's gather: its taps, on a disk or, with blades, on the aperture's polygon; the largest
// circle of confusion's radius, as a share of the scene's height, which the taps cover without gaps between them; and
// how much more a highlight weighs, so it opens into the aperture's shape.
Dof_Params :: struct {
	taps:       u32,
	blades:     u32,
	max_radius: f32,
	highlights: f32,
}

@(rodata)
DOF_PARAMS := [Dof_Technique]Dof_Params {
	.Off = {},
	.Gather = {taps = 24, max_radius = 0.015},
	.Bokeh = {taps = 64, blades = 6, max_radius = 0.03, highlights = 4},
}

// Dof_Lens is a view's circle of confusion in pixels at a view-space z: scale × (1 - focus / z), negative in front of
// the focus and positive behind it (see circle_of_confusion).
Dof_Lens :: struct {
	scale: f32,
	focus: f32,
}

// dof_lens is the circle of confusion of a view of a height in pixels, times a scale, 0 giving 1. The thin lens's circle
// on the sensor is A × f × (z - s) / (z × (s - f)), with the opening A = f / N, the focal length f, the focus s and the
// view-space z, all in meters; it is the sensor's height on the screen. The focus is at least twice the focal length
// and the near plane, so a focus at or behind the lens, as a target behind the camera gives, stays in front of it. ok is
// false without a lens: an orthographic view, or no aperture.
dof_lens :: proc(view: View, height: u32, scale: f32) -> (lens: Dof_Lens, ok: bool) {
	focal_mm := lens_focal_length(view)
	if focal_mm <= 0 {
		return
	}
	f := focal_mm * 0.001
	sensor := view.lens.sensor_height * 0.001
	focus := max(view.lens.focus_distance, 2 * f, view_near(view))
	opening := f / view.lens.aperture
	lens.scale = opening * f / (focus - f) / sensor * f32(height) * (scale > 0 ? scale : 1)
	lens.focus = focus
	return lens, true
}

// circle_of_confusion is a lens's signed circle of confusion in pixels at a view-space z. Matches coc in dof.hlsli.
circle_of_confusion :: proc(lens: Dof_Lens, z: f32) -> f32 {
	return lens.scale * (1 - lens.focus / max(z, 1e-4))
}

// Dof_Frame is one frame's depth of field, in frame memory.
@(private)
Dof_Frame :: struct {
	lens:       Dof_Lens,
	params:     Dof_Params,
	half_size:  [2]u32,
	// The tiles' side in half-size pixels, and their count on each axis.
	tile:       u32,
	tiles_size: [2]u32,
	// The scene that the setup and the composite read, the half-size scene and its circles, its view-space depth, the
	// tiles, the blur, and the composite's result.
	scene:      Texture,
	half:       Texture,
	half_depth: Texture,
	tiles:      Texture,
	blur:       Texture,
	output:     Texture,
}

// Dof_Constants matches Constants in depth_of_field.hlsl.
@(private = "file")
Dof_Constants :: struct {
	projection:    View_Projection,
	size:          [2]u32,
	half_size:     [2]u32,
	tiles_size:    [2]u32,
	mode:          u32,
	scene:         u32,
	depth:         u32,
	stencil:       u32,
	half_scene:    u32,
	half_depth:    u32,
	tiles:         u32,
	blur:          u32,
	output:        u32,
	sampler_index: u32,
	coc_scale:     f32,
	focus:         f32,
	max_radius:    f32,
	taps:          u32,
	blades:        u32,
	highlights:    f32,
	tile:          u32,
	padding:       u32,
}

#assert(size_of(Dof_Constants) == 112)

// Dof_Step is one pass of the depth of field.
@(private = "file")
Dof_Step :: struct {
	frame: ^Frame,
	mode:  u32,
}

// begin_dof is the frame's depth of field, or nil: without a technique, with no_dof, without a lens, or while its
// pipeline compiles. begin_post decides it before the world pass, which keeps the depth for it.
@(private)
begin_dof :: proc(f: ^Frame, settings: Post_Settings) -> ^Dof_Frame {
	if settings.no_dof || settings.dof == .Off {
		return nil
	}
	lens, ok := dof_lens(f.view, f.size.y, settings.dof_scale)
	if !ok || !pipeline_ready(f.renderer.platform, &f.renderer.post.dof) {
		return nil
	}
	df := new(Dof_Frame, f.renderer.platform.frame_allocator)
	df.lens = lens
	df.params = DOF_PARAMS[settings.dof]
	df.half_size = (f.size + 1) / 2
	df.tile = max(DOF_MIN_TILE, u32(df.params.max_radius * f32(f.size.y) * 0.5 + 1))
	df.tiles_size = (df.half_size + df.tile - 1) / df.tile
	return df
}

// add_dof_passes adds the depth of field's passes, whose result becomes Frame.scene.
@(private)
add_dof_passes :: proc(f: ^Frame) {
	df := f.post.dof
	if df == nil {
		return
	}
	g := f.graph
	allocator := f.renderer.platform.frame_allocator
	df.scene = f.scene
	df.half = create_texture(g, {size = df.half_size, format = DOF_HALF_FORMAT, label = "dof half"})
	df.half_depth = create_texture(
		g,
		{size = df.half_size, format = DOF_DEPTH_FORMAT, label = "dof half depth"},
	)
	df.tiles = create_texture(
		g,
		{size = df.tiles_size, format = DOF_TILE_FORMAT, label = "dof near tiles"},
	)
	df.blur = create_texture(g, {size = df.half_size, format = DOF_HALF_FORMAT, label = "dof blur"})
	df.output = create_texture(g, {size = f.size, format = SCENE_FORMAT, label = "dof scene"})

	pass := add_compute_pass(g, "dof setup", run_dof, new_clone(Dof_Step{f, DOF_SETUP}, allocator))
	read(g, pass, df.scene)
	read(g, pass, f.depth)
	write(g, pass, df.half)
	write(g, pass, df.half_depth)

	pass = add_compute_pass(g, "dof near tiles", run_dof, new_clone(Dof_Step{f, DOF_TILES}, allocator))
	read(g, pass, df.half)
	write(g, pass, df.tiles)

	pass = add_compute_pass(g, "dof gather", run_dof, new_clone(Dof_Step{f, DOF_GATHER}, allocator))
	read(g, pass, df.half)
	read(g, pass, df.half_depth)
	read(g, pass, df.tiles)
	write(g, pass, df.blur)

	pass = add_compute_pass(
		g,
		"dof composite",
		run_dof,
		new_clone(Dof_Step{f, DOF_COMPOSITE}, allocator),
	)
	read(g, pass, df.scene)
	read(g, pass, f.depth)
	read(g, pass, df.blur)
	write(g, pass, df.output)
	f.scene = df.output
}

@(private = "file")
run_dof :: proc(ctx: ^Pass_Context) {
	step := (^Dof_Step)(ctx.data)
	f := step.frame
	df := f.post.dof
	g := ctx.graph
	c := Dof_Constants {
		projection    = f.projection,
		size          = f.size,
		half_size     = df.half_size,
		tiles_size    = df.tiles_size,
		mode          = step.mode,
		sampler_index = gpu.sampler_index(f.renderer.post.sampler),
		coc_scale     = df.lens.scale,
		focus         = df.lens.focus,
		max_radius    = df.params.max_radius * f32(f.size.y),
		taps          = df.params.taps,
		blades        = df.params.blades,
		highlights    = df.params.highlights,
		tile          = df.tile,
	}
	size := df.half_size
	switch step.mode {
	case DOF_SETUP:
		depth := gpu_texture(g, f.depth)
		c.scene = gpu.read_index(gpu_texture(g, df.scene))
		c.depth = gpu.read_index(depth)
		c.stencil = gpu.stencil_index(depth)
		c.half_scene = gpu.write_index(gpu_texture(g, df.half))
		c.half_depth = gpu.write_index(gpu_texture(g, df.half_depth))
	case DOF_TILES:
		c.half_scene = gpu.read_index(gpu_texture(g, df.half))
		c.tiles = gpu.write_index(gpu_texture(g, df.tiles))
		size = df.tiles_size
	case DOF_GATHER:
		c.half_scene = gpu.read_index(gpu_texture(g, df.half))
		c.half_depth = gpu.read_index(gpu_texture(g, df.half_depth))
		c.tiles = gpu.read_index(gpu_texture(g, df.tiles))
		c.blur = gpu.write_index(gpu_texture(g, df.blur))
	case DOF_COMPOSITE:
		depth := gpu_texture(g, f.depth)
		c.scene = gpu.read_index(gpu_texture(g, df.scene))
		c.depth = gpu.read_index(depth)
		c.stencil = gpu.stencil_index(depth)
		c.blur = gpu.read_index(gpu_texture(g, df.blur))
		c.output = gpu.write_index(gpu_texture(g, df.output))
		size = f.size
	}
	upload, ok := f.renderer.platform.gpu_upload(size_of(Dof_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Dof_Constants)(raw_data(upload.data))^ = c
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.dof.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_dispatch(ctx.cb, groups(size, POST_GROUP_SIZE))
}

package render

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/ecs"

// Ray-traced reflections (see docs/rendering/lighting-and-shadows.md#ray-traced-reflections): Reflection_Technique.
// Ray_Traced, with Ray_Query. They are the screen-space reflections' frame (see screen_reflections.odin), with its
// lit scene, resolve and temporal pass, and a trace of their own: after the prepass, on the compute queue, a ray from
// one pixel of each block of the level's stride, sampled by its roughness as the screen-space reflections' are, marches
// the screen for the level's steps, and where the screen does not show its hit, traces the ray scene. Hit shading
// evaluates the materials at the hits, as a batch of their own, the global illumination's hit light passes light them,
// with the world probes where they run, and a light pass gives a ray that found nothing the sky's cubemap, and one past
// the level's distance no weight, so the probes fill in.

// The engine's traced reflection shaders, by their .meta files.
RTR_TRACE_SHADER :: #load("../content/shaders/rtr_trace.hlsl.meta", string)
RTR_LIGHT_SHADER :: #load("../content/shaders/rtr_light.hlsl.meta", string)

// The light that the hits' light pass writes for each ray: a float4 of its light and its distance.
RTR_LIGHT_STRIDE :: 16

// Traced_Reflections is the traced reflections' state between frames, in the Renderer: their pipelines, and their rays'
// buffers, which grow to the most rays that a frame has traced.
Traced_Reflections :: struct {
	trace:    Shader_Pipeline,
	light:    Shader_Pipeline,
	hits:     gpu.Buffer,
	surfaces: gpu.Buffer,
	rays:     gpu.Buffer,
	capacity: int,
}

// Rtr_Trace_Push matches Rtr_Trace_Push in rtr_common.hlsli.
@(private = "file")
Rtr_Trace_Push :: struct {
	camera_offset: [4]f32,
	accel:         u32,
	hits:          u32,
	ray_count:     u32,
	padding:       u32,
}

// Rtr_Light_Push matches Rtr_Light_Push in rtr_light.hlsl.
@(private = "file")
Rtr_Light_Push :: struct {
	shadow_atlas: u32,
	shadow_mask:  u32,
	hits:         u32,
	light:        u32,
	rays:         u32,
	radiance:     u32,
	exposure:     u32,
	width:        u32,
	height:       u32,
	shaded:       u32,
}

#assert(size_of(Rtr_Trace_Push) <= 128 && size_of(Rtr_Light_Push) <= 128)

// Rtr_Frame is one frame's traced reflections, in frame memory: the rays' buffers, a ray for each trace texel, and what
// lights their hits.
@(private)
Rtr_Frame :: struct {
	hits:      Buffer,
	surfaces:  Buffer,
	rays:      Buffer,
	ray_count: u32,
	inputs:    Hit_Light_Inputs,
	// Whether hit shading shades the hits: without it, a ray that hit has no weight.
	shaded:    bool,
}

traced_reflections_init :: proc(t: ^Traced_Reflections) {
	t.trace = shader_pipeline(RTR_TRACE_SHADER)
	t.light = shader_pipeline(RTR_LIGHT_SHADER)
}

traced_reflections_destroy :: proc(t: ^Traced_Reflections, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&t.trace, platform)
	destroy_shader_pipeline(&t.light, platform)
	for b in ([]gpu.Buffer{t.hits, t.surfaces, t.rays}) {
		platform.gpu_destroy_buffer(b)
	}
}

// sync_traced_reflections updates the pipelines, with Ray_Query only.
@(private)
sync_traced_reflections :: proc(r: ^Renderer, force: bool) {
	if !r.caps.ray_query {
		return
	}
	t := &r.rtr
	assets := r.residency.assets
	sync_compute_pipeline(&t.trace, r.platform, assets, {label = "reflections ray trace"}, force)
	sync_compute_pipeline(&t.light, r.platform, assets, {label = "reflections ray light"}, force)
}

// begin_traced_reflections gives the frame's traced reflections, after build_scene and before add_ray_scene_passes, or
// nil when the frame cannot trace them: without Ray_Query, before their pipelines, hit shading's and the hits' light's
// have compiled, or without items to draw and a hit table to shade them with. Once the pipelines are ready, it requests
// the ray scene, whose first request makes the hit table from the next frame on.
@(private)
begin_traced_reflections :: proc(f: ^Frame) -> ^Rtr_Frame {
	r := f.renderer
	if !r.caps.ray_query {
		return nil
	}
	for p in ([]^Shader_Pipeline{&r.rtr.trace, &r.rtr.light, &r.ray_scene.bin_pipeline, &r.ray_scene.fallback, &r.gi.probes.light, &r.gi.probes.screen}) {
		if !pipeline_ready(r.platform, p) {
			return nil
		}
	}
	sf := f.scene_frame
	if !request_ray_scene(f) || sf == nil || len(sf.items) == 0 || sf.hit_instance_count == 0 {
		return nil
	}
	return new(Rtr_Frame, r.platform.frame_allocator)
}

// ensure_rtr_storage grows the rays' buffers to hold count rays.
@(private = "file")
ensure_rtr_storage :: proc(r: ^Renderer, count: int) {
	t := &r.rtr
	if count <= t.capacity {
		return
	}
	platform := r.platform
	for b in ([]gpu.Buffer{t.hits, t.surfaces, t.rays}) {
		platform.gpu_destroy_buffer(b)
	}
	t.capacity = max(count, t.capacity * 2)
	capacity := u32(t.capacity)
	t.hits = platform.gpu_create_buffer({size = capacity * size_of(Hit_Record), usage = {.Storage}, label = "reflections hits"}, nil)
	t.surfaces = platform.gpu_create_buffer({size = capacity * size_of(Hit_Surface), usage = {.Storage}, label = "reflections surfaces"}, nil)
	t.rays = platform.gpu_create_buffer({size = capacity * RTR_LIGHT_STRIDE, usage = {.Storage}, label = "reflections light"}, nil)
}

// add_traced_reflection_passes adds the traced reflections' trace, with the depth pyramid when it marches the screen
// first, their hit shading, the hits' light and the light pass, which write the trace's ray and radiance textures for
// the resolve. It is false, and adds nothing, when the frame's hits cannot be shaded after all, or an upload fails.
@(private)
add_traced_reflection_passes :: proc(f: ^Frame) -> bool {
	r := f.renderer
	sf := f.ssr
	tf := sf.traced
	if !hit_shading_ready(f) {
		return false
	}
	inputs, ok := hit_light_inputs(f, sf.params.distance, sf.lit)
	if !ok {
		return false
	}
	g := f.graph
	tf.inputs = inputs
	tf.ray_count = sf.trace_size.x * sf.trace_size.y
	ensure_rtr_storage(r, int(tf.ray_count))
	tf.hits = import_buffer(g, r.rtr.hits)
	tf.surfaces = import_buffer(g, r.rtr.surfaces)
	tf.rays = import_buffer(g, r.rtr.rays)
	if sf.constants.steps > 0 {
		add_ssr_depth(f)
	}
	create_ssr_rays(f)

	p := add_compute_pass(g, "reflections ray trace", run_rtr_trace, f, queue = .Compute)
	declare_ssr_surface(f, p)
	if sf.constants.steps > 0 {
		for level in sf.levels {
			read(g, p, level)
		}
	}
	read(g, p, sf.lit.previous)
	read(g, p, f.exposure)
	read_accel(g, p, ray_scene_accel(f))
	write(g, p, tf.hits)
	write(g, p, sf.rays[0])
	write(g, p, sf.radiance[0])

	// hit_shading_ready said that it can, but for an upload.
	tf.shaded = add_hit_shading(f, {hits = tf.hits, surfaces = tf.surfaces, count = tf.ray_count}, .Compute, "reflections")
	if tf.shaded {
		add_hit_light_passes(f, &tf.inputs, "reflections hit", tf.hits, tf.surfaces, tf.rays, tf.ray_count)
	}

	p = add_compute_pass(g, "reflections ray light", run_rtr_light, f, queue = .Compute)
	read(g, p, tf.hits)
	if tf.shaded {
		read(g, p, tf.rays)
	}
	read(g, p, f.exposure)
	write(g, p, sf.rays[0])
	write(g, p, sf.radiance[0])
	return true
}

@(private = "file")
run_rtr_trace :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	r := f.renderer
	sf := f.ssr
	tf := sf.traced
	g := ctx.graph
	c := ssr_constants(ctx, f)
	if c.steps > 0 {
		for level, i in sf.levels {
			c.levels[i / 4][i % 4] = gpu.read_index(gpu_texture(g, level))
		}
	}
	c.lit = gpu.read_index(gpu_texture(g, sf.lit.previous))
	c.exposure = gpu.read_index(gpu_buffer(g, f.exposure))
	c.rays[0] = gpu.write_index(gpu_texture(g, sf.rays[0]))
	c.rays[2] = gpu.write_index(gpu_texture(g, sf.radiance[0]))
	offset := ecs.position_sub(f.view.position, r.scene.origin)
	push := Rtr_Trace_Push {
		camera_offset = {offset.x, offset.y, offset.z, 0},
		accel         = gpu.read_index(gpu_accel(g, ray_scene_accel(f))),
		hits          = gpu.write_index(gpu_buffer(g, tf.hits)),
		ray_count     = tf.ray_count,
	}
	upload, ok := r.platform.gpu_upload(size_of(Ssr_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return
	}
	(^Ssr_Constants)(raw_data(upload.data))^ = c
	gpu.cmd_set_pipeline(ctx.cb, r.rtr.trace.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, upload)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(sf.trace_size, POST_GROUP_SIZE))
}

@(private = "file")
run_rtr_light :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	r := f.renderer
	sf := f.ssr
	tf := sf.traced
	g := ctx.graph
	push := Rtr_Light_Push {
		hits     = gpu.read_index(gpu_buffer(g, tf.hits)),
		rays     = gpu.write_index(gpu_texture(g, sf.rays[0])),
		radiance = gpu.write_index(gpu_texture(g, sf.radiance[0])),
		exposure = gpu.read_index(gpu_buffer(g, f.exposure)),
		width    = sf.trace_size.x,
		height   = sf.trace_size.y,
		shaded   = u32(tf.shaded),
	}
	if tf.shaded {
		push.light = gpu.read_index(gpu_buffer(g, tf.rays))
	}
	gpu.cmd_set_pipeline(ctx.cb, r.rtr.light.pipeline)
	gpu.cmd_set_pass_constants(ctx.cb, f.scene_frame.view_constants[VIEW_CAMERA])
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(sf.trace_size, POST_GROUP_SIZE))
}

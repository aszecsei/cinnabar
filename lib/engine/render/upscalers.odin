package render

import "core:log"
import "core:math"
import "core:math/linalg"

import "cinnabar:core"
import "cinnabar:core/gpu"

// The vendors' upscalers (see docs/rendering/anti-aliasing.md#fsr): FSR, as the quality chooses in temporal AA's
// place, through the GPU interface's upscalers (see docs/gpu/upscalers.md#upscalers). Like temporal AA, it takes the
// jittered scene and upscales it into a new scene at the frame's size, with its own history; it reads the prepass's
// velocity, with the camera's motion where the prepass drew nothing, which the motion pass adds. The motion pass also
// writes how much moment-based transparency and the sprites cover each pixel, which the upscaler takes as its reactive
// and transparency masks, so what moves without velocity does not trail.

UPSCALE_MOTION_SHADER :: #load("../content/shaders/upscale_motion.hlsl.meta", string)

// The motion that the upscalers read: the velocity, in UV, from where a pixel's surface was to where it is.
MOTION_FORMAT :: VELOCITY_FORMAT
// The transparent surfaces' mask that the upscalers read: their coverage, 1 - e^-b0, from moment-based transparency's
// optical depth.
UPSCALE_MASK_FORMAT :: gpu.Format.R8_Unorm

// Upscalers is the upscalers' state between frames, in Post. One upscaler upscales into the frame's size; a frame of
// another size, or another technique, makes a new one.
Upscalers :: struct {
	motion:      Shader_Pipeline,
	upscaler:    gpu.Upscaler,
	// What upscaler was made for, or failed to be made for, which is not tried again.
	desc:        gpu.Upscaler_Desc,
	failed:      bool,
	// The last frame's upscale: whether there was one, and its render size. The history starts again when either
	// changes.
	active:      bool,
	render_size: [2]u32,
}

// Motion_Push matches Push in upscale_motion.hlsl.
@(private = "file")
Motion_Push :: struct {
	reproject:      matrix[4, 4]f32,
	jitter:         [2]f32,
	inverse_size:   [2]f32,
	size:           [2]u32,
	velocity:       u32,
	depth:          u32,
	output:         u32,
	// Zero without a mask.
	moments_zeroth: u32,
	mask:           u32,
}

#assert(size_of(Motion_Push) <= gpu.MAX_PUSH_CONSTANTS_SIZE)

upscalers_init :: proc(u: ^Upscalers) {
	u.motion = shader_pipeline(UPSCALE_MOTION_SHADER)
}

upscalers_destroy :: proc(u: ^Upscalers, platform: ^core.Platform_API) {
	destroy_shader_pipeline(&u.motion, platform)
	if u.upscaler != {} {
		platform.gpu_destroy_upscaler(u.upscaler)
	}
	u^ = {}
}

@(private)
sync_upscaler_pipelines :: proc(r: ^Renderer, force: bool) {
	sync_compute_pipeline(&r.post.upscalers.motion, r.platform, r.residency.assets, {label = "upscale motion"}, force)
}

// upscaler_kind is the GPU interface's upscaler that an anti-aliasing technique runs, if it runs one.
upscaler_kind :: proc(technique: Aa_Technique) -> (kind: gpu.Upscaler_Kind, ok: bool) {
	#partial switch technique {
	case .Fsr:
		return .Fsr, true
	}
	return
}

// frame_upscaler is the upscaler that a frame with a technique upscales with, made the first time that the frame's
// size or the technique needs it, or nil while the motion pass compiles, or when the device cannot make one. It keeps
// the upscaler of the last frame that used one.
@(private)
frame_upscaler :: proc(f: ^Frame, technique: Aa_Technique) -> gpu.Upscaler {
	r := f.renderer
	u := &r.post.upscalers
	kind, ok := upscaler_kind(technique)
	if !ok || kind not_in r.caps.upscalers || !pipeline_ready(r.platform, &u.motion) || r.platform.gpu_create_upscaler == nil {
		return {}
	}
	desc := gpu.Upscaler_Desc {
		kind            = kind,
		flags           = {.Hdr, .Depth_Reversed, .Depth_Infinite},
		max_render_size = f.output_size,
		output_size     = f.output_size,
		label           = "upscaler",
	}
	if desc == u.desc && (u.upscaler != {} || u.failed) {
		return u.upscaler
	}
	if u.upscaler != {} {
		r.platform.gpu_destroy_upscaler(u.upscaler)
	}
	u.upscaler = r.platform.gpu_create_upscaler(desc)
	u.desc, u.failed, u.active = desc, u.upscaler == {}, false
	if u.failed {
		log.errorf("render: no %v upscaler into %v: temporal AA stands in", kind, desc.output_size)
	} else {
		log.debugf("render: %v upscales into %v", kind, desc.output_size)
	}
	return u.upscaler
}

// add_upscale adds the motion pass and the upscale, after the before_temporal_aa effects, and makes the upscaled scene
// Frame.scene, at the frame's size.
@(private)
add_upscale :: proc(f: ^Frame) {
	pf := f.post
	g := f.graph
	pf.reproject = f.previous_view_projection * linalg.matrix4_translate_f32(f.camera_motion) * linalg.inverse(f.view_projection)
	pf.motion = create_texture(g, {size = f.size, format = MOTION_FORMAT, label = "upscale motion"})
	pass := add_compute_pass(g, "upscale motion", run_motion, f)
	read(g, pass, f.velocity)
	read(g, pass, f.depth)
	write(g, pass, pf.motion)
	// The overdraw view counts layers in the moments, not their optical depth.
	if f.moments_zeroth != 0 && f.debug_view != .Transparent_Overdraw {
		pf.upscale_mask = create_texture(g, {size = f.size, format = UPSCALE_MASK_FORMAT, label = "upscale mask"})
		read(g, pass, f.moments_zeroth)
		write(g, pass, pf.upscale_mask)
	}

	pf.temporal_in = f.scene
	pf.upscaled = create_texture(g, {size = f.output_size, format = SCENE_FORMAT, label = "upscaled scene"})
	pass = add_compute_pass(g, "upscale", run_upscale, f)
	read(g, pass, f.scene)
	read(g, pass, f.depth)
	read(g, pass, pf.motion)
	if pf.upscale_mask != 0 {
		read(g, pass, pf.upscale_mask)
	}
	write(g, pass, pf.upscaled)
	f.scene, f.scene_size = pf.upscaled, f.output_size
}

@(private = "file")
run_motion :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	push := Motion_Push {
		reproject    = f.post.reproject,
		jitter       = f.jitter,
		inverse_size = {1 / f32(f.size.x), 1 / f32(f.size.y)},
		size         = f.size,
		velocity     = gpu.read_index(gpu_texture(g, f.velocity)),
		depth        = gpu.read_index(gpu_texture(g, f.depth)),
		output       = gpu.write_index(gpu_texture(g, f.post.motion)),
	}
	if f.post.upscale_mask != 0 {
		push.moments_zeroth = gpu.read_index(gpu_texture(g, f.moments_zeroth))
		push.mask = gpu.write_index(gpu_texture(g, f.post.upscale_mask))
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.post.upscalers.motion.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

// run_upscale gives the upscaler the jitter in the scene's pixels, y down, and the motion from where a surface is to
// where it was, in the scene's pixels: the velocity's opposite. The transparent surfaces' mask is both its reactive
// mask and its transparency mask. The first frame has no time since the last, so it takes a 60th of a second.
@(private = "file")
run_upscale :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	pf := f.post
	g := ctx.graph
	size := [2]f32{f32(f.size.x), f32(f.size.y)}
	mask: gpu.Texture
	if pf.upscale_mask != 0 {
		mask = gpu_texture(g, pf.upscale_mask)
	}
	gpu.cmd_upscale(
		ctx.cb,
		{
			upscaler = pf.upscaler,
			color = gpu_texture(g, pf.temporal_in),
			depth = gpu_texture(g, f.depth),
			motion = gpu_texture(g, pf.motion),
			reactive = mask,
			transparency = mask,
			output = gpu_texture(g, pf.upscaled),
			render_size = f.size,
			jitter = f.jitter * [2]f32{0.5, -0.5} * size,
			motion_scale = -size,
			delta_time = pf.delta > 0 ? pf.delta : 1.0 / 60,
			near = f.view.near,
			far = math.F32_MAX,
			fov_y = f.view.vertical_fov,
			reset = b32(pf.upscale_reset),
		},
	)
}

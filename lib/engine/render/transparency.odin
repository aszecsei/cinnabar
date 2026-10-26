package render

import "cinnabar:core/gpu"

// Transparency (see docs/rendering/transparency.md#transparency): the transparent and additive surfaces draw after the opaque ones,
// test their depth and write none. A Transparent material draws with moment-based order-independent transparency by
// default: a pass adds up each pixel's optical depth and its moments, a second shades each surface dimmed by the
// transmittance in front of it that the moments give and adds them up, and a compute pass composites the sum over the
// scene. A sorted material, and an additive one, draws back to front over the scene, an item at a time. The editor gets
// the IDs and the depth of the surfaces wherever they show, after post-processing.

TRANSPARENCY_COMPOSITE_SHADER :: #load("../content/shaders/transparency_composite.hlsl.meta", string)

// The moments: each pixel's optical depth, b0, and its four power moments, weighted by it. 16-bit moments would need
// the paper's quantization to stay stable, so they are 32-bit (see MOMENT_BIAS in moments.hlsli).
MOMENTS_ZEROTH_FORMAT :: gpu.Format.R32_Float
MOMENTS_FORMAT :: gpu.Format.RGBA32_Float
// The transparent surfaces' light, premultiplied by their opacity and the transmittance in front of them, and that
// opacity, pre-exposed.
ACCUMULATED_FORMAT :: gpu.Format.RGBA16_Float

MOMENT_COLORS :: []gpu.Color_Target{{format = MOMENTS_ZEROTH_FORMAT, blend = .Additive}, {format = MOMENTS_FORMAT, blend = .Additive}}
ACCUMULATED_COLORS :: []gpu.Color_Target{{format = ACCUMULATED_FORMAT, blend = .Additive}}
// The sorted draws' targets: the scene, under premultiplied colors or additive ones.
OVER_COLORS :: []gpu.Color_Target{{format = SCENE_FORMAT, blend = .Premultiplied}}
ADDITIVE_COLORS :: []gpu.Color_Target{{format = SCENE_FORMAT, blend = .Additive}}
TRANSPARENT_ID_COLORS :: []gpu.Color_Target{{format = ID_FORMAT}}
// The depth bias of the transparent passes' pipelines, toward the camera, since depth is reversed. A transparent face in
// the plane of an opaque one, such as the bottom of a glass box on a floor, then always passes the depth test. Without
// it, which of the two is in front changes from pixel to pixel with rounding, and from frame to frame with temporal
// AA's jitter, so the face flickers.
TRANSPARENT_DEPTH_BIAS :: 16
TRANSPARENT_SLOPE_BIAS :: 1

// Composite_Push matches Push in transparency_composite.hlsl.
@(private = "file")
Composite_Push :: struct {
	moments_zeroth: u32,
	accumulated:    u32,
	scene:          u32,
	padding:        u32,
	size:           [2]u32,
}

// Composite_Frame is the composite pass's textures, in frame memory.
@(private = "file")
Composite_Frame :: struct {
	frame:       ^Frame,
	accumulated: Texture,
	scene:       Texture,
}

// has_group is whether the frame draws any item of a group.
@(private)
has_group :: proc(f: ^Frame, group: Bin_Group) -> bool {
	sf := f.scene_frame
	return sf != nil && len(sf.items) > 0 && sf.groups[group][1] > sf.groups[group][0]
}

// has_transparency is whether the frame draws transparent or additive surfaces, which test the scene's depth after
// the world pass.
@(private)
has_transparency :: proc(f: ^Frame) -> bool {
	return has_group(f, .Moments) || has_group(f, .Sorted)
}

// add_transparency_passes adds the transparent surfaces' passes after the world pass: moment-based transparency's
// moments, its transparent pass and its composite, then the sorted draws over the result. Without the composite's
// pipeline, moment-based transparency draws nothing. In the overdraw debug view, the moments pass counts every
// transparent layer, the sorted ones too, and nothing else draws.
@(private)
add_transparency_passes :: proc(f: ^Frame) {
	r := f.renderer
	g := f.graph
	overdraw := f.debug_view == .Transparent_Overdraw
	moments := has_group(f, .Moments) && pipeline_ready(r.platform, &r.transparency_composite)
	if overdraw {
		moments = has_transparency(f)
	}
	if moments {
		f.moments_zeroth = create_texture(g, {size = f.size, format = MOMENTS_ZEROTH_FORMAT, label = "moments zeroth"})
		f.moments = create_texture(g, {size = f.size, format = MOMENTS_FORMAT, label = "moments"})
		p := add_render_pass(g, "transparent moments", proc(ctx: ^Pass_Context) {
			f := (^Frame)(ctx.data)
			for view in ([]int{VIEW_VIEW_MODEL, VIEW_CAMERA}) {
				draw_scene_view(f, ctx.cb, view, .Moments, .Moments)
				if f.debug_view == .Transparent_Overdraw {
					draw_scene_view(f, ctx.cb, view, .Moments, .Sorted)
				}
			}
		}, f)
		color(g, p, f.moments_zeroth, .Clear)
		color(g, p, f.moments, .Clear)
		depth(g, p, f.depth, .Load)
		declare_scene_draws(f, p)
	}
	if overdraw {
		return
	}
	if moments {
		cf := new(Composite_Frame, r.platform.frame_allocator)
		cf^ = {frame = f, accumulated = create_texture(g, {size = f.size, format = ACCUMULATED_FORMAT, label = "transparent light"}), scene = f.scene}
		p := add_render_pass(g, "transparent", proc(ctx: ^Pass_Context) {
			f := (^Frame)(ctx.data)
			draw_scene_view(f, ctx.cb, VIEW_VIEW_MODEL, .Transparent, .Moments)
			draw_scene_view(f, ctx.cb, VIEW_CAMERA, .Transparent, .Moments)
		}, f)
		color(g, p, cf.accumulated, .Clear)
		depth(g, p, f.depth, .Load)
		declare_scene_draws(f, p)
		declare_lighting(f, p, opaque = false)
		read(g, p, f.moments_zeroth)
		read(g, p, f.moments)
		p = add_compute_pass(g, "transparency composite", run_composite, cf)
		read(g, p, f.moments_zeroth)
		read(g, p, cf.accumulated)
		write(g, p, f.scene)
	}
	if has_group(f, .Sorted) {
		p := add_render_pass(g, "sorted transparent", proc(ctx: ^Pass_Context) {
			f := (^Frame)(ctx.data)
			draw_scene_view(f, ctx.cb, VIEW_VIEW_MODEL, .Transparent, .Sorted)
			draw_scene_view(f, ctx.cb, VIEW_CAMERA, .Transparent, .Sorted)
		}, f)
		color(g, p, f.scene, .Load)
		depth(g, p, f.depth, .Load)
		declare_scene_draws(f, p)
		declare_lighting(f, p, opaque = false)
	}
}

// add_transparent_id_pass adds the editor's pass of the transparent surfaces' IDs and depth, wherever they show, so its
// picking and its tools see them. It runs after post-processing, so the frame looks as the game's does.
@(private)
add_transparent_id_pass :: proc(f: ^Frame, keep_ids: bool) {
	if !keep_ids || !has_transparency(f) {
		return
	}
	g := f.graph
	p := add_render_pass(g, "transparent ids", proc(ctx: ^Pass_Context) {
		f := (^Frame)(ctx.data)
		for view in ([]int{VIEW_VIEW_MODEL, VIEW_CAMERA}) {
			draw_scene_view(f, ctx.cb, view, .Transparent_Ids, .Moments)
			draw_scene_view(f, ctx.cb, view, .Transparent_Ids, .Sorted)
		}
	}, f)
	color(g, p, f.ids, .Load)
	depth(g, p, f.depth, .Load)
	declare_scene_draws(f, p)
}

// declare_lighting declares what the forward template reads: the exposure, the clusters, the shadow maps, the fog
// volume and the global illumination, and for opaque surfaces the shadow mask and the ambient occlusion.
@(private)
declare_lighting :: proc(f: ^Frame, p: Pass, opaque: bool) {
	g := f.graph
	read(g, p, f.exposure)
	if f.lights.clustered {
		read(g, p, f.lights.clusters)
		read(g, p, f.lights.indices)
	}
	if f.shadows.atlas != 0 {
		read(g, p, f.shadows.atlas)
	}
	if f.fog_volume != 0 {
		read(g, p, f.fog_volume)
	}
	if f.gi_diffuse != 0 {
		read(g, p, f.gi_diffuse)
		read(g, p, f.gi_specular)
	}
	if !opaque {
		return
	}
	if f.shadows.mask != 0 {
		read(g, p, f.shadows.mask)
	}
	if f.ambient_occlusion != 0 {
		read(g, p, f.ambient_occlusion)
	}
}

@(private = "file")
run_composite :: proc(ctx: ^Pass_Context) {
	cf := (^Composite_Frame)(ctx.data)
	f := cf.frame
	g := ctx.graph
	push := Composite_Push {
		moments_zeroth = gpu.read_index(gpu_texture(g, f.moments_zeroth)),
		accumulated    = gpu.read_index(gpu_texture(g, cf.accumulated)),
		scene          = gpu.write_index(gpu_texture(g, cf.scene)),
		size           = f.size,
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.transparency_composite.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

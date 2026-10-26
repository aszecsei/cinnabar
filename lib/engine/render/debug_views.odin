package render

import "cinnabar:core/gpu"

// Debug views (see docs/rendering.md#debug-views): the editor's views of what makes the frame, in place of the lit
// scene, and features that it turns off in its viewport.

DEBUG_VIEW_SHADER :: #load("../content/shaders/debug_view.hlsl.meta", string)

// Debug_View is what the frame shows. The forward pass draws the views up to Shadow_Cascades, and a pass from the
// frame's textures the rest. Matches DEBUG_* in material_common.hlsli and debug_view.hlsl.
Debug_View :: enum u8 {
	Lit,
	// The lighting on a grey surface, without emission.
	Lighting_Only,
	// Only the lights' light, or only the indirect light.
	Direct_Light,
	Indirect_Light,
	// Only the light that the fog scatters toward the camera.
	Fog,
	// The surface's base color, or an unlit surface's color.
	Albedo,
	// The number of lights that shade each pixel, as heat colors to 16.
	Light_Complexity,
	// The directional lights' cascade at each pixel: red, green, blue, yellow, then grey beyond.
	Shadow_Cascades,
	Normals,
	// On a log scale from the near plane to 1 km.
	Depth,
	Velocity,
	Ambient_Occlusion,
	Gi_Diffuse,
	Gi_Specular,
	// Each traced light's channel in its own color.
	Shadow_Mask,
	// Each entity in a color of its own.
	Entity_Ids,
	// EV100 as heat colors, from -4 to 16.
	Luminance,
	// The number of transparent surfaces at each pixel, as heat colors from 1 to 8, which the moments pass counts.
	Transparent_Overdraw,
}

// Feature is a part of the frame that the editor's viewport can turn off.
Feature :: enum u8 {
	Temporal_Aa,
	Bloom,
	// Without it, a plain roll-off to white in place of the tone mapper and the grading.
	Tone_Mapping,
	Fog,
	Ambient_Occlusion,
	Gi,
	Shadows,
	// The game's post effects.
	Post_Effects,
}

Features :: bit_set[Feature;u16]

// debug_view_shaded is whether a view is exposed and tone mapped, as the lit scene is. The others are colors as they
// are, which the output pass only encodes.
debug_view_shaded :: proc(view: Debug_View) -> bool {
	#partial switch view {
	case .Lit, .Lighting_Only, .Direct_Light, .Indirect_Light, .Fog, .Gi_Diffuse, .Gi_Specular:
		return true
	}
	return false
}

// debug_view_from_textures is whether a view comes from the frame's textures, not the forward pass.
debug_view_from_textures :: proc(view: Debug_View) -> bool {
	return view > .Shadow_Cascades
}

// apply_debug turns off what a debug view and the disabled features leave out of the frame's settings, and adds the
// exposure offset in stops. A view other than Lit has no bloom and no post effects, and a view that is not shaded no
// temporal AA and no fog, so its colors stay as they are.
@(private)
apply_debug :: proc(s: ^Frame_Settings, view: Debug_View, disable: Features, exposure_offset: f32) {
	shaded := debug_view_shaded(view)
	s.post.no_temporal_aa ||= .Temporal_Aa in disable || !shaded
	s.post.no_bloom ||= .Bloom in disable || view != .Lit
	s.post.exposure_compensation += exposure_offset
	if .Fog in disable || (!shaded && view != .Fog) {
		s.fog.density = 0
	}
	s.ambient_occlusion.off ||= .Ambient_Occlusion in disable
	s.gi.off ||= .Gi in disable
}

// Debug_View_Push matches Push in debug_view.hlsl.
@(private = "file")
Debug_View_Push :: struct {
	view:          u32,
	source:        u32,
	output:        u32,
	exposure:      u32,
	size:          [2]u32,
	near:          f32,
	mask_channels: u32,
}

// Debug_View_Frame is the pass of a view from the frame's textures, in frame memory.
@(private = "file")
Debug_View_Frame :: struct {
	frame:  ^Frame,
	source: Texture,
	output: Texture,
}

// add_debug_view_pass writes a view from the frame's textures into a new scene color, before post-processing. A view
// whose texture the frame does not have, such as the global illumination when it is off, is black.
@(private)
add_debug_view_pass :: proc(f: ^Frame) {
	r := f.renderer
	if !debug_view_from_textures(f.debug_view) || !pipeline_ready(r.platform, &r.debug_view) {
		return
	}
	source: Texture
	#partial switch f.debug_view {
	case .Normals:
		source = f.normals
	case .Depth:
		source = f.depth
	case .Velocity:
		source = f.velocity
	case .Ambient_Occlusion:
		source = f.ambient_occlusion
	case .Gi_Diffuse:
		source = f.gi_diffuse
	case .Gi_Specular:
		source = f.gi_specular
	case .Shadow_Mask:
		source = f.shadows != nil ? f.shadows.mask : 0
	case .Entity_Ids:
		source = f.ids
	case .Luminance:
		source = f.scene
	case .Transparent_Overdraw:
		source = f.moments_zeroth
	}
	g := f.graph
	dv := new(Debug_View_Frame, r.platform.frame_allocator)
	dv^ = {frame = f, source = source, output = create_texture(g, {size = f.size, format = SCENE_FORMAT, label = "debug view"})}
	p := add_compute_pass(g, "debug view", run_debug_view, dv)
	if source != 0 {
		read(g, p, source)
	}
	read(g, p, f.exposure)
	write(g, p, dv.output)
	f.scene = dv.output
}

@(private = "file")
run_debug_view :: proc(ctx: ^Pass_Context) {
	dv := (^Debug_View_Frame)(ctx.data)
	f := dv.frame
	g := ctx.graph
	push := Debug_View_Push {
		// With nothing to show, a view that the shader does not know, which is black.
		view     = dv.source != 0 ? u32(f.debug_view) : max(u32),
		output   = gpu.write_index(gpu_texture(g, dv.output)),
		exposure = gpu.read_index(gpu_buffer(g, f.exposure)),
		size     = f.size,
		near     = f.view.near,
	}
	if f.shadows != nil {
		push.mask_channels = u32(f.shadows.mask_count)
	}
	if dv.source != 0 {
		push.source = gpu.read_index(gpu_texture(g, dv.source))
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.debug_view.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_dispatch(ctx.cb, groups(f.size, POST_GROUP_SIZE))
}

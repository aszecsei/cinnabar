package render

import "core:mem"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/asset"
import "cinnabar:engine/debug"
import "cinnabar:engine/ecs"

// The frame's targets (see docs/rendering.md#layers). The world draws into linear HDR colors, the editor's entity IDs
// and reversed depth, which the prepass writes with the normals and the velocities (see PREPASS_COLORS). The UI is premultiplied and sRGB-encoded, and blends as encoded values. The debug layer has an
// sRGB view, so it blends in linear light, and the output pass encodes it.
SCENE_FORMAT :: gpu.Format.RGBA16_Float
// Each pixel holds entity_id of the entity drawn there, or 0. The editor picks from it.
ID_FORMAT :: gpu.Format.R32_Uint
DEPTH_FORMAT :: gpu.Format.D32_Float
UI_FORMAT :: gpu.Format.RGBA8_Unorm
DEBUG_FORMAT :: gpu.Format.RGBA8_Unorm_Srgb
// The world pass's color targets, which a game's pipelines that draw in it use.
WORLD_COLORS :: []gpu.Color_Target{{format = SCENE_FORMAT}, {format = ID_FORMAT}}

// Debug lines are this many pixels wide, and the part that the scene hides draws with this alpha.
DEBUG_LINE_WIDTH :: 2
DEBUG_HIDDEN_ALPHA :: 0.3

// The engine's shaders for the debug layer and the output pass, by their .meta files.
DEBUG_SHADER :: #load("../content/shaders/debug.hlsl.meta", string)
OUTPUT_SHADER :: #load("../content/shaders/output.hlsl.meta", string)

// entity_id is an entity's value in the ID buffer: its slot + 1, so 0 is no entity.
entity_id :: proc "contextless" (entity: ecs.Entity) -> u32 {
	return ecs.entity_index(entity) + 1
}

// Renderer is the built-in renderer (see docs/rendering.md#frame). It lives in Game_State and holds handles only, so
// a code reload keeps it.
Renderer :: struct {
	platform:        ^core.Platform_API,
	residency:       Residency,
	textures:        Texture_Cache,
	// The lines that debug draws, which the debug layer draws each frame.
	debug:           debug.Draw,
	// A registration, created again in renderer_reload.
	meshes:          Extractor,
	materials:       Materials,
	scene:           Gpu_Scene,
	lights:          Lights,
	shadows:         Shadows,
	output_pipeline: Shader_Pipeline,
	debug_tested:    Shader_Pipeline,
	debug_hidden:    Shader_Pipeline,
	debug_overlay:   Shader_Pipeline,
	// A code reload may bring new descriptions, so the next frame updates every pipeline.
	reloaded:        bool,
}

// Frame_Desc is what a game gives draw_frame each frame. It lives in frame memory, and so do its hooks' data.
Frame_Desc :: struct {
	view:        View,
	size:        [2]u32,
	// Keeps the IDs and the depth after the frame's passes need them, for the editor's picking and outline.
	keep_ids:    bool,
	// The entity slots not to draw, a bit each, as the editor hides them. nil hides nothing.
	hidden:      []u32,
	// Scales the scene before tone mapping. 0 means 1.
	exposure:    f32,
	clear_color: [4]f32,
	// The light from everything else until global illumination. Zero gives DEFAULT_AMBIENT.
	ambient:     Ambient,
	hooks:       Frame_Hooks,
}

// Frame_Hooks add a game's passes and draws to the frame. Each is optional. They are procedures in the game, so a
// Frame_Desc never outlives its frame.
Frame_Hooks :: struct {
	// Given to every hook as Frame.data.
	data:         rawptr,
	// Adds passes before the prepass, such as culling.
	before_world:  proc(f: ^Frame),
	// Adds passes after the prepass, which can read Frame.depth, Frame.normals and Frame.velocity.
	after_prepass: proc(f: ^Frame),
	// Declares the world pass's other uses, such as the buffers that world_draw reads.
	world_uses:   proc(f: ^Frame, pass: Pass),
	// Records draws into the world pass, after the Mesh_Renderers in piece 0. The pass has world_pieces pieces.
	world_draw:   proc(f: ^Frame, ctx: ^Pass_Context),
	world_pieces: int,
	// Adds passes after the world pass. A pass that makes a new scene color, such as post-processing, sets Frame.scene
	// to it, and the output pass tone maps that.
	after_world:  proc(f: ^Frame),
	// Adds the passes that draw the UI into Frame.ui, after a pass that clears it. They load it.
	ui:           proc(f: ^Frame),
	// Adds passes that draw into Frame.debug after the debug lines, such as the editor's tools. They load it.
	debug:        proc(f: ^Frame),
}

// Frame is one frame's targets and data, in frame memory, which the hooks and the passes share.
Frame :: struct {
	renderer:        ^Renderer,
	graph:           ^Graph,
	data:            rawptr,
	view:            View,
	size:            [2]u32,
	view_projection: matrix[4, 4]f32,
	scene:           Texture,
	ids:             Texture,
	depth:           Texture,
	normals:         Texture,
	velocity:        Texture,
	// Zero without a UI hook, and without debug lines or a debug hook.
	ui:              Texture,
	debug:           Texture,
	hooks:           Frame_Hooks,
	exposure:        f32,
	scene_frame:     ^Scene_Frame,
	lights:          ^Light_Frame,
	shadows:         ^Shadow_Frame,
	debug_lines:     gpu.Upload,
	tested_lines:    int,
	overlay_lines:   int,
}

// Debug_Vertex_Line matches Line in debug.hlsl.
Debug_Vertex_Line :: struct {
	a:       [3]f32,
	color:   u32,
	b:       [3]f32,
	padding: u32,
}

// Debug_Push matches Push in debug.hlsl.
Debug_Push :: struct {
	view_projection: matrix[4, 4]f32,
	lines:           u32,
	lines_offset:    u32,
	first_line:      u32,
	alpha:           f32,
	viewport:        [2]f32,
	width:           f32,
}

// Output_Push matches Push in output.hlsl.
Output_Push :: struct {
	scene:     u32,
	ui:        u32,
	debug:     u32,
	has_ui:    u32,
	has_debug: u32,
	exposure:  f32,
}

#assert(size_of(Debug_Push) <= 128 && size_of(Output_Push) <= 128)

renderer_init :: proc(r: ^Renderer, platform: ^core.Platform_API, assets: ^asset.Assets, w: ^ecs.World) {
	// The Renderer is too large for a temporary on the stack, so it is zeroed in place.
	mem.zero_item(r)
	r.platform = platform
	r.meshes = mesh_extractor(w)
	r.output_pipeline = shader_pipeline(OUTPUT_SHADER)
	r.debug_tested = shader_pipeline(DEBUG_SHADER)
	r.debug_hidden = shader_pipeline(DEBUG_SHADER)
	r.debug_overlay = shader_pipeline(DEBUG_SHADER)
	residency_init(&r.residency, platform, assets)
	debug.init(&r.debug, platform.heap_allocator)
	materials_init(&r.materials, platform)
	scene_init(&r.scene, platform)
	lights_init(&r.lights, platform, w)
	shadows_init(&r.shadows, platform)
	r.residency.accels = r.shadows.ray_query
}

// mesh_extractor selects the entities with a Mesh_Renderer.
@(private = "file")
mesh_extractor :: proc(w: ^ecs.World) -> Extractor {
	return extractor(w, {ecs.read(w, Mesh_Renderer)})
}

// renderer_reload keeps the renderer after a code reload, and makes its registrations again.
renderer_reload :: proc(r: ^Renderer, platform: ^core.Platform_API, w: ^ecs.World) {
	r.platform = platform
	r.meshes = mesh_extractor(w)
	lights_register(&r.lights, w)
	r.reloaded = true
	residency_reload(&r.residency, platform)
	materials_reload(&r.materials)
}

renderer_destroy :: proc(r: ^Renderer) {
	residency_destroy(&r.residency)
	cache_destroy(&r.textures, r.platform)
	debug.destroy(&r.debug)
	materials_destroy(&r.materials, r.platform)
	scene_destroy(&r.scene, r.platform)
	lights_destroy(&r.lights, r.platform)
	shadows_destroy(&r.shadows, r.platform)
	for p in ([]^Shader_Pipeline{&r.output_pipeline, &r.debug_tested, &r.debug_hidden, &r.debug_overlay}) {
		destroy_shader_pipeline(p, r.platform)
	}
}

// draw_frame draws a frame into the frame target: the world, the UI and the debug layer, combined by the output pass
// (see docs/rendering.md#frame). The world draws in a prepass, then in the forward pass with the lights' clusters and
// the shadows. It returns false if the graph could not execute.
draw_frame :: proc(r: ^Renderer, w: ^ecs.World, desc: Frame_Desc) -> bool {
	residency_update(&r.residency)
	sync_frame_pipelines(r)
	g := begin(r.platform, &r.textures)
	f := new(Frame, r.platform.frame_allocator)
	f^ = {
		renderer        = r,
		graph           = &g,
		data            = desc.hooks.data,
		view            = desc.view,
		size            = desc.size,
		view_projection = view_projection(desc.view, f32(desc.size.x) / f32(max(desc.size.y, 1))),
		hooks           = desc.hooks,
		exposure        = desc.exposure > 0 ? desc.exposure : 1,
	}
	target := import_texture(&g, r.platform.gpu_frame_target(), .Color)
	f.scene = create_texture(&g, {size = desc.size, format = SCENE_FORMAT, label = "scene"})
	f.ids = create_texture(&g, {size = desc.size, format = ID_FORMAT, label = "entity ids"})
	f.depth = create_texture(&g, {size = desc.size, format = DEPTH_FORMAT, label = "scene depth"})
	f.normals = create_texture(&g, {size = desc.size, format = NORMAL_FORMAT, label = "scene normals"})
	f.velocity = create_texture(&g, {size = desc.size, format = VELOCITY_FORMAT, label = "scene velocity"})
	build_scene(f, w, desc.hidden)
	f.lights = extract_lights(f, w, desc.hidden)
	assign_shadows(f)
	upload_lights(f)
	add_scene_passes(f, desc.ambient == {} ? DEFAULT_AMBIENT : desc.ambient)
	lines := debug.frame_lines(&r.debug)
	has_debug := len(lines) > 0 || desc.hooks.debug != nil

	if desc.hooks.before_world != nil {
		desc.hooks.before_world(f)
	}
	p := add_render_pass(&g, "prepass", proc(ctx: ^Pass_Context) {
		draw_scene_view((^Frame)(ctx.data), ctx.cb, 0, .Prepass)
	}, f)
	color(&g, p, f.normals, .Clear)
	color(&g, p, f.velocity, .Clear)
	depth(&g, p, f.depth, .Clear)
	declare_scene_draws(f, p)
	if desc.hooks.after_prepass != nil {
		desc.hooks.after_prepass(f)
	}
	add_cluster_passes(f)
	add_shadow_passes(f)

	p = add_render_pass(&g, "world", draw_world, f, pieces = max(desc.hooks.world_pieces, 1))
	color(&g, p, f.scene, .Clear, desc.clear_color)
	color(&g, p, f.ids, .Clear, store = desc.keep_ids ? .Store : .Discard)
	// The debug layer tests against the depth, and the editor reads it.
	depth(&g, p, f.depth, .Load, store = desc.keep_ids || has_debug ? .Store : .Discard)
	declare_scene_draws(f, p)
	if f.lights.clustered {
		read(&g, p, f.lights.clusters)
		read(&g, p, f.lights.indices)
	}
	if f.shadows.atlas != 0 {
		read(&g, p, f.shadows.atlas)
	}
	if f.shadows.mask != 0 {
		read(&g, p, f.shadows.mask)
	}
	if desc.hooks.world_uses != nil {
		desc.hooks.world_uses(f, p)
	}
	if desc.hooks.after_world != nil {
		desc.hooks.after_world(f)
	}

	if desc.hooks.ui != nil {
		f.ui = create_texture(&g, {size = desc.size, format = UI_FORMAT, label = "ui"})
		p = add_render_pass(&g, "clear ui", proc(_: ^Pass_Context) {}, f)
		color(&g, p, f.ui, .Clear)
		desc.hooks.ui(f)
	}

	if has_debug {
		f.debug = create_texture(&g, {size = desc.size, format = DEBUG_FORMAT, label = "debug"})
		upload_debug_lines(f, lines)
		p = add_render_pass(&g, "debug", draw_debug_lines, f)
		color(&g, p, f.debug, .Clear)
		depth(&g, p, f.depth, .Load, store = desc.keep_ids ? .Store : .Discard)
		if desc.hooks.debug != nil {
			desc.hooks.debug(f)
		}
	}

	p = add_render_pass(&g, "output", draw_output, f)
	read(&g, p, f.scene)
	if f.ui != 0 {
		read(&g, p, f.ui)
	}
	if f.debug != 0 {
		read(&g, p, f.debug)
	}
	color(&g, p, target, .Discard)

	ok := execute(&g)
	debug.end_frame(&r.debug)
	return ok
}

// sync_frame_pipelines creates the renderer's pipelines from their shaders, and updates those whose shaders changed,
// or all of them after a code reload.
@(private = "file")
sync_frame_pipelines :: proc(r: ^Renderer) {
	force := r.reloaded
	r.reloaded = false
	assets := r.residency.assets
	sync_graphics_pipeline(&r.output_pipeline, r.platform, assets, {.Vertex, .Pixel}, OUTPUT_PIPELINE, force)
	debug_desc := gpu.Graphics_Pipeline_Desc {
		colors       = {{format = DEBUG_FORMAT, blend = .Alpha}},
		depth_format = DEPTH_FORMAT,
	}
	debug_desc.depth_compare, debug_desc.label = .Greater_Equal, "debug lines"
	sync_graphics_pipeline(&r.debug_tested, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
	debug_desc.depth_compare, debug_desc.label = .Less, "debug lines (hidden)"
	sync_graphics_pipeline(&r.debug_hidden, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
	debug_desc.depth_compare, debug_desc.label = .Always, "debug lines (overlay)"
	sync_graphics_pipeline(&r.debug_overlay, r.platform, assets, {.Vertex, .Pixel}, debug_desc, force)
}

@(private = "file")
OUTPUT_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	colors = {{format = gpu.FRAME_TARGET_FORMAT}},
	label  = "output",
}

@(private = "file")
draw_world :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	if ctx.piece == 0 {
		draw_scene_view(f, ctx.cb, 0, .Forward)
	}
	if f.hooks.world_draw != nil {
		f.hooks.world_draw(f, ctx)
	}
}

// upload_debug_lines writes the lines relative to the camera, the tested ones first, then the overlay ones.
@(private = "file")
upload_debug_lines :: proc(f: ^Frame, lines: []debug.Line) {
	upload, ok := f.renderer.platform.gpu_upload(max(len(lines), 1) * size_of(Debug_Vertex_Line), 16)
	if !ok {
		return
	}
	records := ([^]Debug_Vertex_Line)(raw_data(upload.data))[:len(lines)]
	pack :: proc(c: [4]f32) -> u32 {
		packed: u32
		for ch, i in c {
			packed |= u32(clamp(ch, 0, 1) * 255 + 0.5) << (u32(i) * 8)
		}
		return packed
	}
	next := 0
	for mode in debug.Mode {
		for l in lines {
			if l.mode == mode {
				records[next] = {a = ecs.position_sub(l.a, f.view.position), b = ecs.position_sub(l.b, f.view.position), color = pack(l.color)}
				next += 1
			}
		}
		if mode == .Tested {
			f.tested_lines = next
		}
	}
	f.overlay_lines = next - f.tested_lines
	f.debug_lines = upload
}

@(private = "file")
draw_debug_lines :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	r := f.renderer
	if f.tested_lines + f.overlay_lines == 0 {
		return
	}
	push := Debug_Push {
		view_projection = f.view_projection,
		lines           = gpu.read_index(f.debug_lines.buffer),
		lines_offset    = f.debug_lines.offset,
		viewport        = {f32(f.size.x), f32(f.size.y)},
		width           = DEBUG_LINE_WIDTH,
	}
	draw :: proc(cb: ^gpu.Command_Buffer, pipeline: gpu.Pipeline, push: ^Debug_Push, first, count: int, alpha: f32) {
		// A pipeline that does not exist yet, because its shader is not cooked, draws nothing.
		if count == 0 || pipeline == {} {
			return
		}
		push.first_line, push.alpha = u32(first), alpha
		gpu.cmd_set_pipeline(cb, pipeline)
		gpu.cmd_push_constants(cb, push)
		gpu.cmd_draw(cb, u32(count * 6))
	}
	draw(ctx.cb, r.debug_hidden.pipeline, &push, 0, f.tested_lines, DEBUG_HIDDEN_ALPHA)
	draw(ctx.cb, r.debug_tested.pipeline, &push, 0, f.tested_lines, 1)
	draw(ctx.cb, r.debug_overlay.pipeline, &push, f.tested_lines, f.overlay_lines, 1)
}

@(private = "file")
draw_output :: proc(ctx: ^Pass_Context) {
	f := (^Frame)(ctx.data)
	g := ctx.graph
	if f.renderer.output_pipeline.pipeline == {} {
		return
	}
	push := Output_Push {
		scene    = gpu.read_index(gpu_texture(g, f.scene)),
		exposure = f.exposure,
	}
	if f.ui != 0 {
		push.ui, push.has_ui = gpu.read_index(gpu_texture(g, f.ui)), 1
	}
	if f.debug != 0 {
		push.debug, push.has_debug = gpu.read_index(gpu_texture(g, f.debug)), 1
	}
	gpu.cmd_set_pipeline(ctx.cb, f.renderer.output_pipeline.pipeline)
	gpu.cmd_push_constants(ctx.cb, &push)
	gpu.cmd_draw(ctx.cb, 3)
}

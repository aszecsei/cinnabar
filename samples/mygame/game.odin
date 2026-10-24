package mygame

import "core:fmt"
import "core:log"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/layout"
import "cinnabar:engine/render"

TRIANGLE_VS :: #load("shaders/triangle.vs.dxil")
TRIANGLE_PS :: #load("shaders/triangle.ps.dxil")
POST_CS :: #load("shaders/post.cs.dxil")
COMPOSITE_VS :: #load("shaders/composite.vs.dxil")
COMPOSITE_PS :: #load("shaders/composite.ps.dxil")

SCENE_FORMAT :: gpu.Format.RGBA16_Float
DEPTH_FORMAT :: gpu.Format.D32_Float
// Matches numthreads in shaders/post.hlsl.
POST_GROUP_SIZE :: 8

CHECKER_SIZE :: 64
CHECKER_CELL :: 8

// Matches Vertex in shaders/triangle.hlsl.
Vertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

// Matches Push in shaders/triangle.hlsl.
Scene_Constants :: struct {
	vertices: u32,
	texture:  u32,
	sampler:  u32,
}

// Matches Push in shaders/post.hlsl.
Post_Constants :: struct {
	input:  u32,
	output: u32,
	size:   [2]u32,
}

// Matches Push in shaders/composite.hlsl.
Composite_Constants :: struct {
	input:   u32,
	sampler: u32,
}

// Matches Pass in shaders/triangle.hlsl.
Pass_Constants :: struct {
	time:   f32,
	aspect: f32,
}

// Game_State is the root of all persistent game-side state. The host owns its memory.
Game_State :: struct {
	platform:    ^core.Platform_API,
	frame_count: u64,
	elapsed:     time.Duration,
	next_report: time.Duration,
	pipelines:   Pipelines,
	vertices:    gpu.Buffer,
	indices:     gpu.Buffer,
	checker:     gpu.Texture,
	nearest:     gpu.Sampler,
	linear:      gpu.Sampler,
	textures:    render.Texture_Cache,
}

Pipelines :: struct {
	scene:     gpu.Pipeline,
	post:      gpu.Pipeline,
	composite: gpu.Pipeline,
}

// Frame is what the pass procedures need. It lives in frame memory.
Frame :: struct {
	state:          ^Game_State,
	size:           [2]u32,
	pass_constants: gpu.Upload,
	vertices:       render.Buffer,
	indices:        render.Buffer,
	checker:        render.Texture,
	scene:          render.Texture,
	post:           render.Texture,
}

init :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s^ = {
		platform = platform,
	}

	vertices := [3]Vertex {
		{{0, 0.6}, {0.5, 0}, {1, 0.3, 0.3, 1}},
		{{0.52, -0.3}, {1, 1}, {0.3, 1, 0.3, 1}},
		{{-0.52, -0.3}, {0, 1}, {0.3, 0.3, 1, 1}},
	}
	// Buffer sizes are multiples of 4, so the three u16 indices have one u16 of padding.
	indices := [4]u16{0, 1, 2, 0}
	s.vertices = platform.gpu_create_buffer({size = size_of(vertices), label = "triangle vertices"}, gpu_bytes(&vertices))
	s.indices = platform.gpu_create_buffer({size = size_of(indices), usage = {.Index}, label = "triangle indices"}, gpu_bytes(&indices))

	checker: [CHECKER_SIZE * CHECKER_SIZE][4]u8
	for &texel, i in checker {
		x, y := i % CHECKER_SIZE / CHECKER_CELL, i / CHECKER_SIZE / CHECKER_CELL
		texel = (x + y) % 2 == 0 ? 255 : 64
	}
	s.checker = platform.gpu_create_texture(
		{size = CHECKER_SIZE, format = .RGBA8_Unorm_Srgb, usage = {.Sampled}, label = "checker"},
		gpu_bytes(&checker),
	)
	s.nearest = platform.gpu_create_sampler({label = "nearest"})
	s.linear = platform.gpu_create_sampler({filter = .Linear, address = .Clamp, label = "linear clamp"})
	s.pipelines = create_pipelines(platform)
	log.info("mygame: init")
}

update :: proc(state: rawptr, dt: time.Duration) -> (keep_running: bool) {
	s := (^Game_State)(state)
	s.frame_count += 1
	s.elapsed += dt

	if s.elapsed >= s.next_report {
		s.next_report += time.Second
		title := fmt.aprintf("mygame | frame %d | %.1fs", s.frame_count, time.duration_seconds(s.elapsed), allocator = s.platform.frame_allocator)
		s.platform.set_window_title(title)
	}

	// A minimized window has no size, and nothing is rendered.
	size := s.platform.window_size()
	if size.x <= 0 || size.y <= 0 {
		return true
	}
	pass, ok := s.platform.gpu_upload(size_of(Pass_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return true
	}
	(^Pass_Constants)(raw_data(pass.data))^ = {
		time   = f32(time.duration_seconds(s.elapsed)),
		aspect = f32(size.x) / f32(size.y),
	}
	render_frame(s, {u32(size.x), u32(size.y)}, pass)
	return true
}

// render_frame draws the scene into an HDR target with depth, post-processes it in a compute pass,
// and tone maps it into the frame target. The render graph places the barriers between the passes.
render_frame :: proc(s: ^Game_State, size: [2]u32, pass_constants: gpu.Upload) {
	frame := new(Frame, s.platform.frame_allocator)
	frame^ = {
		state          = s,
		size           = size,
		pass_constants = pass_constants,
	}

	g := render.begin(s.platform, &s.textures)
	target := render.import_texture(&g, s.platform.gpu_frame_target(), .Color)
	frame.checker = render.import_texture(&g, s.checker, .Sampled)
	frame.vertices = render.import_buffer(&g, s.vertices)
	frame.indices = render.import_buffer(&g, s.indices)
	frame.scene = render.create_texture(&g, {size = size, format = SCENE_FORMAT, label = "scene"})
	depth := render.create_texture(&g, {size = size, format = DEPTH_FORMAT, label = "scene depth"})
	frame.post = render.create_texture(&g, {size = size, format = SCENE_FORMAT, label = "post"})

	p := render.add_render_pass(&g, "scene", draw_scene, frame)
	render.color(&g, p, frame.scene, .Clear, {0.02, 0.02, 0.035, 1})
	render.depth(&g, p, depth, .Clear, store = .Discard)
	render.read(&g, p, frame.checker)
	render.read(&g, p, frame.vertices)
	render.index_buffer(&g, p, frame.indices)

	p = render.add_compute_pass(&g, "post", run_post, frame)
	render.read(&g, p, frame.scene)
	render.write(&g, p, frame.post)

	p = render.add_render_pass(&g, "composite", draw_composite, frame)
	render.read(&g, p, frame.post)
	render.color(&g, p, target, .Discard)

	render.execute(&g)
}

draw_scene :: proc(g: ^render.Graph, cb: ^gpu.Command_Buffer, data: rawptr) {
	frame := (^Frame)(data)
	constants := Scene_Constants {
		vertices = gpu.read_index(render.gpu_buffer(g, frame.vertices)),
		texture  = gpu.read_index(render.gpu_texture(g, frame.checker)),
		sampler  = gpu.sampler_index(frame.state.nearest),
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.scene)
	gpu.cmd_set_pass_constants(cb, frame.pass_constants)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_set_index_buffer(cb, render.gpu_buffer(g, frame.indices), .U16)
	gpu.cmd_draw_indexed(cb, 3, instance_count = 2)
}

run_post :: proc(g: ^render.Graph, cb: ^gpu.Command_Buffer, data: rawptr) {
	frame := (^Frame)(data)
	constants := Post_Constants {
		input  = gpu.read_index(render.gpu_texture(g, frame.scene)),
		output = gpu.write_index(render.gpu_texture(g, frame.post)),
		size   = frame.size,
	}
	groups := (frame.size + POST_GROUP_SIZE - 1) / POST_GROUP_SIZE
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.post)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {groups.x, groups.y, 1})
}

draw_composite :: proc(g: ^render.Graph, cb: ^gpu.Command_Buffer, data: rawptr) {
	frame := (^Frame)(data)
	constants := Composite_Constants {
		input   = gpu.read_index(render.gpu_texture(g, frame.post)),
		sampler = gpu.sampler_index(frame.state.linear),
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.composite)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_draw(cb, 3)
}

shutdown :: proc(state: rawptr) {
	s := (^Game_State)(state)
	render.cache_destroy(&s.textures, s.platform)
	destroy_pipelines(s.platform, s.pipelines)
	s.platform.gpu_destroy_sampler(s.linear)
	s.platform.gpu_destroy_sampler(s.nearest)
	s.platform.gpu_destroy_texture(s.checker)
	s.platform.gpu_destroy_buffer(s.indices)
	s.platform.gpu_destroy_buffer(s.vertices)
	log.info("mygame: shutdown")
}

// on_reload recreates the pipelines, because the new DLL may embed new shaders.
on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	destroy_pipelines(platform, s.pipelines)
	s.pipelines = create_pipelines(platform)
	log.infof("mygame: reloaded at frame %d", s.frame_count)
}

create_pipelines :: proc(platform: ^core.Platform_API) -> Pipelines {
	return {
		scene = platform.gpu_create_graphics_pipeline(
			{
				vertex = TRIANGLE_VS,
				pixel = TRIANGLE_PS,
				colors = {{format = SCENE_FORMAT}},
				depth_format = DEPTH_FORMAT,
				depth_compare = .Less,
				depth_write = true,
				label = "scene",
			},
		),
		post = platform.gpu_create_compute_pipeline({compute = POST_CS, label = "post"}),
		composite = platform.gpu_create_graphics_pipeline(
			{vertex = COMPOSITE_VS, pixel = COMPOSITE_PS, colors = {{format = gpu.FRAME_TARGET_FORMAT}}, label = "composite"},
		),
	}
}

destroy_pipelines :: proc(platform: ^core.Platform_API, pipelines: Pipelines) {
	platform.gpu_destroy_pipeline(pipelines.scene)
	platform.gpu_destroy_pipeline(pipelines.post)
	platform.gpu_destroy_pipeline(pipelines.composite)
}

gpu_bytes :: proc(data: ^$T) -> []byte {
	return ([^]byte)(data)[:size_of(T)]
}

state_size :: proc() -> int {
	return size_of(Game_State)
}

layout_hash :: proc() -> u64 {
	return layout.hash(Game_State)
}

@(export)
cinnabar_game_api :: proc() -> core.Game_API {
	return {
		init = init,
		update = update,
		shutdown = shutdown,
		on_reload = on_reload,
		state_size = state_size,
		layout_hash = layout_hash,
		gpu_format_hash = gpu.format_hash,
	}
}

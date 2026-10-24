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
OBJECTS_VS :: #load("shaders/objects.vs.dxil")
OBJECTS_PS :: #load("shaders/objects.ps.dxil")
COUNT_RESET_CS :: #load("shaders/count_reset.cs.dxil")
CULL_CS :: #load("shaders/cull.cs.dxil")
POST_CS :: #load("shaders/post.cs.dxil")
COMPOSITE_VS :: #load("shaders/composite.vs.dxil")
COMPOSITE_PS :: #load("shaders/composite.ps.dxil")

SCENE_FORMAT :: gpu.Format.RGBA16_Float
DEPTH_FORMAT :: gpu.Format.D32_Float
// Matches numthreads in shaders/post.hlsl.
POST_GROUP_SIZE :: 8
// Matches numthreads in shaders/cull.hlsl.
CULL_GROUP_SIZE :: 64

// The GPU culls a grid of small objects every frame and draws the visible ones with one indirect draw.
OBJECT_COLUMNS :: 64
OBJECT_ROWS :: 36
OBJECT_COUNT :: OBJECT_COLUMNS * OBJECT_ROWS

// The scene pass is split in two: one piece draws the large triangles, the other the culled objects.
SCENE_PIECES :: 2

CHECKER_SIZE :: 64
CHECKER_CELL :: 8

// Matches Vertex in shaders/triangle.hlsl and shaders/objects.hlsl.
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

// Matches Push in shaders/objects.hlsl.
Object_Constants :: struct {
	vertices: u32,
	visible:  u32,
	texture:  u32,
	sampler:  u32,
	grid:     [2]u32,
}

// Matches Push in shaders/count_reset.hlsl.
Reset_Constants :: struct {
	count: u32,
}

// Matches Push in shaders/cull.hlsl.
Cull_Constants :: struct {
	arguments:    u32,
	count:        u32,
	visible:      u32,
	object_count: u32,
	grid:         [2]u32,
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

// Matches Pass in shaders/triangle.hlsl, shaders/objects.hlsl and shaders/cull.hlsl.
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
	// The cull pass writes these on the compute queue each frame, and the scene pass reads them.
	arguments:   gpu.Buffer,
	draw_count:  gpu.Buffer,
	visible:     gpu.Buffer,
	checker:     gpu.Texture,
	nearest:     gpu.Sampler,
	linear:      gpu.Sampler,
	textures:    render.Texture_Cache,
}

Pipelines :: struct {
	scene:       gpu.Pipeline,
	objects:     gpu.Pipeline,
	count_reset: gpu.Pipeline,
	cull:        gpu.Pipeline,
	post:        gpu.Pipeline,
	composite:   gpu.Pipeline,
}

// Frame is what the pass procedures need. It lives in frame memory.
Frame :: struct {
	state:          ^Game_State,
	size:           [2]u32,
	pass_constants: gpu.Upload,
	vertices:       render.Buffer,
	indices:        render.Buffer,
	arguments:      render.Buffer,
	draw_count:     render.Buffer,
	visible:        render.Buffer,
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
	s.arguments = platform.gpu_create_buffer(
		{size = OBJECT_COUNT * size_of(gpu.Draw_Indexed_Indirect_Args), usage = {.Storage, .Indirect}, label = "object draws"},
		nil,
	)
	s.draw_count = platform.gpu_create_buffer({size = size_of(u32), usage = {.Storage, .Indirect}, label = "object draw count"}, nil)
	s.visible = platform.gpu_create_buffer({size = OBJECT_COUNT * size_of(u32), usage = {.Storage}, label = "visible objects"}, nil)

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

// render_frame culls the objects on the compute queue, draws the scene into an HDR target with depth,
// post-processes it in a compute pass, and tone maps it into the frame target. The render graph places the
// barriers between the passes and the waits between the queues.
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
	frame.arguments = render.import_buffer(&g, s.arguments)
	frame.draw_count = render.import_buffer(&g, s.draw_count)
	frame.visible = render.import_buffer(&g, s.visible)
	frame.scene = render.create_texture(&g, {size = size, format = SCENE_FORMAT, label = "scene"})
	depth := render.create_texture(&g, {size = size, format = DEPTH_FORMAT, label = "scene depth"})
	frame.post = render.create_texture(&g, {size = size, format = SCENE_FORMAT, label = "post"})

	p := render.add_compute_pass(&g, "reset draw count", reset_count, frame, queue = .Compute)
	render.write(&g, p, frame.draw_count)

	p = render.add_compute_pass(&g, "cull", cull_objects, frame, queue = .Compute)
	render.write(&g, p, frame.draw_count)
	render.write(&g, p, frame.arguments)
	render.write(&g, p, frame.visible)

	p = render.add_render_pass(&g, "scene", draw_scene, frame, pieces = SCENE_PIECES)
	render.color(&g, p, frame.scene, .Clear, {0.02, 0.02, 0.035, 1})
	render.depth(&g, p, depth, .Clear, store = .Discard)
	render.read(&g, p, frame.checker)
	render.read(&g, p, frame.vertices)
	render.index_buffer(&g, p, frame.indices)
	render.indirect_buffer(&g, p, frame.arguments)
	render.indirect_buffer(&g, p, frame.draw_count)
	render.read(&g, p, frame.visible)

	p = render.add_compute_pass(&g, "post", run_post, frame)
	render.read(&g, p, frame.scene)
	render.write(&g, p, frame.post)

	p = render.add_render_pass(&g, "composite", draw_composite, frame)
	render.read(&g, p, frame.post)
	render.color(&g, p, target, .Discard)

	render.execute(&g)
}

reset_count :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	constants := Reset_Constants {
		count = gpu.write_index(render.gpu_buffer(ctx.graph, frame.draw_count)),
	}
	gpu.cmd_set_pipeline(ctx.cb, frame.state.pipelines.count_reset)
	gpu.cmd_push_constants(ctx.cb, &constants)
	gpu.cmd_dispatch(ctx.cb, {1, 1, 1})
}

cull_objects :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	constants := Cull_Constants {
		arguments    = gpu.write_index(render.gpu_buffer(g, frame.arguments)),
		count        = gpu.write_index(render.gpu_buffer(g, frame.draw_count)),
		visible      = gpu.write_index(render.gpu_buffer(g, frame.visible)),
		object_count = OBJECT_COUNT,
		grid         = {OBJECT_COLUMNS, OBJECT_ROWS},
	}
	gpu.cmd_set_pipeline(cb, frame.state.pipelines.cull)
	gpu.cmd_set_pass_constants(cb, frame.pass_constants)
	gpu.cmd_push_constants(cb, &constants)
	gpu.cmd_dispatch(cb, {(OBJECT_COUNT + CULL_GROUP_SIZE - 1) / CULL_GROUP_SIZE, 1, 1})
}

// draw_scene draws the large triangles in piece 0, and the objects that survived culling in piece 1.
// Each piece starts with nothing bound.
draw_scene :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
	vertices := gpu.read_index(render.gpu_buffer(g, frame.vertices))
	checker := gpu.read_index(render.gpu_texture(g, frame.checker))
	switch ctx.piece {
	case 0:
		constants := Scene_Constants{vertices, checker, gpu.sampler_index(frame.state.nearest)}
		gpu.cmd_set_pipeline(cb, frame.state.pipelines.scene)
		gpu.cmd_set_pass_constants(cb, frame.pass_constants)
		gpu.cmd_push_constants(cb, &constants)
		gpu.cmd_set_index_buffer(cb, render.gpu_buffer(g, frame.indices), .U16)
		gpu.cmd_draw_indexed(cb, 3, instance_count = 2)
	case 1:
		constants := Object_Constants {
			vertices = vertices,
			visible  = gpu.read_index(render.gpu_buffer(g, frame.visible)),
			texture  = checker,
			sampler  = gpu.sampler_index(frame.state.nearest),
			grid     = {OBJECT_COLUMNS, OBJECT_ROWS},
		}
		gpu.cmd_set_pipeline(cb, frame.state.pipelines.objects)
		gpu.cmd_set_pass_constants(cb, frame.pass_constants)
		gpu.cmd_push_constants(cb, &constants)
		gpu.cmd_set_index_buffer(cb, render.gpu_buffer(g, frame.indices), .U16)
		gpu.cmd_draw_indexed_indirect(cb, render.gpu_buffer(g, frame.arguments), 0, OBJECT_COUNT, render.gpu_buffer(g, frame.draw_count))
	}
}

run_post :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
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

draw_composite :: proc(ctx: ^render.Pass_Context) {
	frame := (^Frame)(ctx.data)
	g, cb := ctx.graph, ctx.cb
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
	s.platform.gpu_destroy_buffer(s.visible)
	s.platform.gpu_destroy_buffer(s.draw_count)
	s.platform.gpu_destroy_buffer(s.arguments)
	s.platform.gpu_destroy_buffer(s.indices)
	s.platform.gpu_destroy_buffer(s.vertices)
	log.info("mygame: shutdown")
}

// on_reload updates the pipelines, because the new DLL may embed new shaders. The old versions keep drawing until
// the new ones compile. An update that changes a pipeline's formats is refused, so that pipeline is created again.
on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	reload_graphics_pipeline(platform, &s.pipelines.scene, SCENE_PIPELINE)
	reload_graphics_pipeline(platform, &s.pipelines.objects, OBJECTS_PIPELINE)
	reload_graphics_pipeline(platform, &s.pipelines.composite, COMPOSITE_PIPELINE)
	reload_compute_pipeline(platform, &s.pipelines.count_reset, COUNT_RESET_PIPELINE)
	reload_compute_pipeline(platform, &s.pipelines.cull, CULL_PIPELINE)
	reload_compute_pipeline(platform, &s.pipelines.post, POST_PIPELINE)
	log.infof("mygame: reloaded at frame %d", s.frame_count)
}

reload_graphics_pipeline :: proc(platform: ^core.Platform_API, pipeline: ^gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) {
	if !platform.gpu_update_graphics_pipeline(pipeline^, desc) {
		platform.gpu_destroy_pipeline(pipeline^)
		pipeline^ = platform.gpu_create_graphics_pipeline(desc)
	}
}

reload_compute_pipeline :: proc(platform: ^core.Platform_API, pipeline: ^gpu.Pipeline, desc: gpu.Compute_Pipeline_Desc) {
	if !platform.gpu_update_compute_pipeline(pipeline^, desc) {
		platform.gpu_destroy_pipeline(pipeline^)
		pipeline^ = platform.gpu_create_compute_pipeline(desc)
	}
}

create_pipelines :: proc(platform: ^core.Platform_API) -> Pipelines {
	return {
		scene = platform.gpu_create_graphics_pipeline(SCENE_PIPELINE),
		objects = platform.gpu_create_graphics_pipeline(OBJECTS_PIPELINE),
		count_reset = platform.gpu_create_compute_pipeline(COUNT_RESET_PIPELINE),
		cull = platform.gpu_create_compute_pipeline(CULL_PIPELINE),
		post = platform.gpu_create_compute_pipeline(POST_PIPELINE),
		composite = platform.gpu_create_graphics_pipeline(COMPOSITE_PIPELINE),
	}
}

SCENE_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	vertex        = TRIANGLE_VS,
	pixel         = TRIANGLE_PS,
	colors        = {{format = SCENE_FORMAT}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Less,
	depth_write   = true,
	label         = "scene",
}

OBJECTS_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	vertex        = OBJECTS_VS,
	pixel         = OBJECTS_PS,
	colors        = {{format = SCENE_FORMAT}},
	depth_format  = DEPTH_FORMAT,
	depth_compare = .Less,
	depth_write   = true,
	label         = "objects",
}

COUNT_RESET_PIPELINE :: gpu.Compute_Pipeline_Desc {
	compute = COUNT_RESET_CS,
	label   = "count reset",
}

CULL_PIPELINE :: gpu.Compute_Pipeline_Desc {
	compute = CULL_CS,
	label   = "cull",
}

POST_PIPELINE :: gpu.Compute_Pipeline_Desc {
	compute = POST_CS,
	label   = "post",
}

COMPOSITE_PIPELINE :: gpu.Graphics_Pipeline_Desc {
	vertex = COMPOSITE_VS,
	pixel  = COMPOSITE_PS,
	colors = {{format = gpu.FRAME_TARGET_FORMAT}},
	label  = "composite",
}

destroy_pipelines :: proc(platform: ^core.Platform_API, pipelines: Pipelines) {
	platform.gpu_destroy_pipeline(pipelines.scene)
	platform.gpu_destroy_pipeline(pipelines.objects)
	platform.gpu_destroy_pipeline(pipelines.count_reset)
	platform.gpu_destroy_pipeline(pipelines.cull)
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

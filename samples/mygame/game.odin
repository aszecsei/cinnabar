package mygame

import "core:fmt"
import "core:log"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:core/layout"

TRIANGLE_VS :: #load("shaders/triangle.vs.dxil")
TRIANGLE_PS :: #load("shaders/triangle.ps.dxil")

CHECKER_SIZE :: 64
CHECKER_CELL :: 8

// Matches Vertex in shaders/triangle.hlsl.
Vertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

// Matches Push in shaders/triangle.hlsl.
Triangle_Constants :: struct {
	vertices: u32,
	texture:  u32,
	sampler:  u32,
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
	pipeline:    gpu.Pipeline,
	vertices:    gpu.Buffer,
	indices:     gpu.Buffer,
	checker:     gpu.Texture,
	sampler:     gpu.Sampler,
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
	s.sampler = platform.gpu_create_sampler({label = "nearest"})
	s.pipeline = create_pipeline(platform)
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

	size := s.platform.window_size()
	pass, ok := s.platform.gpu_upload(size_of(Pass_Constants), gpu.PASS_CONSTANTS_ALIGN)
	if !ok {
		return true
	}
	(^Pass_Constants)(raw_data(pass.data))^ = {
		time   = f32(time.duration_seconds(s.elapsed)),
		aspect = f32(size.x) / f32(max(size.y, 1)),
	}
	constants := Triangle_Constants {
		vertices = gpu.read_index(s.vertices),
		texture  = gpu.read_index(s.checker),
		sampler  = gpu.sampler_index(s.sampler),
	}

	cb := gpu.command_buffer(s.platform.frame_allocator)
	gpu.cmd_begin_marker(&cb, "triangle")
	gpu.cmd_begin_pass(&cb, {{texture = s.platform.gpu_frame_target(), load = .Clear, clear = {0.05, 0.05, 0.08, 1}}})
	gpu.cmd_set_pipeline(&cb, s.pipeline)
	gpu.cmd_set_pass_constants(&cb, pass)
	gpu.cmd_push_constants(&cb, &constants)
	gpu.cmd_set_index_buffer(&cb, s.indices, .U16)
	gpu.cmd_draw_indexed(&cb, 3)
	gpu.cmd_end_pass(&cb)
	gpu.cmd_end_marker(&cb)
	s.platform.gpu_submit({cb})
	return true
}

shutdown :: proc(state: rawptr) {
	s := (^Game_State)(state)
	s.platform.gpu_destroy_pipeline(s.pipeline)
	s.platform.gpu_destroy_sampler(s.sampler)
	s.platform.gpu_destroy_texture(s.checker)
	s.platform.gpu_destroy_buffer(s.indices)
	s.platform.gpu_destroy_buffer(s.vertices)
	log.info("mygame: shutdown")
}

// on_reload recreates the pipeline, because the new DLL may embed new shaders.
on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	platform.gpu_destroy_pipeline(s.pipeline)
	s.pipeline = create_pipeline(platform)
	log.infof("mygame: reloaded at frame %d", s.frame_count)
}

create_pipeline :: proc(platform: ^core.Platform_API) -> gpu.Pipeline {
	return platform.gpu_create_graphics_pipeline(
		{vertex = TRIANGLE_VS, pixel = TRIANGLE_PS, colors = {{format = gpu.FRAME_TARGET_FORMAT}}, label = "triangle"},
	)
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

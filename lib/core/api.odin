package core

import "base:runtime"
import "core:time"

import "cinnabar:core/gpu"

// Platform_API is everything core provides to the game side (host -> game).
// It is the complete porting surface.
Platform_API :: struct {
	// Allocators are built by the host, so their procedures stay valid across reloads.
	permanent_allocator: runtime.Allocator,
	frame_allocator:     runtime.Allocator,

	time_seconds:     proc() -> f64,
	// The client area size at the start of the frame. The frame target has this size. It is zero while minimized.
	window_size:      proc() -> [2]i32,
	set_window_title: proc(title: string),

	gpu_features:     proc() -> gpu.Features,
	// The frame target is in the render target layout when the frame starts, and the game must leave it there.
	// Its contents are undefined at the start of each frame.
	gpu_frame_target: proc() -> gpu.Texture,
	// gpu_submit returns false if the backend rejected the command buffers.
	gpu_submit:       proc(buffers: []gpu.Command_Buffer) -> bool,
	// gpu_upload allocates memory in the frame's upload ring. It returns false when the ring is full.
	gpu_upload:       proc(size, align: int) -> (gpu.Upload, bool),

	// Creation returns the nil handle on failure. data may be nil. The backend copies the description and the data.
	gpu_create_buffer:            proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer,
	gpu_create_texture:           proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture,
	gpu_create_sampler:           proc(desc: gpu.Sampler_Desc) -> gpu.Sampler,
	gpu_create_graphics_pipeline: proc(desc: gpu.Graphics_Pipeline_Desc) -> gpu.Pipeline,
	gpu_create_compute_pipeline:  proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline,
	// Destruction invalidates the handle at once and releases the resource when the GPU no longer uses it.
	gpu_destroy_buffer:           proc(buffer: gpu.Buffer),
	gpu_destroy_texture:          proc(texture: gpu.Texture),
	gpu_destroy_sampler:          proc(sampler: gpu.Sampler),
	gpu_destroy_pipeline:         proc(pipeline: gpu.Pipeline),
}

// Game_API is what the game side provides to the host (game -> host).
// `state` always points at the game's root Game_State, which the host owns.
Game_API :: struct {
	init:        proc(state: rawptr, platform: ^Platform_API),
	// dt is fixed-point (integer nanoseconds), so accumulated world time does not drift.
	update:      proc(state: rawptr, dt: time.Duration) -> (keep_running: bool),
	shutdown:    proc(state: rawptr),
	on_reload:   proc(state: rawptr, platform: ^Platform_API),
	state_size:  proc() -> int,
	layout_hash: proc() -> u64,
	// The host refuses a DLL whose GPU command format differs from its own (see docs/gpu.md#command-buffers).
	gpu_format_hash: proc() -> u64,
}

// The game DLL exports a `proc() -> Game_API` under this name.
GAME_API_SYMBOL :: "cinnabar_game_api"

GAME_STATE_ALIGN :: 64

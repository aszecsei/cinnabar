package core

import "base:runtime"
import "core:time"

import "cinnabar:core/gpu"
import "cinnabar:core/jobs"

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

	// Frame jobs run on fibers and must finish before the frame ends. Wait from a job or from the game's frame code.
	// Call these, not the jobs package: the DLL's copy of the scheduler is not running.
	jobs_run:          proc(job_list: []jobs.Job, counter: ^jobs.Counter),
	jobs_wait:         proc(counter: ^jobs.Counter),
	// A fiber-aware lock: a fiber that waits for it suspends and frees its thread, so the holder may wait on
	// counters while it holds the lock. Use it only from jobs and the frame code.
	jobs_lock:         proc(mutex: ^jobs.Mutex),
	jobs_unlock:       proc(mutex: ^jobs.Mutex),
	// The number of threads that run jobs, including the main thread.
	jobs_worker_count: proc() -> int,

	gpu_features:     proc() -> gpu.Features,
	// The frame target is in the render target layout when the frame starts, and the game must leave it there.
	// Its contents are undefined at the start of each frame.
	gpu_frame_target: proc() -> gpu.Texture,
	// gpu_submit runs the command buffers on a queue, in order after the queue's earlier submissions in the frame.
	// They start after the earlier submissions of the wait_for queues finish. It returns false if the backend
	// rejected the command buffers. See docs/gpu.md#queues.
	gpu_submit:       proc(buffers: []gpu.Command_Buffer, queue := gpu.Queue.Graphics, wait_for := gpu.Queues{}) -> bool,
	// gpu_upload allocates memory in the frame's upload ring. It returns false when the ring is full.
	gpu_upload:       proc(size, align: int) -> (gpu.Upload, bool),

	// Creation returns the nil handle on failure. data may be nil. The backend copies the description and the data.
	gpu_create_buffer:            proc(desc: gpu.Buffer_Desc, data: []byte) -> gpu.Buffer,
	gpu_create_texture:           proc(desc: gpu.Texture_Desc, data: []byte) -> gpu.Texture,
	gpu_create_sampler:           proc(desc: gpu.Sampler_Desc) -> gpu.Sampler,
	gpu_create_graphics_pipeline: proc(desc: gpu.Graphics_Pipeline_Desc) -> gpu.Pipeline,
	gpu_create_compute_pipeline:  proc(desc: gpu.Compute_Pipeline_Desc) -> gpu.Pipeline,
	// An update compiles a new version and keeps the current one in use until the new one is ready. It keeps the
	// handle and the scope. It returns false, and changes nothing, if the new version changes the attachment
	// formats or the topology: create a new pipeline for those.
	gpu_update_graphics_pipeline: proc(pipeline: gpu.Pipeline, desc: gpu.Graphics_Pipeline_Desc) -> bool,
	gpu_update_compute_pipeline:  proc(pipeline: gpu.Pipeline, desc: gpu.Compute_Pipeline_Desc) -> bool,
	// Destruction invalidates the handle at once and releases the resource when the GPU no longer uses it.
	gpu_destroy_buffer:           proc(buffer: gpu.Buffer),
	gpu_destroy_texture:          proc(texture: gpu.Texture),
	gpu_destroy_sampler:          proc(sampler: gpu.Sampler),
	gpu_destroy_pipeline:         proc(pipeline: gpu.Pipeline),
	// Destroys every resource in the scope and returns how many there were. See gpu.Scope.
	gpu_destroy_scope:            proc(scope: gpu.Scope) -> int,
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

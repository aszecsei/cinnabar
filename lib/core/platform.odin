package core

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:time"

import "cinnabar:core/gpu"
import "cinnabar:core/jobs"

// A comma-separated list of gpu.Feature names that core hides from the game, to test fallback paths on hardware
// that has the features. For example: CINNABAR_DISABLE_FEATURES=Mesh_Shaders.
DISABLE_FEATURES_VARIABLE :: "CINNABAR_DISABLE_FEATURES"

// The build selects the GPU backend by pointing this collection at a backend package.
import backend "gpu_backend:."

PERMANENT_RESERVE :: 4 * mem.Gigabyte
FRAME_RESERVE :: 256 * mem.Megabyte

@(private)
Platform :: struct {
	permanent:   virtual.Arena,
	frame:       [2]virtual.Arena,
	frame_index: u64,
	start:       time.Tick,
	last_frame:  time.Tick,
	// Read once per frame, so the game and the GPU backend agree on it.
	window_size: [2]i32,
	disabled_features: gpu.Features,
	api:         Platform_API,
}

@(private)
platform: Platform

init :: proc(title: string, width: i32 = 1280, height: i32 = 720) -> bool {
	if err := virtual.arena_init_static(&platform.permanent, PERMANENT_RESERVE); err != nil {
		log.errorf("core: permanent arena: %v", err)
		return false
	}
	for &arena in platform.frame {
		if err := virtual.arena_init_static(&arena, FRAME_RESERVE); err != nil {
			log.errorf("core: frame arena: %v", err)
			return false
		}
	}
	if !jobs.init() {
		log.error("core: failed to start the job system")
		return false
	}
	if !_window_open(title, width, height) {
		log.error("core: failed to open window")
		return false
	}
	platform.window_size = _window_size()
	if !backend.init(_window_native_handle(), platform.window_size) {
		log.error("core: failed to initialize the GPU backend")
		return false
	}

	platform.disabled_features = read_disabled_features()

	platform.start = time.tick_now()
	platform.last_frame = platform.start
	platform.api = {
		permanent_allocator          = virtual.arena_allocator(&platform.permanent),
		frame_allocator              = virtual.arena_allocator(&platform.frame[0]),
		time_seconds                 = time_seconds,
		window_size                  = window_size,
		set_window_title             = _window_set_title,
		jobs_run                     = jobs.run,
		jobs_wait                    = jobs.wait,
		jobs_lock                    = jobs.lock,
		jobs_unlock                  = jobs.unlock,
		jobs_worker_count            = jobs.worker_count,
		gpu_features                 = gpu_features,
		gpu_frame_target             = backend.frame_target,
		gpu_submit                   = backend.submit,
		gpu_upload                   = backend.upload,
		gpu_create_buffer            = backend.create_buffer,
		gpu_create_texture           = backend.create_texture,
		gpu_create_sampler           = backend.create_sampler,
		gpu_create_graphics_pipeline = backend.create_graphics_pipeline,
		gpu_create_compute_pipeline  = backend.create_compute_pipeline,
		gpu_update_graphics_pipeline = backend.update_graphics_pipeline,
		gpu_update_compute_pipeline  = backend.update_compute_pipeline,
		gpu_create_ray_tracing_pipeline = backend.create_ray_tracing_pipeline,
		gpu_update_ray_tracing_pipeline = backend.update_ray_tracing_pipeline,
		gpu_create_accel             = backend.create_accel,
		gpu_accel_reference          = backend.accel_reference,
		gpu_destroy_buffer           = backend.destroy_buffer,
		gpu_destroy_texture          = backend.destroy_texture,
		gpu_destroy_sampler          = backend.destroy_sampler,
		gpu_destroy_pipeline         = backend.destroy_pipeline,
		gpu_destroy_accel            = backend.destroy_accel,
		gpu_destroy_scope            = backend.destroy_scope,
	}
	return true
}

shutdown :: proc() {
	backend.shutdown()
	_window_close()
	jobs.shutdown()
	for &arena in platform.frame {
		virtual.arena_destroy(&arena)
	}
	virtual.arena_destroy(&platform.permanent)
}

platform_api :: proc() -> ^Platform_API {
	return &platform.api
}

// begin_frame polls platform events, waits for the GPU backend to accept a new frame
// and swaps the frame arena. It returns false when the window was closed.
begin_frame :: proc() -> (dt: time.Duration, keep_running: bool) {
	keep_running = _window_poll()
	platform.window_size = _window_size()
	backend.begin_frame(platform.window_size)

	now := time.tick_now()
	dt = time.tick_diff(platform.last_frame, now)
	platform.last_frame = now

	platform.frame_index += 1
	frame := &platform.frame[platform.frame_index % len(platform.frame)]
	virtual.arena_free_all(frame)
	platform.api.frame_allocator = virtual.arena_allocator(frame)
	return
}

// end_frame presents the frame. The GPU backend paces frames to vsync.
end_frame :: proc() {
	if !jobs.drain_frame() {
		log.error("core: jobs ran past the end of the frame. Wait for every counter before the frame ends.")
	}
	backend.end_frame()
}

// alloc_game_state allocates zeroed root game state from the permanent arena.
alloc_game_state :: proc(size: int) -> rawptr {
	ptr, err := mem.alloc(size, GAME_STATE_ALIGN, platform.api.permanent_allocator)
	if err != nil {
		log.panicf("core: failed to allocate %d bytes of game state: %v", size, err)
	}
	return ptr
}

// soft_restart runs between the old game's shutdown and the new game's init. It destroys the GPU resources in the
// Game scope, which the old game may have left, and frees all permanent allocations.
soft_restart :: proc() {
	if count := backend.destroy_scope(.Game); count > 0 {
		log.debugf("core: destroyed %d GPU resources that the game left in the Game scope", count)
	}
	virtual.arena_free_all(&platform.permanent)
}

// gpu_features is the backend's optional features without those that CINNABAR_DISABLE_FEATURES hides.
gpu_features :: proc() -> gpu.Features {
	return backend.features() - platform.disabled_features
}

@(private = "file")
read_disabled_features :: proc() -> (disabled: gpu.Features) {
	value := os.get_env(DISABLE_FEATURES_VARIABLE, context.temp_allocator)
	for name in strings.split_iterator(&value, ",") {
		trimmed := strings.trim_space(name)
		if feature, ok := reflect.enum_from_name(gpu.Feature, trimmed); ok {
			disabled += {feature}
		} else if trimmed != "" {
			log.warnf("core: %s: unknown feature %q", DISABLE_FEATURES_VARIABLE, trimmed)
		}
	}
	if disabled != {} {
		log.infof("core: hiding GPU features %v", disabled)
	}
	return
}

// window_size is the client area size at the start of the frame. It is zero while the window is minimized.
window_size :: proc() -> [2]i32 {
	return platform.window_size
}

time_seconds :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(platform.start))
}

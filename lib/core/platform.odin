package core

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:time"

PERMANENT_RESERVE :: 4 * mem.Gigabyte
FRAME_RESERVE :: 256 * mem.Megabyte

// Until the GPU backend presents with vsync, frames are paced by sleeping.
TARGET_FRAME_TIME :: time.Second / 60

@(private)
Platform :: struct {
	permanent:   virtual.Arena,
	frame:       [2]virtual.Arena,
	frame_index: u64,
	start:       time.Tick,
	last_frame:  time.Tick,
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
	if !_window_open(title, width, height) {
		log.error("core: failed to open window")
		return false
	}

	platform.start = time.tick_now()
	platform.last_frame = platform.start
	platform.api = {
		permanent_allocator = virtual.arena_allocator(&platform.permanent),
		frame_allocator     = virtual.arena_allocator(&platform.frame[0]),
		time_seconds        = time_seconds,
		window_size         = _window_size,
		set_window_title    = _window_set_title,
	}
	return true
}

shutdown :: proc() {
	_window_close()
	for &arena in platform.frame {
		virtual.arena_destroy(&arena)
	}
	virtual.arena_destroy(&platform.permanent)
}

platform_api :: proc() -> ^Platform_API {
	return &platform.api
}

// begin_frame polls platform events and swaps the frame arena.
// It returns false when the window was closed.
begin_frame :: proc() -> (dt: time.Duration, keep_running: bool) {
	if elapsed := time.tick_since(platform.last_frame); elapsed < TARGET_FRAME_TIME {
		time.sleep(TARGET_FRAME_TIME - elapsed)
	}
	now := time.tick_now()
	dt = time.tick_diff(platform.last_frame, now)
	platform.last_frame = now

	platform.frame_index += 1
	frame := &platform.frame[platform.frame_index % len(platform.frame)]
	virtual.arena_free_all(frame)
	platform.api.frame_allocator = virtual.arena_allocator(frame)

	return dt, _window_poll()
}

// alloc_game_state allocates zeroed root game state from the permanent arena.
alloc_game_state :: proc(size: int) -> rawptr {
	ptr, err := mem.alloc(size, GAME_STATE_ALIGN, platform.api.permanent_allocator)
	if err != nil {
		log.panicf("core: failed to allocate %d bytes of game state: %v", size, err)
	}
	return ptr
}

// reset_permanent frees all permanent allocations, for a soft restart with fresh state.
reset_permanent :: proc() {
	virtual.arena_free_all(&platform.permanent)
}

time_seconds :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(platform.start))
}

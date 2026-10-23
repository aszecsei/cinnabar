package core

import "base:runtime"

// Platform_API is everything core provides to the game side (host -> game).
// It is the complete porting surface.
Platform_API :: struct {
	// Allocators are built by the host, so their procedures stay valid across reloads.
	permanent_allocator: runtime.Allocator,
	frame_allocator:     runtime.Allocator,

	time_seconds:     proc() -> f64,
	window_size:      proc() -> [2]i32,
	set_window_title: proc(title: string),
}

// Game_API is what the game side provides to the host (game -> host).
// `state` always points at the game's root Game_State, which the host owns.
Game_API :: struct {
	init:        proc(state: rawptr, platform: ^Platform_API),
	update:      proc(state: rawptr, dt: f32) -> (keep_running: bool),
	shutdown:    proc(state: rawptr),
	on_reload:   proc(state: rawptr, platform: ^Platform_API),
	state_size:  proc() -> int,
	layout_hash: proc() -> u64,
}

// The game DLL exports a `proc() -> Game_API` under this name.
GAME_API_SYMBOL :: "cinnabar_game_api"

GAME_STATE_ALIGN :: 64

package mygame

import "core:fmt"
import "core:log"

import "cinnabar:core"
import "cinnabar:engine"

// Game_State is the root of all persistent game-side state. The host owns its memory.
Game_State :: struct {
	platform:    ^core.Platform_API,
	frame_count: u64,
	elapsed:     f64,
	next_report: f64,
}

init :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s^ = {
		platform = platform,
	}
	log.info("mygame: init")
}

update :: proc(state: rawptr, dt: f32) -> (keep_running: bool) {
	s := (^Game_State)(state)
	s.frame_count += 1
	s.elapsed += f64(dt)

	if s.elapsed >= s.next_report {
		s.next_report += 1
		title := fmt.aprintf("mygame | frame %d | %.1fs", s.frame_count, s.elapsed, allocator = s.platform.frame_allocator)
		s.platform.set_window_title(title)
	}
	return true
}

shutdown :: proc(state: rawptr) {
	log.info("mygame: shutdown")
}

on_reload :: proc(state: rawptr, platform: ^core.Platform_API) {
	s := (^Game_State)(state)
	s.platform = platform
	log.infof("mygame: reloaded at frame %d", s.frame_count)
}

state_size :: proc() -> int {
	return size_of(Game_State)
}

layout_hash :: proc() -> u64 {
	return engine.layout_hash(Game_State)
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
	}
}

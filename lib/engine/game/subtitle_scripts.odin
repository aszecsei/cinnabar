package game

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/cutscene"
import "cinnabar:engine/project"
import "cinnabar:engine/script"

// The subtitles' script API (see docs/scripting/api.md#subtitles), for the options menu: Subtitles.get, Subtitles.set
// and Subtitles.save. The settings are the cutscenes' (cutscene.set_subtitles), and Subtitles.save writes them to the
// user settings file.

// define_subtitle_bindings defines the Subtitles bindings.
@(private)
define_subtitle_bindings :: proc(r: ^script.Runtime) {
	script.define(r, "Subtitles.get", subtitles_get_binding, "() -> SubtitleSettings")
	script.define(r, "Subtitles.set", subtitles_set_binding, "(change: SubtitleChange) -> ()")
	script.define(r, "Subtitles.save", subtitles_save_binding, "() -> boolean")
}

// Subtitles.get() is the player's subtitle settings: whether subtitles show, the scale of their size, and the opacity
// of their backs.
@(private = "file")
subtitles_get_binding :: proc(L: ^luau.State) -> c.int {
	settings := cutscene.subtitles(&game_of(L).cutscenes)
	luau.createtable(L, 0, 3)
	luau.pushboolean(L, b32(settings.enabled))
	luau.setfield(L, -2, "enabled")
	luau.pushnumber(L, f64(settings.size))
	luau.setfield(L, -2, "size")
	luau.pushnumber(L, f64(settings.background))
	luau.setfield(L, -2, "background")
	return 1
}

// Subtitles.set(change) makes the fields that change gives the player's subtitle settings, from the next frame. A
// field that does not exist, or a value of the wrong type or outside its range, raises an error, which changes nothing.
@(private = "file")
subtitles_set_binding :: proc(L: ^luau.State) -> c.int {
	luau.L_checktype(L, 1, .TABLE)
	allocator := script.runtime_of(L).platform.frame_allocator
	g := game_of(L)
	settings := cutscene.subtitles(&g.cutscenes)
	problem := ""
	luau.pushnil(L)
	for problem == "" && luau.next(L, 1) {
		defer luau.pop(L, 1)
		name := luau.type(L, -2) == .STRING ? luau.toodinstring(L, -2) : ""
		switch name {
		case "enabled":
			if luau.type(L, -1) != .BOOLEAN {
				problem = "enabled takes a boolean"
				continue
			}
			settings.enabled = bool(luau.toboolean(L, -1))
		case "size":
			size := luau.tonumber(L, -1)
			if luau.type(L, -1) != .NUMBER ||
			   !(size >= project.MIN_SUBTITLES_SIZE && size <= project.MAX_SUBTITLES_SIZE) {
				problem = fmt.aprintf(
					"size takes a number from %v to %v",
					project.MIN_SUBTITLES_SIZE,
					project.MAX_SUBTITLES_SIZE,
					allocator = allocator,
				)
				continue
			}
			settings.size = f32(size)
		case "background":
			opacity := luau.tonumber(L, -1)
			if luau.type(L, -1) != .NUMBER || !(opacity >= 0 && opacity <= 1) {
				problem = "background takes a number from 0 to 1"
				continue
			}
			settings.background = f32(opacity)
		case:
			problem = fmt.aprintf("there is no subtitle setting %q", name, allocator = allocator)
		}
	}
	if problem != "" {
		script.raise(L, fmt.aprintf("Subtitles.set: %s", problem, allocator = allocator))
	}
	cutscene.set_subtitles(&g.cutscenes, settings)
	return 0
}

// Subtitles.save() writes the player's subtitle settings to the user settings file, as the player's choice on this
// machine. It returns false if it could not write the file.
@(private = "file")
subtitles_save_binding :: proc(L: ^luau.State) -> c.int {
	g := game_of(L)
	settings := cutscene.subtitles(&g.cutscenes)
	ok := project.save_subtitles(
		g.platform,
		g.platform.project_path,
		{settings.enabled, settings.size, settings.background},
	)
	luau.pushboolean(L, b32(ok))
	return 1
}

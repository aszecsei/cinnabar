package project

import "core:c"
import "core:fmt"
import "core:math"
import "core:reflect"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:engine/render"
import "cinnabar:engine/script"

// The display's script API (see docs/scripting/api.md#display), for the options menu: Display.modes,
// Display.resolutions, Display.get, Display.set and Display.save. It reaches the window through the Platform_API and
// the paper white through the renderer, which the Script_Quality of the Render bindings holds.

// define_display_bindings defines the Display bindings. A game's Register_Proc calls it after define_quality_bindings,
// which sets the registry field that holds the Script_Quality.
define_display_bindings :: proc(r: ^script.Runtime) {
	script.define(r, "Display.modes", display_modes_binding, "() -> { string }")
	script.define(r, "Display.resolutions", display_resolutions_binding, "() -> { DisplaySize }")
	script.define(r, "Display.get", display_get_binding, "() -> DisplayState")
	script.define(r, "Display.set", display_set_binding, "(change: DisplayChange) -> ()")
	script.define(r, "Display.save", display_save_binding, "() -> boolean")
}

// Display.modes() is the window modes' names.
@(private = "file")
display_modes_binding :: proc(L: ^luau.State) -> c.int {
	luau.createtable(L, len(core.Window_Mode), 0)
	for mode in core.Window_Mode {
		name, _ := reflect.enum_name_from_value(mode)
		luau.pushodinstring(L, name)
		luau.rawseti(L, -2, c.int(mode) + 1)
	}
	return 1
}

// Display.resolutions() is the sizes of the display modes of the window's monitor, largest first.
@(private = "file")
display_resolutions_binding :: proc(L: ^luau.State) -> c.int {
	platform := script.runtime_of(L).platform
	sizes := platform.display_resolutions(platform.frame_allocator)
	luau.createtable(L, c.int(len(sizes)), 0)
	for size, i in sizes {
		luau.createtable(L, 0, 2)
		luau.pushnumber(L, f64(size.x))
		luau.setfield(L, -2, "width")
		luau.pushnumber(L, f64(size.y))
		luau.setfield(L, -2, "height")
		luau.rawseti(L, -2, c.int(i) + 1)
	}
	return 1
}

// Display.get() is how the display is: the window's mode and client size, whether HDR output is on, whether the display
// is in HDR now, and the paper white of HDR output that is in effect.
@(private = "file")
display_get_binding :: proc(L: ^luau.State) -> c.int {
	platform := script.runtime_of(L).platform
	renderer := script_quality_of(L).renderer
	state := platform.display_state()
	luau.createtable(L, 0, 6)
	mode, _ := reflect.enum_name_from_value(state.mode)
	luau.pushodinstring(L, mode)
	luau.setfield(L, -2, "mode")
	luau.pushnumber(L, f64(state.size.x))
	luau.setfield(L, -2, "width")
	luau.pushnumber(L, f64(state.size.y))
	luau.setfield(L, -2, "height")
	luau.pushboolean(L, b32(state.output != .Sdr))
	luau.setfield(L, -2, "hdr")
	luau.pushboolean(L, b32(state.hdr_available))
	luau.setfield(L, -2, "hdr_available")
	nits := render.paper_white_nits(renderer.paper_white, 0, platform.gpu_output().display)
	luau.pushnumber(L, f64(nits))
	luau.setfield(L, -2, "paper_white")
	return 1
}

// display_change_of reads a script's DisplayChange table at the stack's index 1 into a change, or says what is wrong
// with it.
@(private = "file")
display_change_of :: proc(
	L: ^luau.State,
	state: core.Display_State,
	allocator := context.temp_allocator,
) -> (
	change: Display_Change,
	problem: string,
) {
	luau.pushnil(L)
	for luau.next(L, 1) {
		defer luau.pop(L, 1)
		name := luau.type(L, -2) == .STRING ? luau.toodinstring(L, -2) : ""
		switch name {
		case "mode":
			if luau.type(L, -1) != .STRING {
				return {}, "mode takes a string"
			}
			text := luau.toodinstring(L, -1)
			mode, ok := reflect.enum_from_name(core.Window_Mode, text)
			if !ok {
				return {}, fmt.aprintf("mode takes %s, not %q", window_mode_names(), text, allocator = allocator)
			}
			change.mode = mode
		case "width", "height":
			if luau.type(L, -1) != .NUMBER {
				return {}, fmt.aprintf("%s takes a number", name, allocator = allocator)
			}
			pixels := luau.tonumber(L, -1)
			if pixels != math.floor(pixels) || pixels < 1 || pixels > MAX_DISPLAY_SIZE {
				return {}, fmt.aprintf("%s takes a whole number of pixels from 1 to %d, not %v", name, MAX_DISPLAY_SIZE, pixels, allocator = allocator)
			}
			if name == "width" {
				change.width = i32(pixels)
			} else {
				change.height = i32(pixels)
			}
		case "hdr":
			if luau.type(L, -1) != .BOOLEAN {
				return {}, "hdr takes a boolean"
			}
			// On is Auto, which is HDR10 while the display is in HDR. A request for an HDR mode stays as it is.
			if luau.toboolean(L, -1) {
				change.output = state.output if state.output != .Sdr else .Auto
			} else {
				change.output = .Sdr
			}
		case "paper_white":
			if luau.type(L, -1) != .NUMBER {
				return {}, "paper_white takes a number"
			}
			change.paper_white = f32(luau.tonumber(L, -1))
		case "hdr_available":
			return {}, "hdr_available cannot be set"
		case:
			return {}, fmt.aprintf("there is no display field %q", name, allocator = allocator)
		}
	}
	return
}

// Display.set(change) makes the fields that change gives the display's, as Display.get has them. The window changes at
// once, and the frame target follows from the next frame. A field that does not exist, a mode that is not one, a size
// that is not a display mode while the mode is Fullscreen, or a paper white outside its range raises an error, which
// changes nothing. A change that the window refuses is logged, and Display.get shows what the window is.
@(private = "file")
display_set_binding :: proc(L: ^luau.State) -> c.int {
	luau.L_checktype(L, 1, .TABLE)
	platform := script.runtime_of(L).platform
	allocator := platform.frame_allocator
	state := platform.display_state()
	change, problem := display_change_of(L, state, allocator)
	if problem == "" {
		problem = display_problem(change, state, platform.display_resolutions(allocator))
	}
	if problem != "" {
		script.raise(L, fmt.aprintf("Display.set: %s", problem, allocator = allocator))
	}
	apply_display(platform, script_quality_of(L).renderer, change)
	return 0
}

// Display.save() writes the display to the user settings file, as the player's choice on this machine. It returns false
// if it could not write the file.
@(private = "file")
display_save_binding :: proc(L: ^luau.State) -> c.int {
	sq := script_quality_of(L)
	platform := script.runtime_of(L).platform
	choice := display_choice(platform.display_state(), sq.renderer.paper_white)
	ok := save_display(platform, string(sq.path[:sq.path_len]), choice)
	luau.pushboolean(L, b32(ok))
	return 1
}

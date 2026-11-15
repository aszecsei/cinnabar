package project

import "core:fmt"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

import "cinnabar:core"
import "cinnabar:core/gpu"
import "cinnabar:engine/render"

// The display's keys of the settings files (see docs/overview/architecture.md#project-settings). The output mode is
// the `output` key, which Settings.output holds.
OUTPUT_KEY :: "output"
DISPLAY_MODE_KEY :: "display.mode"
DISPLAY_WIDTH_KEY :: "display.width"
DISPLAY_HEIGHT_KEY :: "display.height"
DISPLAY_PAPER_WHITE_KEY :: "display.paper_white"

// The most pixels on a side that display.width and display.height take.
MAX_DISPLAY_SIZE :: 16384

Display_Key :: enum u8 {
	Mode,
	Width,
	Height,
	Paper_White,
}

Display_Keys :: bit_set[Display_Key]

@(rodata)
DISPLAY_KEY_NAMES := [Display_Key]string {
	.Mode        = DISPLAY_MODE_KEY,
	.Width       = DISPLAY_WIDTH_KEY,
	.Height      = DISPLAY_HEIGHT_KEY,
	.Paper_White = DISPLAY_PAPER_WHITE_KEY,
}

// Display_Settings are the display keys that the files give: given says which, and the others keep their zero values.
Display_Settings :: struct {
	given:       Display_Keys,
	mode:        core.Window_Mode,
	width:       i32,
	height:      i32,
	// In nits, from render.MIN_PAPER_WHITE to render.MAX_PAPER_WHITE.
	paper_white: f32,
}

// parse_display_key reads a display key's value into settings. known is whether key is a display key, and problem says
// why its value does not fit, in which case settings keep what they had.
parse_display_key :: proc(
	settings: ^Settings,
	key, value: string,
) -> (
	known: bool,
	problem: string,
) {
	d := &settings.display
	switch key {
	case DISPLAY_MODE_KEY:
		mode, ok := reflect.enum_from_name(core.Window_Mode, value)
		if !ok {
			return true, fmt.tprintf("%s takes %s, not %q", key, window_mode_names(), value)
		}
		d.mode, d.given = mode, d.given + {.Mode}
	case DISPLAY_WIDTH_KEY, DISPLAY_HEIGHT_KEY:
		pixels, ok := strconv.parse_int(value, 10)
		if !ok || pixels < 1 || pixels > MAX_DISPLAY_SIZE {
			return true, fmt.tprintf(
				"%s takes a whole number of pixels from 1 to %d, not %q",
				key,
				MAX_DISPLAY_SIZE,
				value,
			)
		}
		if key == DISPLAY_WIDTH_KEY {
			d.width, d.given = i32(pixels), d.given + {.Width}
		} else {
			d.height, d.given = i32(pixels), d.given + {.Height}
		}
	case DISPLAY_PAPER_WHITE_KEY:
		nits, ok := strconv.parse_f32(value)
		if !ok || nits < render.MIN_PAPER_WHITE || nits > render.MAX_PAPER_WHITE {
			return true, fmt.tprintf(
				"%s takes a number of nits from %d to %d, not %q",
				key,
				render.MIN_PAPER_WHITE,
				render.MAX_PAPER_WHITE,
				value,
			)
		}
		d.paper_white, d.given = nits, d.given + {.Paper_White}
	case:
		return false, ""
	}
	return true, ""
}

// window_mode_names is the names of the window modes, as a message lists them.
window_mode_names :: proc() -> string {
	return strings.join(reflect.enum_field_names(core.Window_Mode), ", ", context.temp_allocator)
}

// Display_Choice is what the player chose, as the user file keeps it. A paper_white of 0 is no choice, and its key
// stays as the file has it.
Display_Choice :: struct {
	mode:        core.Window_Mode,
	width:       i32,
	height:      i32,
	output:      gpu.Output_Request,
	paper_white: f32,
}

// with_display is a settings file's text with the keys of a choice set, and its other lines as they were.
with_display :: proc(
	text: string,
	c: Display_Choice,
	allocator := context.temp_allocator,
) -> string {
	mode, _ := reflect.enum_name_from_value(c.mode)
	output, _ := reflect.enum_name_from_value(c.output)
	out := set_value(text, DISPLAY_MODE_KEY, mode)
	out = set_value(out, DISPLAY_WIDTH_KEY, fmt.tprintf("%d", c.width))
	out = set_value(out, DISPLAY_HEIGHT_KEY, fmt.tprintf("%d", c.height))
	out = set_value(out, OUTPUT_KEY, output)
	if c.paper_white > 0 {
		out = set_value(out, DISPLAY_PAPER_WHITE_KEY, fmt.tprintf("%v", c.paper_white))
	}
	return strings.clone(out, allocator)
}

// save_display writes a choice to the user file beside a project file, as save_quality writes a quality. It returns
// false if it could not write the file.
save_display :: proc(platform: ^core.Platform_API, path: string, c: Display_Choice) -> bool {
	user := user_path(path, platform.frame_allocator)
	text := ""
	if data, ok := platform.file_read(user, 1, platform.frame_allocator); ok {
		text = string(data)
	}
	text = with_display(text, c, platform.frame_allocator)
	if !platform.file_write(user, transmute([]byte)text) {
		log.errorf("project: could not write %s", user)
		return false
	}
	return true
}

// display_choice is the player's choice that a window's state and the renderer's paper white make: the mode, the
// client size that the mode shows, the output, and the paper white if the player has set one.
display_choice :: proc(state: core.Display_State, paper_white: f32) -> Display_Choice {
	size := state.size if state.mode == .Fullscreen else state.requested
	return {state.mode, size.x, size.y, state.output, paper_white}
}

// Display_Change is a change to the display. Each field that is set replaces the display's own, and the others stay.
// The output is the request for the output mode.
Display_Change :: struct {
	mode:        Maybe(core.Window_Mode),
	width:       Maybe(i32),
	height:      Maybe(i32),
	output:      Maybe(gpu.Output_Request),
	paper_white: Maybe(f32),
}

// display_target is the mode and size that a change gives the window, from its state: the mode that it names or the
// current one, and the size that it names or the one that the mode keeps. Fullscreen's is the display mode, which is
// the monitor's own unless the window is already Fullscreen; Windowed's and Borderless's is the requested client size.
display_target :: proc(
	change: Display_Change,
	state: core.Display_State,
) -> (
	mode: core.Window_Mode,
	size: [2]i32,
) {
	mode = change.mode.? or_else state.mode
	switch {
	case mode != .Fullscreen:
		size = state.requested
	case state.mode == .Fullscreen:
		size = state.size
	case:
		size = state.monitor
	}
	size.x = change.width.? or_else size.x
	size.y = change.height.? or_else size.y
	return
}

// display_problem says why a change does not fit, or is empty. resolutions is what the window's monitor has: Fullscreen
// needs one of them.
display_problem :: proc(
	change: Display_Change,
	state: core.Display_State,
	resolutions: [][2]i32,
) -> string {
	for side in ([]struct {
			value: Maybe(i32),
			name:  string,
		}{{change.width, "width"}, {change.height, "height"}}) {
		if pixels, ok := side.value.?; ok && (pixels < 1 || pixels > MAX_DISPLAY_SIZE) {
			return fmt.tprintf(
				"%s takes a whole number of pixels from 1 to %d, not %d",
				side.name,
				MAX_DISPLAY_SIZE,
				pixels,
			)
		}
	}
	if nits, ok := change.paper_white.?;
	   ok && (nits < render.MIN_PAPER_WHITE || nits > render.MAX_PAPER_WHITE) {
		return fmt.tprintf(
			"paper_white takes nits from %d to %d, not %v",
			render.MIN_PAPER_WHITE,
			render.MAX_PAPER_WHITE,
			nits,
		)
	}
	mode, size := display_target(change, state)
	moves := change.mode != nil || change.width != nil || change.height != nil
	if mode == .Fullscreen && moves && !slice.contains(resolutions, size) {
		return fmt.tprintf(
			"%dx%d is not a display mode of this monitor, so Fullscreen cannot show it: Display.resolutions() lists them",
			size.x,
			size.y,
		)
	}
	return ""
}

// apply_display makes a change the display's: the window's mode and size, the output request and the renderer's paper
// white. The window changes when the change names a mode or a size that differs from its own, and the change commits
// only if the window did. It returns false when the window refused, which core logs; the output and the paper white
// apply either way, because they do not depend on the window.
apply_display :: proc(
	platform: ^core.Platform_API,
	r: ^render.Renderer,
	change: Display_Change,
) -> (
	ok: bool,
) {
	ok = true
	state := platform.display_state()
	if change.mode != nil || change.width != nil || change.height != nil {
		mode, size := display_target(change, state)
		current := state.size if state.mode == .Fullscreen else state.requested
		// Borderless covers the monitor whatever its size, and the size is only kept.
		if mode != state.mode || size != current {
			ok = platform.set_window_mode(mode, size)
		}
	}
	if output, has := change.output.?; has && output != state.output {
		platform.gpu_request_output(output)
	}
	if nits, has := change.paper_white.?; has {
		render.set_paper_white(r, nits)
	}
	return
}

// Display_File is the display that the settings files gave when the game last applied them.
Display_File :: struct {
	display: Display_Settings,
	output:  gpu.Output_Request,
}

// apply_display_settings applies the display keys of settings, when they differ from those that applied before, so a
// settings file's change to another key leaves what the player set since. applied is what applied last: it commits
// only when the window changed, so a refused change tries again at the next refresh.
apply_display_settings :: proc(
	applied: ^Maybe(Display_File),
	platform: ^core.Platform_API,
	r: ^render.Renderer,
	settings: Settings,
) {
	file := Display_File{settings.display, settings.output}
	if last, has := applied.?; has && last == file {
		return
	}
	d := settings.display
	change := Display_Change {
		output = settings.output,
	}
	if .Mode in d.given {
		change.mode = d.mode
	}
	if .Width in d.given {
		change.width = d.width
	}
	if .Height in d.given {
		change.height = d.height
	}
	if .Paper_White in d.given {
		change.paper_white = d.paper_white
	}
	if apply_display(platform, r, change) {
		applied^ = file
	}
}

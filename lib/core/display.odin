package core

import "base:runtime"
import "core:slice"

import "cinnabar:core/gpu"

// How the window is shown (see docs/gpu/presentation.md#window-modes).
Window_Mode :: enum u8 {
	// A normal window, whose client area has the chosen size, in the middle of its monitor.
	Windowed,
	// A window without a frame that covers the whole monitor it is on, at the monitor's own resolution.
	Borderless,
	// A window without a frame that covers the monitor, after the monitor has changed to the display mode of the chosen
	// size.
	Fullscreen,
}

// Screen_Rect is a rectangle of the desktop in pixels. Right and bottom are one past the last pixel.
Screen_Rect :: struct {
	left, top, right, bottom: i32,
}

screen_rect_size :: proc(r: Screen_Rect) -> [2]i32 {
	return {r.right - r.left, r.bottom - r.top}
}

// Window_Layout is where the window goes for a mode: its outer rectangle, and the client area inside it, which is the
// size of the frame target.
Window_Layout :: struct {
	rect:   Screen_Rect,
	client: [2]i32,
}

// window_layout is the window's place in a mode. monitor is the whole monitor, work the part of it that the taskbar
// leaves, client the size that Windowed and Fullscreen ask for, and frame the pixels that a normal window's frame and
// title bar add to its client area.
//
// Windowed gives the client size that fits the work area, centred on the monitor and then moved into the work area
// if the taskbar cuts it. Borderless covers the monitor and ignores client. Fullscreen starts at the monitor's corner
// and has the client size, which is the monitor's display mode by then.
window_layout :: proc(
	mode: Window_Mode,
	monitor, work: Screen_Rect,
	client, frame: [2]i32,
) -> (
	layout: Window_Layout,
) {
	switch mode {
	case .Windowed:
		available := screen_rect_size(work)
		outer := [2]i32 {
			min(max(client.x, 1) + frame.x, available.x),
			min(max(client.y, 1) + frame.y, available.y),
		}
		size := screen_rect_size(monitor)
		left := monitor.left + (size.x - outer.x) / 2
		top := monitor.top + (size.y - outer.y) / 2
		left = clamp(left, work.left, work.right - outer.x)
		top = clamp(top, work.top, work.bottom - outer.y)
		layout.rect = {left, top, left + outer.x, top + outer.y}
		layout.client = {max(outer.x - frame.x, 1), max(outer.y - frame.y, 1)}
	case .Borderless:
		layout.rect = monitor
		layout.client = screen_rect_size(monitor)
	case .Fullscreen:
		layout.client = {max(client.x, 1), max(client.y, 1)}
		layout.rect = {
			monitor.left,
			monitor.top,
			monitor.left + layout.client.x,
			monitor.top + layout.client.y,
		}
	}
	return
}

// resolutions_of is the distinct sizes among a monitor's display modes, largest first: by pixel count, and then by
// width. Modes that differ only in refresh rate or color depth give one size, and a mode with no area is dropped.
resolutions_of :: proc(modes: [][2]i32, allocator: runtime.Allocator) -> (sizes: [][2]i32) {
	list := make([dynamic][2]i32, 0, len(modes), allocator)
	for mode in modes {
		if mode.x <= 0 || mode.y <= 0 || slice.contains(list[:], mode) {
			continue
		}
		append(&list, mode)
	}
	slice.sort_by(list[:], proc(a, b: [2]i32) -> bool {
		if area_a, area_b := a.x * a.y, b.x * b.y; area_a != area_b {
			return area_a > area_b
		}
		return a.x > b.x
	})
	return list[:]
}

// Display_State is how the window is shown now.
Display_State :: struct {
	mode:          Window_Mode,
	// The client area, which the frame target has. It is zero while minimized.
	size:          [2]i32,
	// The client size that the last successful set_window_mode asked for in Windowed or Borderless. It is what Windowed
	// returns to, as Borderless's size is the monitor's, and Fullscreen's display mode leaves it as it was.
	requested:     [2]i32,
	// The monitor that the window is on.
	monitor:       [2]i32,
	// The display shows HDR now: the desktop is in HDR mode on it. Zero in shared mode.
	hdr_available: bool,
	// The output that the game asked for last, or CINNABAR_OUTPUT's.
	output:        gpu.Output_Request,
}

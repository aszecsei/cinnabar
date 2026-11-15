package core

import "core:testing"

// A 1920x1080 monitor at the desktop's origin, with a 40 pixel taskbar below, and a frame of 16x39 pixels.
@(private = "file")
MONITOR :: Screen_Rect{0, 0, 1920, 1080}
@(private = "file")
WORK :: Screen_Rect{0, 0, 1920, 1040}
@(private = "file")
FRAME :: [2]i32{16, 39}

@(test)
windowed_is_centred_and_fits_the_work_area :: proc(t: ^testing.T) {
	// A client area that fits is centred on the monitor, and the frame adds to it.
	layout := window_layout(.Windowed, MONITOR, WORK, {1280, 720}, FRAME)
	testing.expect_value(t, layout.client, [2]i32{1280, 720})
	testing.expect_value(t, layout.rect, Screen_Rect{312, 160, 312 + 1296, 160 + 759})

	// A client area as large as the monitor is cut to the work area, and keeps its place in it.
	layout = window_layout(.Windowed, MONITOR, WORK, {1920, 1080}, FRAME)
	testing.expect_value(t, layout.rect, Screen_Rect{0, 0, 1920, 1040})
	testing.expect_value(t, layout.client, [2]i32{1920 - 16, 1040 - 39})

	// Centring on a monitor that is not at the origin, and a taskbar at the top, which moves a window that it would cut.
	right := Screen_Rect{1920, -200, 3840, 880}
	top_work := Screen_Rect{1920, -160, 3840, 880}
	layout = window_layout(.Windowed, right, top_work, {1900, 1000}, FRAME)
	testing.expect_value(t, layout.rect.top, i32(-160))
	testing.expect_value(t, layout.rect.bottom, i32(-160 + 1039))
	testing.expect_value(t, layout.rect.left, i32(1920 + (1920 - 1916) / 2))
	testing.expect_value(t, layout.client, [2]i32{1900, 1000})

	// A size without area still has a client area.
	layout = window_layout(.Windowed, MONITOR, WORK, {0, -5}, FRAME)
	testing.expect_value(t, layout.client, [2]i32{1, 1})
}

@(test)
borderless_covers_the_monitor :: proc(t: ^testing.T) {
	// Whatever size it is given, and wherever the monitor is.
	right := Screen_Rect{1920, -200, 3840, 880}
	layout := window_layout(.Borderless, right, right, {640, 480}, FRAME)
	testing.expect_value(t, layout.rect, right)
	testing.expect_value(t, layout.client, [2]i32{1920, 1080})
}

@(test)
fullscreen_has_the_display_modes_size_at_the_monitors_corner :: proc(t: ^testing.T) {
	// The monitor's rectangle is already the one of the new display mode.
	mode := Screen_Rect{0, 0, 1280, 720}
	layout := window_layout(.Fullscreen, mode, mode, {1280, 720}, FRAME)
	testing.expect_value(t, layout.rect, mode)
	testing.expect_value(t, layout.client, [2]i32{1280, 720})
}

@(test)
resolutions_are_distinct_and_largest_first :: proc(t: ^testing.T) {
	// Refresh rates and color depths repeat a size. A mode with no area is not a size.
	modes := [][2]i32 {
		{1280, 720},
		{1920, 1080},
		{1280, 720},
		{3840, 2160},
		{1920, 1080},
		{0, 600},
		{1600, 1200},
		{2560, 1440},
		{1440, 1920},
	}
	sizes := resolutions_of(modes, context.temp_allocator)
	want := [][2]i32 {
		{3840, 2160},
		{2560, 1440},
		{1440, 1920},
		{1920, 1080},
		{1600, 1200},
		{1280, 720},
	}
	testing.expect_value(t, len(sizes), len(want))
	for size, i in sizes {
		testing.expect_value(t, size, want[i])
	}
	testing.expect_value(t, len(resolutions_of(nil, context.temp_allocator)), 0)
}

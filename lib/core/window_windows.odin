#+private
package core

import "base:runtime"
import "core:log"
import "core:slice"
import win "core:sys/windows"
import "core:time"

WINDOW_CLASS :: "cinnabar_window"

@(private = "file")
window: struct {
	hwnd:            win.HWND,
	close_requested: bool,
	input:           Input,
	// The mouse position at the last WM_MOUSEMOVE, for the delta. Unknown until the first one.
	mouse_known:     bool,
	// The first half of a character that WM_CHAR sends in two.
	high_surrogate:  u16,
	gamepads:        Gamepad_Poller,
	// How the window is shown, which _window_set_mode alone changes (see docs/gpu/presentation.md#window-modes), and the
	// client size that its last successful call asked for in Windowed or Borderless.
	mode:            Window_Mode,
	requested:       [2]i32,
	// The GDI name of the monitor whose display mode Fullscreen changed, until it is restored. It is set while the
	// display mode differs from the desktop's, which is when the mode is Fullscreen, unless a change of the window
	// failed after the display mode changed.
	display_changed: Maybe([32]u16),
	// Alt+Enter was pressed. _window_poll takes it after the messages, since the window procedure has no context.
	alt_enter:       bool,
}

_window_open :: proc(title: string, width, height: i32, visible := true) -> bool {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = window_proc,
		hInstance     = instance,
		// A release's icon, which the export writes as icon group 1 (see docs/world/game-package.md#releases). The host
		// has none, and the window takes Windows' default.
		hIcon         = win.LoadIconW(instance, transmute(win.LPCWSTR)uintptr(1)),
		hCursor       = win.LoadCursorW(nil, transmute(win.LPCWSTR)win.IDC_ARROW),
		lpszClassName = win.L(WINDOW_CLASS),
	}
	if win.RegisterClassExW(&class) == 0 {
		return false
	}

	style := win.WS_OVERLAPPEDWINDOW
	if visible {
		style |= win.WS_VISIBLE
	}
	rect := win.RECT{0, 0, width, height}
	win.AdjustWindowRect(&rect, style, false)
	window.hwnd = win.CreateWindowExW(
		0,
		win.L(WINDOW_CLASS),
		win.utf8_to_wstring(title),
		style,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil,
		nil,
		instance,
		nil,
	)
	window.requested = {width, height}
	return window.hwnd != nil
}

_window_close :: proc() {
	if device, changed := window.display_changed.?; changed {
		restore_display_mode(device)
		window.display_changed = nil
	}
	if window.hwnd != nil {
		win.DestroyWindow(window.hwnd)
		window.hwnd = nil
	}
}

_window_poll :: proc() -> (open: bool) {
	input_begin_frame(&window.input)
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
	if window.alt_enter {
		window.alt_enter = false
		_window_set_mode(window.mode == .Windowed ? .Borderless : .Windowed, window.requested)
	}
	// XInput answers any process, so the pads belong to this window only while it is in the foreground. A hidden
	// window never does, and in shared mode the editor's viewport sends the pads.
	if _window_has_focus() {
		gamepad_poll(&window.gamepads, &window.input, time.tick_now(), xinput_read)
	}
	return !window.close_requested
}

// _window_has_focus is whether the window is the foreground window. A hidden window, as in shared mode, never is.
_window_has_focus :: proc() -> bool {
	return window.hwnd != nil && win.GetForegroundWindow() == window.hwnd
}

// _window_apply_input applies input from elsewhere after the window's messages of the frame.
_window_apply_input :: proc(events: []Input_Event) {
	for e in events {
		input_apply(&window.input, e)
	}
}

_window_native_handle :: proc() -> rawptr {
	return rawptr(window.hwnd)
}

_window_size :: proc() -> [2]i32 {
	rect: win.RECT
	win.GetClientRect(window.hwnd, &rect)
	return {rect.right - rect.left, rect.bottom - rect.top}
}

// _window_input is the input state after the last _window_poll.
_window_input :: proc() -> Input {
	return window.input
}

_window_set_title :: proc(title: string) {
	win.SetWindowTextW(window.hwnd, win.utf8_to_wstring(title))
}

// _window_display_state is how the window is shown. The platform fills in the output.
_window_display_state :: proc() -> (state: Display_State) {
	state.mode, state.requested, state.size = window.mode, window.requested, _window_size()
	if monitor, ok := window_monitor(); ok {
		state.monitor = screen_rect_size(monitor.rect)
	}
	return
}

// _window_resolutions is the distinct sizes of the display modes of the monitor that the window is on, largest first.
_window_resolutions :: proc(allocator: runtime.Allocator) -> [][2]i32 {
	monitor, ok := window_monitor()
	if !ok {
		return nil
	}
	return resolutions_of(monitor_modes(monitor.device), allocator)
}

// _window_set_mode shows the window in a mode, with a client size for Windowed and a display mode for Fullscreen, which
// must be one of _window_resolutions. Borderless covers its monitor and keeps size for Windowed to return to, and
// Fullscreen leaves that size as it was. It returns false and keeps the window as it was when the display mode or the window did not change. This is the only
// writer of window.mode, window.requested and window.display_changed.
_window_set_mode :: proc(mode: Window_Mode, size: [2]i32) -> bool {
	if window.hwnd == nil || size.x <= 0 || size.y <= 0 {
		return false
	}
	monitor, found := window_monitor()
	if !found {
		log.error("core: cannot find the window's monitor")
		return false
	}
	// The display mode first, since the monitor's rectangle follows it.
	if mode == .Fullscreen {
		if !slice.contains(
			resolutions_of(monitor_modes(monitor.device), context.temp_allocator),
			size,
		) {
			log.errorf("core: the monitor has no display mode of %dx%d", size.x, size.y)
			return false
		}
		if !change_display_mode(monitor.device, size) {
			log.errorf("core: the monitor did not change to %dx%d", size.x, size.y)
			return false
		}
	}
	if old, changed := window.display_changed.?;
	   changed && (mode != .Fullscreen || old != monitor.device) {
		restore_display_mode(old)
	}
	window.display_changed = monitor.device if mode == .Fullscreen else nil
	// The monitor's rectangle is the one of the new display mode.
	monitor, found = window_monitor()
	if !found {
		return false
	}
	frame_rect := win.RECT{}
	win.AdjustWindowRect(&frame_rect, win.WS_OVERLAPPEDWINDOW, false)
	layout := window_layout(
		mode,
		monitor.rect,
		monitor.work,
		size,
		{frame_rect.right - frame_rect.left, frame_rect.bottom - frame_rect.top},
	)
	style := win.WS_OVERLAPPEDWINDOW if mode == .Windowed else win.WS_POPUP
	if win.IsZoomed(window.hwnd) || win.IsIconic(window.hwnd) {
		win.ShowWindow(window.hwnd, win.SW_RESTORE)
	}
	win.SetWindowLongPtrW(window.hwnd, win.GWL_STYLE, win.LONG_PTR(style | win.WS_VISIBLE))
	rect := layout.rect
	if !win.SetWindowPos(
		window.hwnd,
		win.HWND_TOP,
		rect.left,
		rect.top,
		rect.right - rect.left,
		rect.bottom - rect.top,
		win.SWP_FRAMECHANGED | win.SWP_SHOWWINDOW,
	) {
		log.error("core: the window did not move")
		return false
	}
	window.mode = mode
	if mode != .Fullscreen {
		window.requested = size
	}
	return true
}

@(private = "file")
Monitor :: struct {
	rect:   Screen_Rect,
	work:   Screen_Rect,
	// The GDI device name, which the display modes are by.
	device: [32]u16,
}

@(private = "file")
window_monitor :: proc() -> (monitor: Monitor, ok: bool) {
	handle := win.MonitorFromWindow(window.hwnd, .MONITOR_DEFAULTTONEAREST)
	info: win.MONITORINFOEXW
	info.cbSize = size_of(win.MONITORINFOEXW)
	if handle == nil || !win.GetMonitorInfoW(handle, (^win.MONITORINFO)(&info)) {
		return
	}
	rect := proc(r: win.RECT) -> Screen_Rect {
		return {r.left, r.top, r.right, r.bottom}
	}
	return {rect(info.rcMonitor), rect(info.rcWork), info.szDevice}, true
}

// monitor_modes is the sizes of a monitor's 32-bit display modes, one for each mode, so a size can repeat.
@(private = "file")
monitor_modes :: proc(device: [32]u16) -> [][2]i32 {
	device := device
	modes := make([dynamic][2]i32, context.temp_allocator)
	mode := win.DEVMODEW {
		dmSize = size_of(win.DEVMODEW),
	}
	for i: win.DWORD = 0; win.EnumDisplaySettingsW(cast(win.wstring)&device[0], i, &mode); i += 1 {
		if mode.dmBitsPerPel >= 32 {
			append(&modes, [2]i32{i32(mode.dmPelsWidth), i32(mode.dmPelsHeight)})
		}
	}
	return modes[:]
}

@(private = "file")
change_display_mode :: proc(device: [32]u16, size: [2]i32) -> bool {
	device := device
	mode := win.DEVMODEW {
		dmSize       = size_of(win.DEVMODEW),
		dmFields     = DM_PELSWIDTH | DM_PELSHEIGHT,
		dmPelsWidth  = win.DWORD(size.x),
		dmPelsHeight = win.DWORD(size.y),
	}
	// CDS_FULLSCREEN makes the mode temporary: Windows restores the desktop's when the process ends.
	return(
		ChangeDisplaySettingsExW(cast(win.wstring)&device[0], &mode, nil, CDS_FULLSCREEN, nil) ==
		DISP_CHANGE_SUCCESSFUL \
	)
}

@(private = "file")
restore_display_mode :: proc(device: [32]u16) {
	device := device
	ChangeDisplaySettingsExW(cast(win.wstring)&device[0], nil, nil, 0, nil)
}

@(private = "file")
DM_PELSWIDTH :: 0x80000
@(private = "file")
DM_PELSHEIGHT :: 0x100000
@(private = "file")
CDS_FULLSCREEN :: 0x4
@(private = "file")
DISP_CHANGE_SUCCESSFUL :: 0

foreign import user32 "system:User32.lib"

@(private = "file", default_calling_convention = "system")
foreign user32 {
	ChangeDisplaySettingsExW :: proc(device: win.wstring, mode: ^win.DEVMODEW, hwnd: win.HWND, flags: win.DWORD, param: rawptr) -> win.LONG ---
}

@(private = "file")
window_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	input := &window.input
	switch msg {
	case win.WM_CLOSE:
		window.close_requested = true
		return 0
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		input_key_down(input, key_of(wparam, lparam))
		// Let Windows handle Alt+F4 and the other system keys too.
		if msg == win.WM_SYSKEYDOWN {
			// Alt+Enter, but not its repeats, switches between Windowed and Borderless.
			if wparam == win.VK_RETURN && (lparam >> 30) & 1 == 0 {
				window.alt_enter = true
				return 0
			}
			break
		}
		return 0
	case win.WM_KEYUP, win.WM_SYSKEYUP:
		input_key_up(input, key_of(wparam, lparam))
		if msg == win.WM_SYSKEYUP {
			break
		}
		return 0
	case win.WM_CHAR:
		input_char(input, &window.high_surrogate, u16(wparam))
		return 0
	case win.WM_IME_COMPOSITION:
		// DefWindowProc draws the composition, and turns what the IME commits into WM_CHAR.
		ime_read_composition(hwnd, input)
	case win.WM_IME_ENDCOMPOSITION:
		input_set_composition(input, {}, 0)
	case win.WM_KILLFOCUS:
		input_release_all(input)
	case win.WM_LBUTTONDOWN, win.WM_RBUTTONDOWN, win.WM_MBUTTONDOWN, win.WM_XBUTTONDOWN:
		input_key_down(input, button_of(msg, wparam))
		// Keep receiving mouse messages while a button is held outside the window.
		win.SetCapture(hwnd)
	case win.WM_LBUTTONUP, win.WM_RBUTTONUP, win.WM_MBUTTONUP, win.WM_XBUTTONUP:
		input_key_up(input, button_of(msg, wparam))
		if input.down & {.Mouse_Left, .Mouse_Right, .Mouse_Middle, .Mouse_4, .Mouse_5} == {} {
			win.ReleaseCapture()
		}
	case win.WM_MOUSEMOVE:
		position := [2]f32{f32(win.GET_X_LPARAM(lparam)), f32(win.GET_Y_LPARAM(lparam))}
		if window.mouse_known {
			input.mouse_delta += position - input.mouse_position
		}
		input.mouse_position = position
		window.mouse_known = true
	case win.WM_MOUSEWHEEL:
		input.scroll += f32(win.GET_WHEEL_DELTA_WPARAM(wparam)) / win.WHEEL_DELTA
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private = "file")
button_of :: proc "contextless" (msg: win.UINT, wparam: win.WPARAM) -> Key {
	switch msg {
	case win.WM_LBUTTONDOWN, win.WM_LBUTTONUP:
		return .Mouse_Left
	case win.WM_RBUTTONDOWN, win.WM_RBUTTONUP:
		return .Mouse_Right
	case win.WM_MBUTTONDOWN, win.WM_MBUTTONUP:
		return .Mouse_Middle
	}
	return win.GET_XBUTTON_WPARAM(wparam) == win.XBUTTON1 ? .Mouse_4 : .Mouse_5
}

// key_of maps a virtual key to a Key. Shift, Control and Alt arrive without a side, so the scan code or the
// extended-key flag tells left from right.
@(private = "file")
key_of :: proc "contextless" (wparam: win.WPARAM, lparam: win.LPARAM) -> Key {
	vk := win.UINT(wparam)
	extended := (lparam >> 24) & 1 == 1
	switch vk {
	case 'A' ..= 'Z':
		return Key(int(Key.A) + int(vk - 'A'))
	case '0' ..= '9':
		return Key(int(Key.Num_0) + int(vk - '0'))
	case win.VK_F1 ..= win.VK_F12:
		return Key(int(Key.F1) + int(vk - win.VK_F1))
	case win.VK_SHIFT:
		scan := win.UINT(lparam >> 16) & 0xff
		return(
			win.MapVirtualKeyW(scan, win.MAPVK_VSC_TO_VK_EX) == win.VK_RSHIFT ? .Right_Shift : .Left_Shift \
		)
	case win.VK_CONTROL:
		return extended ? .Right_Control : .Left_Control
	case win.VK_MENU:
		return extended ? .Right_Alt : .Left_Alt
	case win.VK_SPACE:
		return .Space
	case win.VK_RETURN:
		return .Enter
	case win.VK_ESCAPE:
		return .Escape
	case win.VK_TAB:
		return .Tab
	case win.VK_BACK:
		return .Backspace
	case win.VK_DELETE:
		return .Delete
	case win.VK_INSERT:
		return .Insert
	case win.VK_HOME:
		return .Home
	case win.VK_END:
		return .End
	case win.VK_PRIOR:
		return .Page_Up
	case win.VK_NEXT:
		return .Page_Down
	case win.VK_LEFT:
		return .Left
	case win.VK_RIGHT:
		return .Right
	case win.VK_UP:
		return .Up
	case win.VK_DOWN:
		return .Down
	}
	return .None
}

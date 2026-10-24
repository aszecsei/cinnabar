#+private
package core

import win "core:sys/windows"

WINDOW_CLASS :: "cinnabar_window"

@(private = "file")
window: struct {
	hwnd:            win.HWND,
	close_requested: bool,
	input:           Input,
	// The mouse position at the last WM_MOUSEMOVE, for the delta. Unknown until the first one.
	mouse_known:     bool,
}

_window_open :: proc(title: string, width, height: i32, visible := true) -> bool {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = window_proc,
		hInstance     = instance,
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
	return window.hwnd != nil
}

_window_close :: proc() {
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
	return !window.close_requested
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

@(private = "file")
window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	input := &window.input
	switch msg {
	case win.WM_CLOSE:
		window.close_requested = true
		return 0
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		input_key_down(input, key_of(wparam, lparam))
		// Let Windows handle Alt+F4 and the other system keys too.
		if msg == win.WM_SYSKEYDOWN {
			break
		}
		return 0
	case win.WM_KEYUP, win.WM_SYSKEYUP:
		input_key_up(input, key_of(wparam, lparam))
		if msg == win.WM_SYSKEYUP {
			break
		}
		return 0
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
		return win.MapVirtualKeyW(scan, win.MAPVK_VSC_TO_VK_EX) == win.VK_RSHIFT ? .Right_Shift : .Left_Shift
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

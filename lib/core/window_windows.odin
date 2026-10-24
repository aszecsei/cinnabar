#+private
package core

import win "core:sys/windows"

WINDOW_CLASS :: "cinnabar_window"

@(private = "file")
window: struct {
	hwnd:            win.HWND,
	close_requested: bool,
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

_window_set_title :: proc(title: string) {
	win.SetWindowTextW(window.hwnd, win.utf8_to_wstring(title))
}

@(private = "file")
window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	switch msg {
	case win.WM_CLOSE:
		window.close_requested = true
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

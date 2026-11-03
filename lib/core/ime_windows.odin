#+private
package core

import win "core:sys/windows"

foreign import imm32 "system:imm32.lib"

@(private = "file")
HIMC :: distinct rawptr

@(private = "file")
GCS_COMPSTR: win.DWORD : 0x0008
@(private = "file")
GCS_CURSORPOS: win.DWORD : 0x0080

@(private = "file")
@(default_calling_convention = "system")
foreign imm32 {
	ImmGetContext :: proc(hwnd: win.HWND) -> HIMC ---
	ImmReleaseContext :: proc(hwnd: win.HWND, himc: HIMC) -> win.BOOL ---
	// The result is bytes for a string, and the units before the cursor for GCS_CURSORPOS.
	ImmGetCompositionStringW :: proc(himc: HIMC, index: win.DWORD, buffer: rawptr, size: win.DWORD) -> i32 ---
}

// ime_read_composition puts what the window's IME is composing now into input. Empty is no composition.
ime_read_composition :: proc "contextless" (hwnd: win.HWND, input: ^Input) {
	himc := ImmGetContext(hwnd)
	if himc == nil {
		return
	}
	units: [INPUT_TEXT_CAPACITY]u16
	size := ImmGetCompositionStringW(himc, GCS_COMPSTR, &units, size_of(units))
	cursor := ImmGetCompositionStringW(himc, GCS_CURSORPOS, nil, 0)
	ImmReleaseContext(hwnd, himc)
	input_composition_utf16(input, units[:max(size, 0) / size_of(u16)], int(cursor))
}

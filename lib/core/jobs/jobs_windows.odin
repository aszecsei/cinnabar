package jobs

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

// Saves the floating-point state on each switch.
@(private = "file")
FIBER_FLAG_FLOAT_SWITCH :: 0x1

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	CreateFiberEx :: proc(stack_commit, stack_reserve: uint, flags: u32, start: win.LPFIBER_START_ROUTINE, param: rawptr) -> rawptr ---
	ConvertThreadToFiberEx :: proc(param: rawptr, flags: u32) -> rawptr ---
	ConvertFiberToThread :: proc() -> win.BOOL ---
}

@(private)
_fiber_create :: proc(reserve, commit: uint, start: proc "system" (param: rawptr), param: rawptr) -> rawptr {
	return CreateFiberEx(commit, reserve, FIBER_FLAG_FLOAT_SWITCH, start, param)
}

@(private)
_fiber_delete :: proc(fiber: rawptr) {
	if fiber != nil {
		win.DeleteFiber(fiber)
	}
}

@(private)
_fiber_switch :: proc(fiber: rawptr) {
	win.SwitchToFiber(fiber)
}

@(private)
_thread_to_fiber :: proc(param: rawptr) -> rawptr {
	return ConvertThreadToFiberEx(param, FIBER_FLAG_FLOAT_SWITCH)
}

@(private)
_fiber_to_thread :: proc() {
	ConvertFiberToThread()
}

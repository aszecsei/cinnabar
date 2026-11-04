package audio_mixer

import win "core:sys/windows"
import "core:time"

// A high-resolution timer for the mix thread. time.sleep has the resolution of the system tick, 15.6 ms by default,
// which is three of the mixer's blocks.
@(private)
Timer :: win.HANDLE

@(private)
timer_create :: proc() -> Timer {
	return win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
}

@(private)
timer_destroy :: proc(timer: Timer) {
	if timer != nil {
		win.CloseHandle(timer)
	}
}

@(private)
timer_wait :: proc(timer: Timer, milliseconds: int) {
	// A negative due time is relative, in 100 ns units.
	due := win.LARGE_INTEGER(-i64(milliseconds) * 10000)
	if timer != nil && win.SetWaitableTimerEx(timer, &due, 0, nil, nil, nil, 0) {
		win.WaitForSingleObject(timer, win.INFINITE)
		return
	}
	sleep_ms(milliseconds)
}

@(private)
sleep_ms :: proc(milliseconds: int) {
	time.sleep(time.Duration(milliseconds) * time.Millisecond)
}

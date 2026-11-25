package core_math

import "base:intrinsics"
import "core:math"

// Tween_Loop is what a tween does after its duration.
Tween_Loop :: enum u8 {
	// It holds its end.
	Once,
	// It starts again from its start.
	Repeat,
	// It goes back to its start, then forward again, in turn.
	Ping_Pong,
}

// Tween is a change of a value from one value to another over a time, along an easing (see
// docs/core/math.md#tweens). It is a description, not a running state: the caller keeps the time since it began, such
// as a script coroutine's, and asks for the value at that time, so a tween is plain data that a code reload keeps and
// that any number of callers can share. T is a float or an array of floats, such as a position or a color; a rotation
// takes the progress and slerps itself.
Tween :: struct($T: typeid) {
	from, to: T,
	// In seconds, or any unit that the caller's time is in. 0 or less is a jump to to.
	duration: f32,
	// The time before the change starts, in the same unit.
	delay:    f32,
	ease:     Ease,
	loop:     Tween_Loop,
}

// tween_progress is a tween's eased progress at a time since it began: 0 before its delay ends, and along its easing
// and its loop after.
tween_progress :: proc "contextless" (tw: Tween($T), elapsed: f32) -> f32 {
	t := elapsed - tw.delay
	if t <= 0 {
		return 0
	}
	if tw.duration <= 0 {
		return 1
	}
	x := t / tw.duration
	switch tw.loop {
	case .Once:
		x = min(x, 1)
	case .Repeat:
		x -= math.floor(x)
	case .Ping_Pong:
		x -= 2 * math.floor(x / 2)
		if x > 1 {
			x = 2 - x
		}
	}
	return ease(tw.ease, x)
}

// tween_value is a tween's value at a time since it began.
tween_value :: proc "contextless" (tw: Tween($T), elapsed: f32) -> T {
	E :: intrinsics.type_elem_type(T)
	return tw.from + (tw.to - tw.from) * E(tween_progress(tw, elapsed))
}

// tween_done is whether a tween that plays once has reached its end. A tween that loops is never done.
tween_done :: proc "contextless" (tw: Tween($T), elapsed: f32) -> bool {
	return tw.loop == .Once && elapsed >= tw.delay + tw.duration
}

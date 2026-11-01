package anim

import "core:testing"

@(private = "file")
near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

@(test)
the_clock_advances_by_ticks_and_wraps :: proc(t: ^testing.T) {
	a := DEFAULT_ANIMATOR
	a.duration = 1
	for _ in 0 ..< 3 {
		advance(&a, 0.25)
	}
	testing.expect(t, near(a.time, 0.75) && near(a.step, 0.25))
	advance(&a, 0.5)
	testing.expect(t, near(a.time, 0.25), "a looping clock wraps")
	testing.expect(t, near(a.step, 0.5), "the step is the distance before the wrap")

	a.speed = 2
	advance(&a, 0.25)
	testing.expect(t, near(a.time, 0.75))

	held := Animator{speed = 1, playing = true, duration = 1, time = 0.9}
	advance(&held, 0.25)
	testing.expect(t, near(held.time, 1) && near(held.step, 0.1), "without loop it holds at the end")
	advance(&held, 0.25)
	testing.expect(t, near(held.time, 1) && near(held.step, 0))

	stopped := DEFAULT_ANIMATOR
	stopped.duration, stopped.playing, stopped.time = 1, false, 0.5
	advance(&stopped, 0.25)
	testing.expect(t, near(stopped.time, 0.5) && near(stopped.step, 0))

	// Without its clip, an Animator stays at the start.
	unloaded := DEFAULT_ANIMATOR
	advance(&unloaded, 0.25)
	testing.expect_value(t, unloaded.time, 0)
}

@(test)
presentation_interpolates_between_ticks :: proc(t: ^testing.T) {
	a := Animator{loop = true, duration = 1, time = 0.5, step = 0.1}
	testing.expect(t, near(presented_time(a, 1), 0.5))
	testing.expect(t, near(presented_time(a, 0), 0.4))
	testing.expect(t, near(presented_time(a, 0.5), 0.45))
	// Across the wrap, it goes back to the end of the clip.
	wrapped := Animator{loop = true, duration = 1, time = 0.05, step = 0.1}
	testing.expect(t, near(presented_time(wrapped, 0.25), 0.975))
	held := Animator{duration = 1, time = 0.05, step = 0.1}
	testing.expect(t, near(presented_time(held, 0.25), 0))
}

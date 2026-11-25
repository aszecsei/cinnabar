package core_math

import "core:testing"

@(test)
every_easing_starts_at_0_and_ends_at_1 :: proc(t: ^testing.T) {
	for e in Ease {
		testing.expectf(t, ease(e, f32(0)) == 0 && ease(e, f32(1)) == 1, "%v in f32", e)
		testing.expectf(t, ease(e, f64(0)) == 0 && ease(e, f64(1)) == 1, "%v in f64", e)
		testing.expectf(t, ease(e, f32(-3)) == 0 && ease(e, f32(7)) == 1, "%v clamps", e)
		// Each is continuous: no step between close parts.
		last := f64(0)
		for i in 1 ..= 1000 {
			v := ease(e, f64(i) / 1000)
			testing.expectf(t, abs(v - last) < 0.05, "%v jumps at %d: %v after %v", e, i, v, last)
			last = v
		}
	}
}

@(test)
an_out_easing_mirrors_its_in_easing :: proc(t: ^testing.T) {
	PAIRS :: [?][2]Ease {
		{.In_Quad, .Out_Quad},
		{.In_Cubic, .Out_Cubic},
		{.In_Quart, .Out_Quart},
		{.In_Quint, .Out_Quint},
		{.In_Sine, .Out_Sine},
		{.In_Expo, .Out_Expo},
		{.In_Circ, .Out_Circ},
		{.In_Back, .Out_Back},
		{.In_Elastic, .Out_Elastic},
		{.In_Bounce, .Out_Bounce},
	}
	for pair in PAIRS {
		for i in 0 ..= 64 {
			x := f64(i) / 64
			a, b := ease(pair[1], x), 1 - ease(pair[0], 1 - x)
			testing.expectf(t, abs(a - b) < 1e-9, "%v at %v: %v, not %v", pair[1], x, a, b)
		}
	}
	// An In_Out easing is its In easing on the first half, scaled, and is a half at the middle.
	for e in ([?]Ease{.In_Out_Quad, .In_Out_Cubic, .In_Out_Quart, .In_Out_Quint, .In_Out_Sine, .In_Out_Circ}) {
		testing.expectf(
			t,
			abs(ease(e, 0.5) - 0.5) < 1e-12,
			"%v at the middle: %v",
			e,
			ease(e, 0.5),
		)
	}
	testing.expect(t, abs(ease(.In_Out_Cubic, 0.25) - ease(.In_Cubic, 0.5) / 2) < 1e-12)
}

@(test)
the_camera_easings_keep_their_formulas :: proc(t: ^testing.T) {
	for i in 0 ..= 32 {
		x := f32(i) / 32
		testing.expect(t, ease(.Smoothstep, x) == x * x * (3 - 2 * x))
		testing.expect(t, ease(.In_Quad, x) == x * x)
		testing.expect(t, ease(.Out_Quad, x) == 1 - (1 - x) * (1 - x))
		y := f64(i) / 32
		testing.expect(t, ease(.Smoothstep, y) == y * y * (3 - 2 * y))
	}
	testing.expect(t, ease(.Smootherstep, f64(0.5)) == 0.5)
	testing.expect(t, ease(.Out_Back, f64(0.7)) > 1, "back overshoots")
	testing.expect(t, ease(.Out_Elastic, f64(0.1)) > 1, "elastic swings past")
}

@(test)
a_bezier_easing_is_drawn_by_its_handles :: proc(t: ^testing.T) {
	for i in 0 ..= 16 {
		x := f64(i) / 16
		// Handles on the line are the line.
		testing.expect(t, abs(ease_bezier(1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3, x) - x) < 1e-9)
	}
	// CSS's ease-in-out is symmetric about the middle.
	testing.expect(t, abs(ease_bezier(0.42, 0, 0.58, 1, 0.5) - 0.5) < 1e-9)
	testing.expect(t, ease_bezier(0.42, 0, 0.58, 1, 0.25) < 0.25)
	testing.expect(
		t,
		ease_bezier(0.42, 0, 0.58, 1, 0) == 0 && ease_bezier(0.42, 0, 0.58, 1, 1) == 1,
	)
}

@(test)
a_tween_waits_eases_and_loops :: proc(t: ^testing.T) {
	once := Tween(f32) {
		from     = 2,
		to       = 6,
		duration = 2,
		delay    = 1,
		ease     = .Linear,
	}
	testing.expect_value(t, tween_value(once, 0), 2)
	testing.expect_value(t, tween_value(once, 1), 2)
	testing.expect_value(t, tween_value(once, 2), 4)
	testing.expect_value(t, tween_value(once, 3), 6)
	testing.expect_value(t, tween_value(once, 9), 6)
	testing.expect(t, !tween_done(once, 2.5) && tween_done(once, 3))

	repeat := once
	repeat.loop = .Repeat
	testing.expect_value(t, tween_value(repeat, 4), 4)
	testing.expect(t, !tween_done(repeat, 100))
	ping := once
	ping.loop = .Ping_Pong
	testing.expect_value(t, tween_value(ping, 4), 4)
	testing.expect_value(t, tween_value(ping, 4.5), 3)
	testing.expect_value(t, tween_value(ping, 5.5), 3)

	jump := Tween(f32) {
		from = 1,
		to   = 5,
	}
	testing.expect_value(t, tween_value(jump, 0.001), 5)

	move := Tween([3]f32) {
		from     = {0, 0, 0},
		to       = {2, 4, 6},
		duration = 1,
		ease     = .Smoothstep,
	}
	testing.expect_value(t, tween_value(move, 0.5), [3]f32{1, 2, 3})
	wide := Tween([2]f64) {
		from     = {0, 0},
		to       = {1, -1},
		duration = 1,
		ease     = .Linear,
	}
	testing.expect_value(t, tween_value(wide, 0.25), [2]f64{0.25, -0.25})
}

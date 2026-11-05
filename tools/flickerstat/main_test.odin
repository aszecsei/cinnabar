package flickerstat

import "core:math"
import "core:testing"

destroy_stats :: proc(s: ^Stats) {
	delete(s.mean)
	delete(s.m2)
	delete(s.largest)
	delete(s.previous)
	delete(s.steps)
}

@(test)
a_still_view_has_no_spread_and_no_steps :: proc(t: ^testing.T) {
	s: Stats
	defer destroy_stats(&s)
	values := []f32{10, 20, 30, 40}
	for frame in 0 ..< i64(4) {
		testing.expect(t, add(&s, values, {2, 2}, frame))
	}
	spreads := spread(&s, context.temp_allocator)
	for v in spreads {
		testing.expect_value(t, v, 0)
	}
	testing.expect_value(t, len(s.steps), 3)
	testing.expect_value(t, s.steps[0].mean, 0)
	testing.expect_value(t, s.steps[0].popped, 0)
}

@(test)
a_pop_has_a_large_step_at_its_pixel_and_a_small_spread :: proc(t: ^testing.T) {
	// One pixel of four jumps by 32 codes once in 32 screenshots and stays there.
	s: Stats
	defer destroy_stats(&s)
	for frame in 0 ..< i64(32) {
		values := []f32{10, 10, frame < 31 ? f32(10) : 42, 10}
		testing.expect(t, add(&s, values, {2, 2}, frame + 100))
	}
	testing.expect_value(t, s.largest[2], 32)
	testing.expect_value(t, s.largest[0], 0)
	last := s.steps[len(s.steps) - 1]
	testing.expect_value(t, last.from, 130)
	testing.expect_value(t, last.to, 131)
	testing.expect_value(t, last.popped, 0.25)
	testing.expect_value(t, last.low, [2]int{0, 1})
	testing.expect_value(t, last.high, [2]int{0, 1})
	spreads := spread(&s, context.temp_allocator)
	testing.expect(t, spreads[2] > 5 && spreads[2] < 6)
}

@(test)
noise_spreads_as_its_standard_deviation :: proc(t: ^testing.T) {
	s: Stats
	defer destroy_stats(&s)
	for frame in 0 ..< i64(1000) {
		values := []f32{frame % 2 == 0 ? f32(90) : 110}
		testing.expect(t, add(&s, values, {1, 1}, frame))
	}
	spreads := spread(&s, context.temp_allocator)
	testing.expect(t, abs(spreads[0] - 10) < 0.01)
	testing.expect_value(t, s.largest[0], 20)
	testing.expect(t, math.abs(s.mean[0] - 100) < 0.01)
}

@(test)
a_resize_is_refused :: proc(t: ^testing.T) {
	s: Stats
	defer destroy_stats(&s)
	testing.expect(t, add(&s, []f32{1, 2}, {2, 1}, 0))
	testing.expect(t, !add(&s, []f32{1, 2}, {1, 2}, 1))
}

@(test)
quantiles_read_a_sorted_copy :: proc(t: ^testing.T) {
	values := make([]f32, 1000, context.temp_allocator)
	for &v, i in values {
		v = f32(999 - i)
	}
	q := quantiles(values)
	testing.expect_value(t, q.p50, 500)
	testing.expect_value(t, q.p99, 990)
	testing.expect_value(t, q.most, 999)
	testing.expect_value(t, values[0], 999)
}

@(test)
luma_weighs_rec_709 :: proc(t: ^testing.T) {
	out := luma({0, 255, 0, 255, 255, 255}, context.temp_allocator)
	testing.expect_value(t, len(out), 2)
	testing.expect(t, abs(out[0] - 0.7152 * 255) < 0.01)
	testing.expect(t, abs(out[1] - 255) < 0.01)
}

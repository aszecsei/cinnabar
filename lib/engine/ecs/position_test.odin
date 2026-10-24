package ecs

import "core:testing"

UNIT :: 1.0 / (1 << POSITION_FRACTION_BITS)

@(test)
precision_is_independent_of_distance :: proc(t: ^testing.T) {
	far := World_Position{{1 << 61, -(1 << 61), 0}}
	next := World_Position{far.raw + {1, -1, 0}}
	testing.expect_value(t, position_sub(next, far), [3]f32{UNIT, -UNIT, 0})
	testing.expect_value(t, position_offset(far, {UNIT, -UNIT, 0}), next)
}

@(test)
sub_spans_the_whole_range :: proc(t: ^testing.T) {
	low := World_Position{{-POSITION_LIMIT, 0, 0}}
	high := World_Position{{POSITION_LIMIT, 0, 0}}
	testing.expect_value(t, position_sub(high, low).x, f32(1 << 39))
	testing.expect_value(t, position_sub(low, high).x, -f32(1 << 39))
}

@(test)
offset_rounds_to_nearest :: proc(t: ^testing.T) {
	origin: World_Position
	testing.expect_value(t, position_offset(origin, {0.6 * UNIT, -0.6 * UNIT, 0.4 * UNIT}).raw, [3]i64{1, -1, 0})
}

@(test)
offset_reverses :: proc(t: ^testing.T) {
	start := position_from_meters({1.5e11, -3, 42})
	delta := [3]f32{0.0123, -7.5, 1e-5}
	p := start
	for _ in 0 ..< 1000 {
		p = position_offset(p, delta)
	}
	for _ in 0 ..< 1000 {
		p = position_offset(p, -delta)
	}
	testing.expect_value(t, p, start)
}

@(test)
offset_inverts_sub :: proc(t: ^testing.T) {
	a := position_from_meters({1e9, 2.25, -1e9})
	b := position_from_meters({1e9 + 100.125, -1.5, -1e9 + 0.5})
	testing.expect_value(t, position_offset(a, position_sub(b, a)), b)
}

@(test)
lerp_hits_both_ends :: proc(t: ^testing.T) {
	a := position_from_meters({-1e10, 0, 1})
	b := position_from_meters({-1e10 + 3, 4, 1})
	testing.expect_value(t, position_lerp(a, b, 0), a)
	testing.expect_value(t, position_lerp(a, b, 1), b)
	testing.expect_value(t, position_sub(position_lerp(a, b, 0.5), a), [3]f32{1.5, 2, 0})
}

@(test)
meters_round_trip :: proc(t: ^testing.T) {
	m := [3]f64{12345.5, -0.25, 1 << 28}
	testing.expect_value(t, position_to_meters(position_from_meters(m)), m)
}

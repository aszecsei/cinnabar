package core_math

import "base:intrinsics"
import "core:math"

// Arc_Length is a table of a spline's length from its start at even steps of its parameter, per_segment steps to a
// segment: the map between a distance along the path and its parameter. A change of parameter moves along a spline at
// a speed that changes with its shape, so a follower at a constant speed, or points spaced evenly along a path, need
// it. The caller owns cumulative, sized by arc_length_count, and builds it once for a path that does not change.
Arc_Length :: struct($F: typeid) {
	cumulative:  []F,
	per_segment: int,
}

// arc_length_count is the size of an Arc_Length table for a spline: a distance at every step, both ends included.
// 8 steps to a segment is close for most paths; a segment that bends sharply needs more.
arc_length_count :: proc "contextless" (s: Spline($T), per_segment: int) -> int {
	return spline_segment_count(s) * per_segment + 1
}

// arc_length_build fills cumulative, of arc_length_count's size, with a spline's length at each step, and is its
// table.
arc_length_build :: proc "contextless" (
	s: Spline($T),
	per_segment: int,
	cumulative: []$F,
) -> Arc_Length(F) where F ==
	intrinsics.type_elem_type(T) {
	cumulative[0] = 0
	k := 0
	for i in 0 ..< spline_segment_count(s) {
		c := spline_segment(s, i)
		for j in 0 ..< per_segment {
			u0, u1 := F(j) / F(per_segment), F(j + 1) / F(per_segment)
			cumulative[k + 1] = cumulative[k] + bezier_length(c, u0, u1)
			k += 1
		}
	}
	return {cumulative = cumulative[:k + 1], per_segment = per_segment}
}

// arc_length_total is the length of the table's spline.
arc_length_total :: proc "contextless" (a: Arc_Length($F)) -> F {
	return a.cumulative[len(a.cumulative) - 1] if len(a.cumulative) > 0 else 0
}

// arc_length_param is the spline's parameter at a distance along it from its start. An open spline clamps the distance
// to its length; a closed one wraps it. hint, when given, is where the last call found the distance, and makes a
// follower that moves on a little each call find its step at once.
arc_length_param :: proc "contextless" (
	a: Arc_Length($F),
	s: Spline($T),
	distance: F,
	hint: ^int = nil,
) -> F where F ==
	intrinsics.type_elem_type(T) {
	total := arc_length_total(a)
	if len(a.cumulative) < 2 || total <= 0 {
		return 0
	}
	d := distance
	if s.closed {
		d -= total * math.floor(d / total)
	} else {
		d = clamp(d, 0, total)
	}
	k, part := find_segment(a.cumulative, d, hint)
	segment, step := k / a.per_segment, k % a.per_segment
	per := F(a.per_segment)
	lo, hi := F(step) / per, F(step + 1) / per
	u := lo + (hi - lo) * part
	// Newton's method on the length from the step's start, whose derivative is the speed.
	c := spline_segment(s, segment)
	for _ in 0 ..< 2 {
		speed := vector_length(bezier_tangent(c, u))
		if speed <= 0 {
			break
		}
		u = clamp(u - (a.cumulative[k] + bezier_length(c, lo, u) - d) / speed, lo, hi)
	}
	return F(segment) + u
}

// arc_length_distance is the distance along the spline from its start to its parameter t: arc_length_param's inverse.
arc_length_distance :: proc "contextless" (
	a: Arc_Length($F),
	s: Spline($T),
	t: F,
) -> F where F ==
	intrinsics.type_elem_type(T) {
	if len(a.cumulative) < 2 {
		return 0
	}
	i, u := spline_locate(s, t)
	step := min(int(u * F(a.per_segment)), a.per_segment - 1)
	lo := F(step) / F(a.per_segment)
	return a.cumulative[i * a.per_segment + step] + bezier_length(spline_segment(s, i), lo, u)
}

// arc_length_spaced fills out with parameters evenly spaced by distance along the spline: from its start to its end
// for an open spline, both included, and around a closed one from its start, the last a step before it, so that rings
// of a tube or posts of a fence are spaced evenly, whatever the spline's speed.
arc_length_spaced :: proc "contextless" (
	a: Arc_Length($F),
	s: Spline($T),
	out: []F,
) where F ==
	intrinsics.type_elem_type(T) {
	n := len(out)
	if n == 0 {
		return
	}
	total := arc_length_total(a)
	steps := F(n) if s.closed else F(max(n - 1, 1))
	hint := 0
	for &t, i in out {
		t = arc_length_param(a, s, total * F(i) / steps, &hint)
	}
}

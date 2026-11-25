package core_math

import "base:intrinsics"
import "core:math"

// Spline_Kind is how a spline's points make its segments.
Spline_Kind :: enum u8 {
	// Straight segments through the points.
	Linear,
	// Bezier segments: a point, its out handle, the next point's in handle, the next point, and so on. An open spline of
	// k segments has 3k + 1 points; a closed one has 3k, the last being the first point's in handle.
	Bezier,
	// Hermite segments: pairs of a point and its tangent, in change per unit of the segment's parameter.
	Hermite,
	// A curve through the points, each tangent from its neighbours (see catmull_rom_to_bezier and alpha). An open
	// spline's ends are mirrored, so it starts and ends at its first and last point.
	Catmull_Rom,
	// A uniform cubic B-spline: a curve near the points, smooth through every join. An open spline does not reach its
	// end points.
	B_Spline,
}

// Spline is a path: segments made from points by a kind (see docs/core/math.md#paths). It is a view of points that the
// caller owns, so it is cheap to make from a level's data each frame. T is a float or an array of floats, usually
// [3]f32 in a local space that the caller anchors to a world position. Its parameter runs from 0 at its start to its
// segment count at its end, a whole number at each join, and a closed spline wraps it.
Spline :: struct($T: typeid) {
	points: []T,
	kind:   Spline_Kind,
	// The last point joins the first.
	closed: bool,
	// A Catmull-Rom spline's spacing of knots: 0 uniform, 0.5 centripetal, 1 chordal.
	alpha:  f32,
}

// spline_segment_count is how many segments a spline has. Too few points for one is 0.
spline_segment_count :: proc "contextless" (s: Spline($T)) -> int {
	n := len(s.points)
	switch s.kind {
	case .Linear, .Catmull_Rom:
		if n < 2 {
			return 0
		}
		return n if s.closed else n - 1
	case .Bezier:
		if s.closed {
			return n / 3
		}
		return (n - 1) / 3 if n >= 4 else 0
	case .Hermite:
		knots := n / 2
		if knots < 2 {
			return 0
		}
		return knots if s.closed else knots - 1
	case .B_Spline:
		if s.closed {
			return n if n >= 3 else 0
		}
		return n - 3 if n >= 4 else 0
	}
	return 0
}

// spline_segment is a spline's segment i as a cubic Bezier segment. i is from 0 to before the segment count.
spline_segment :: proc "contextless" (s: Spline($T), i: int) -> [4]T {
	P := s.points
	n := len(P)
	at :: #force_inline proc "contextless" (P: []$T, j: int) -> T {
		n := len(P)
		return P[((j % n) + n) % n]
	}
	switch s.kind {
	case .Linear:
		return line_to_bezier(P[i], at(P, i + 1))
	case .Bezier:
		return {P[3 * i], P[3 * i + 1], P[3 * i + 2], at(P, 3 * i + 3)}
	case .Hermite:
		knots := n / 2
		j := (i + 1) % knots
		return hermite_to_bezier(P[2 * i], P[2 * i + 1], P[2 * j], P[2 * j + 1])
	case .Catmull_Rom:
		p1, p2 := P[i], at(P, i + 1)
		p0, p3: T
		if s.closed {
			p0, p3 = at(P, i - 1), at(P, i + 2)
		} else {
			p0 = P[i - 1] if i > 0 else 2 * p1 - p2
			p3 = P[i + 2] if i + 2 < n else 2 * p2 - p1
		}
		return catmull_rom_to_bezier(p0, p1, p2, p3, intrinsics.type_elem_type(T)(s.alpha))
	case .B_Spline:
		return bspline_to_bezier(P[i], at(P, i + 1), at(P, i + 2), at(P, i + 3))
	}
	return {}
}

// spline_locate is the segment and its own parameter, from 0 to 1, at a spline's parameter t. An open spline clamps t
// to its ends; a closed one wraps it. A spline with no segment is 0 and 0.
spline_locate :: proc "contextless" (
	s: Spline($T),
	t: intrinsics.type_elem_type(T),
) -> (
	i: int,
	u: intrinsics.type_elem_type(T),
) {
	F :: intrinsics.type_elem_type(T)
	count := spline_segment_count(s)
	if count == 0 {
		return 0, 0
	}
	t := t
	if s.closed {
		t -= F(count) * math.floor(t / F(count))
	} else {
		t = clamp(t, 0, F(count))
	}
	i = clamp(int(t), 0, count - 1)
	return i, clamp(t - F(i), 0, 1)
}

// spline_point is a spline's point at its parameter t. A spline with no segment is its one point, or zero.
spline_point :: proc "contextless" (s: Spline($T), t: intrinsics.type_elem_type(T)) -> T {
	if spline_segment_count(s) == 0 {
		return s.points[0] if len(s.points) > 0 else {}
	}
	i, u := spline_locate(s, t)
	return bezier_point(spline_segment(s, i), u)
}

// spline_tangent is a spline's velocity at its parameter t, per unit of t. It is not normalized: its length is the
// speed at which a constant change of t moves along the path, which an Arc_Length table evens out.
spline_tangent :: proc "contextless" (s: Spline($T), t: intrinsics.type_elem_type(T)) -> T {
	if spline_segment_count(s) == 0 {
		return {}
	}
	i, u := spline_locate(s, t)
	return bezier_tangent(spline_segment(s, i), u)
}

// spline_closest is the parameter of a spline's point nearest p, and the squared distance to it: how far along a path
// something is, such as a racer on a track.
spline_closest :: proc "contextless" (
	s: Spline($T),
	p: T,
) -> (
	t, dist_sq: intrinsics.type_elem_type(T),
) {
	F :: intrinsics.type_elem_type(T)
	dist_sq = max(F)
	for i in 0 ..< spline_segment_count(s) {
		u, d := bezier_closest(spline_segment(s, i), p)
		if d < dist_sq {
			t, dist_sq = F(i) + u, d
		}
	}
	return
}

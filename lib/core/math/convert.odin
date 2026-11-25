package core_math

import "base:intrinsics"
import "core:math"

// Each kind of segment as the cubic Bezier segment that is the same curve (see bezier.odin), so one set of procedures
// serves them all. T is a float or an array of floats.

// hermite_to_bezier is the Hermite segment from p0 to p1 with the tangents m0 and m1, in change per unit of the
// segment's parameter.
hermite_to_bezier :: proc "contextless" (p0, m0, p1, m1: $T) -> [4]T {
	return {p0, p0 + m0 / 3, p1 - m1 / 3, p1}
}

// catmull_rom_to_bezier is the Catmull-Rom segment from p1 to p2, which p0 and p3 shape. alpha sets how the knots space
// with the distances between the points: 0 is uniform, 0.5 is centripetal, which makes no cusp or loop inside a
// segment, and 1 is chordal (Barry and Goldman's form). Points that coincide count as a distance of 1.
catmull_rom_to_bezier :: proc "contextless" (
	p0, p1, p2, p3: $T,
	alpha: intrinsics.type_elem_type(T),
) -> [4]T {
	knot :: proc "contextless" (a, b: $T, alpha: $F) -> F {
		d := vector_length(b - a)
		if d < 1e-6 {
			return 1
		}
		return math.pow(d, alpha)
	}
	t01, t12, t23 := knot(p0, p1, alpha), knot(p1, p2, alpha), knot(p2, p3, alpha)
	// The tangents at p1 and p2 of the curve through the knots, scaled to the segment's span.
	m1 := ((p1 - p0) / t01 - (p2 - p0) / (t01 + t12) + (p2 - p1) / t12) * t12
	m2 := ((p2 - p1) / t12 - (p3 - p1) / (t12 + t23) + (p3 - p2) / t23) * t12
	return hermite_to_bezier(p1, m1, p2, m2)
}

// bspline_to_bezier is the uniform cubic B-spline segment of four control points: a curve that passes near them, not
// through them, and bends smoothly through its joins, which have no corner and no jump of curvature.
bspline_to_bezier :: proc "contextless" (p0, p1, p2, p3: $T) -> [4]T {
	return {(p0 + 4 * p1 + p2) / 6, (2 * p1 + p2) / 3, (p1 + 2 * p2) / 3, (p1 + 4 * p2 + p3) / 6}
}

// line_to_bezier is the straight segment from p0 to p1, at an even speed.
line_to_bezier :: proc "contextless" (p0, p1: $T) -> [4]T {
	d := p1 - p0
	return {p0, p0 + d / 3, p1 - d / 3, p1}
}

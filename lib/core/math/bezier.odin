package core_math

import "base:intrinsics"
import "core:math"

// A cubic Bezier segment is the one form that every path takes (see docs/core/math.md#paths): four control points
// [4]T, where T is a float or an array of floats, f32 or f64. The curve leaves c[0] toward c[1] and reaches c[3] from
// c[2], at a parameter u from 0 to 1. A Hermite, Catmull-Rom or B-spline segment converts to one (convert.odin), so
// evaluation, derivatives, splitting, bounds, length and frames are written once, here.

// bezier_point is the segment's point at u.
bezier_point :: proc "contextless" (c: [4]$T, u: intrinsics.type_elem_type(T)) -> T {
	r := 1 - u
	return r * r * r * c[0] + 3 * r * r * u * c[1] + 3 * r * u * u * c[2] + u * u * u * c[3]
}

// bezier_tangent is the segment's first derivative at u: its velocity, per unit of u.
bezier_tangent :: proc "contextless" (c: [4]$T, u: intrinsics.type_elem_type(T)) -> T {
	r := 1 - u
	return 3 * (r * r * (c[1] - c[0]) + 2 * r * u * (c[2] - c[1]) + u * u * (c[3] - c[2]))
}

// bezier_second is the segment's second derivative at u: its acceleration, per unit of u squared.
bezier_second :: proc "contextless" (c: [4]$T, u: intrinsics.type_elem_type(T)) -> T {
	r := 1 - u
	return 6 * (r * (c[2] - 2 * c[1] + c[0]) + u * (c[3] - 2 * c[2] + c[1]))
}

// bezier_split cuts the segment at u into two segments that together are the same curve (de Casteljau).
bezier_split :: proc "contextless" (
	c: [4]$T,
	u: intrinsics.type_elem_type(T),
) -> (
	left, right: [4]T,
) {
	p01 := c[0] + (c[1] - c[0]) * u
	p12 := c[1] + (c[2] - c[1]) * u
	p23 := c[2] + (c[3] - c[2]) * u
	p012 := p01 + (p12 - p01) * u
	p123 := p12 + (p23 - p12) * u
	p := p012 + (p123 - p012) * u
	return {c[0], p01, p012, p}, {p, p123, p23, c[3]}
}

// bezier_sub is the part of the segment from u0 to u1, as a segment of its own.
bezier_sub :: proc "contextless" (c: [4]$T, u0, u1: intrinsics.type_elem_type(T)) -> [4]T {
	if u1 <= u0 {
		p := bezier_point(c, u0)
		return {p, p, p, p}
	}
	left, _ := bezier_split(c, u1)
	_, part := bezier_split(left, u0 / u1)
	return part
}

// bezier_bounds is the smallest box that holds the segment, each component's extremes: its ends, and where its
// derivative is 0 between them.
bezier_bounds :: proc "contextless" (c: [4]$T) -> (lo, hi: T) {
	when intrinsics.type_is_array(T) {
		for k in 0 ..< len(T) {
			lo[k], hi[k] = bezier_bounds_1d(c[0][k], c[1][k], c[2][k], c[3][k])
		}
		return
	} else {
		return bezier_bounds_1d(c[0], c[1], c[2], c[3])
	}
}

// bezier_length is the segment's length from u0 to u1, by five-point Gauss-Legendre over its speed. A part of a segment
// that bends sharply is closer cut into pieces, as an Arc_Length table does.
bezier_length :: proc "contextless" (
	c: [4]$T,
	u0: intrinsics.type_elem_type(T) = 0,
	u1: intrinsics.type_elem_type(T) = 1,
) -> intrinsics.type_elem_type(T) {
	F :: intrinsics.type_elem_type(T)
	NODES :: [5]f64 {
		-0.9061798459386640,
		-0.5384693101056831,
		0,
		0.5384693101056831,
		0.9061798459386640,
	}
	WEIGHTS :: [5]f64 {
		0.2369268850561891,
		0.4786286704993665,
		0.5688888888888889,
		0.4786286704993665,
		0.2369268850561891,
	}
	nodes, weights := NODES, WEIGHTS
	half, mid := (u1 - u0) / 2, (u1 + u0) / 2
	total: F
	for node, i in nodes {
		total += F(weights[i]) * vector_length(bezier_tangent(c, mid + half * F(node)))
	}
	return total * half
}

// bezier_closest is the parameter of the segment's point nearest p, and the squared distance to it: the nearest of
// sixteen samples, refined by Newton's method.
bezier_closest :: proc "contextless" (
	c: [4]$T,
	p: T,
) -> (
	u, dist_sq: intrinsics.type_elem_type(T),
) {
	F :: intrinsics.type_elem_type(T)
	SAMPLES :: 16
	dist_sq = max(F)
	for i in 0 ..= SAMPLES {
		at := F(i) / SAMPLES
		d := bezier_point(c, at) - p
		if dd := vector_dot(d, d); dd < dist_sq {
			u, dist_sq = at, dd
		}
	}
	refined := u
	for _ in 0 ..< 4 {
		d := bezier_point(c, refined) - p
		v := bezier_tangent(c, refined)
		slope := vector_dot(v, v) + vector_dot(d, bezier_second(c, refined))
		if slope <= 0 {
			break
		}
		refined = clamp(refined - vector_dot(d, v) / slope, 0, 1)
	}
	d := bezier_point(c, refined) - p
	if dd := vector_dot(d, d); dd < dist_sq {
		u, dist_sq = refined, dd
	}
	return
}

// bezier_bounds_1d is one coordinate's extremes over a cubic Bezier: its ends, and the roots of its derivative, a
// quadratic, inside (0, 1).
@(private)
bezier_bounds_1d :: proc "contextless" (p0, p1, p2, p3: $F) -> (lo, hi: F) {
	lo, hi = min(p0, p3), max(p0, p3)
	// The derivative over 3: a u² + b u + c.
	a := -p0 + 3 * p1 - 3 * p2 + p3
	b := 2 * (p0 - 2 * p1 + p2)
	c := p1 - p0
	roots: [2]F
	count := 0
	EPSILON :: 1e-12
	if abs(a) < EPSILON {
		if abs(b) > EPSILON {
			roots[0], count = -c / b, 1
		}
	} else {
		disc := b * b - 4 * a * c
		if disc >= 0 {
			s := math.sqrt(disc)
			roots[0], roots[1], count = (-b + s) / (2 * a), (-b - s) / (2 * a), 2
		}
	}
	for root in roots[:count] {
		if root > 0 && root < 1 {
			r := 1 - root
			v :=
				r * r * r * p0 +
				3 * r * r * root * p1 +
				3 * r * root * root * p2 +
				root * root * root * p3
			lo, hi = min(lo, v), max(hi, v)
		}
	}
	return
}

// vector_dot is the dot product of two floats or arrays of floats.
@(private)
vector_dot :: proc "contextless" (a, b: $T) -> intrinsics.type_elem_type(T) {
	when intrinsics.type_is_array(T) {
		s: intrinsics.type_elem_type(T)
		for k in 0 ..< len(T) {
			s += a[k] * b[k]
		}
		return s
	} else {
		return a * b
	}
}

// vector_length is the length of a float or an array of floats.
@(private)
vector_length :: proc "contextless" (v: $T) -> intrinsics.type_elem_type(T) {
	return math.sqrt(vector_dot(v, v))
}

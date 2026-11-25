package core_math

// The kernels of the keyed curve. Their arithmetic is f64, + - * / only, in a fixed order, and the editor's C#
// evaluator does the same in the same order (see math.odin), so do not reorder an expression here.

// KEY_SOLVE_STEPS is how many times weighted_param halves a weighted segment's parameter. A fixed count, not a
// tolerance, so another evaluator that does the same arithmetic gets the same value.
KEY_SOLVE_STEPS :: 48

// The three-point Gauss-Legendre rule on [0, 1]: its nodes and weights. It is exact for a polynomial of degree 5.
GAUSS3_NODES :: [3]f64{0.11270166537925831, 0.5, 0.8872983346207417}
GAUSS3_WEIGHTS :: [3]f64{5.0 / 18.0, 8.0 / 18.0, 5.0 / 18.0}

// hermite is the cubic Hermite curve from v0 to v1 at s, from 0 to 1, with the tangents m0 and m1 as changes of value
// over the whole segment.
hermite :: proc "contextless" (v0, m0, v1, m1, s: f64) -> f64 {
	s2 := s * s
	s3 := s2 * s
	return(
		(2 * s3 - 3 * s2 + 1) * v0 +
		(s3 - 2 * s2 + s) * m0 +
		(-2 * s3 + 3 * s2) * v1 +
		(s3 - s2) * m1 \
	)
}

// cubic is a cubic Bezier's coordinate at u, from its four control points' coordinates.
cubic :: proc "contextless" (p0, p1, p2, p3, u: f64) -> f64 {
	r := 1 - u
	return r * r * r * p0 + 3 * r * r * u * p1 + 3 * r * u * u * p2 + u * u * u * p3
}

// weighted_param is the parameter u at which the cubic Bezier x(u) from 0 through x1 and x2 to 1 reaches s. x1 and x2
// from 0 to 1 keep x(u) from falling, so KEY_SOLVE_STEPS halvings find the one u.
weighted_param :: proc "contextless" (x1, x2, s: f64) -> f64 {
	lo, hi := 0.0, 1.0
	for _ in 0 ..< KEY_SOLVE_STEPS {
		mid := (lo + hi) / 2
		if cubic(0, x1, x2, 1, mid) < s {
			lo = mid
		} else {
			hi = mid
		}
	}
	return (lo + hi) / 2
}

// weighted_segment is a weighted Bezier segment's value at s, the part of its duration from 0 to 1: from v0 to v1, with
// the tangents m0 and m1 as changes of value over the whole segment, and the handles reaching w0 and w1 of the
// duration. Weights of a third are the Hermite curve.
weighted_segment :: proc "contextless" (v0, m0, w0, v1, m1, w1, s: f64) -> f64 {
	x1, x2 := w0, 1 - w1
	y1, y2 := v0 + m0 * w0, v1 - m1 * w1
	return cubic(v0, y1, y2, v1, weighted_param(x1, x2, s))
}

// auto_slope is the slope at a point k between a and b that keeps a curve through them from overshooting, in value per
// unit of the durations d_ak (a to k), d_kb (k to b) and d_ab (a to b). A peak, a trough or a point level with a
// neighbour is flat. Otherwise the slope is that of the line through the neighbours, limited to three times the gentler
// of the two sides' slopes, which keeps the curve between the values (Fritsch and Carlson's condition). d_ab is its own
// argument because the keyed curve computes it from the times, not as d_ak + d_kb.
auto_slope :: proc "contextless" (va, vk, vb, d_ak, d_kb, d_ab: f64) -> f64 {
	before := (vk - va) / d_ak
	after := (vb - vk) / d_kb
	if before * after <= 0 {
		return 0
	}
	slope := (vb - va) / d_ab
	limit := 3 * min(abs(before), abs(after))
	return clamp(slope, -limit, limit)
}

// floor_wrap is d divided by span, floored: the whole spans, and the remainder from 0 to before span. span is above 0.
// It is written out, since % truncates toward 0.
floor_wrap :: proc "contextless" (d, span: i64) -> (r, whole: i64) {
	whole = d / span
	r = d - whole * span
	if r < 0 {
		r += span
		whole -= 1
	}
	return
}

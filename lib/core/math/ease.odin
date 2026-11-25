package core_math

import "base:intrinsics"
import "core:math"

// Ease is the shape of a change from 0 to 1 over a part of its time from 0 to 1: a blend, a fade or a tween (see
// docs/core/math.md#easing). In speeds up from rest, Out slows to rest, and In_Out does both. Back overshoots the ends,
// and Elastic and Bounce swing about them. Data names an Ease, never a procedure, so a code reload keeps it. Append
// only: a stored Ease is its number.
Ease :: enum u8 {
	Linear,
	// 3x² − 2x³: no slope at either end.
	Smoothstep,
	// 6x⁵ − 15x⁴ + 10x³: no slope and no curvature at either end.
	Smootherstep,
	In_Quad,
	Out_Quad,
	In_Out_Quad,
	In_Cubic,
	Out_Cubic,
	In_Out_Cubic,
	In_Quart,
	Out_Quart,
	In_Out_Quart,
	In_Quint,
	Out_Quint,
	In_Out_Quint,
	In_Sine,
	Out_Sine,
	In_Out_Sine,
	In_Expo,
	Out_Expo,
	In_Out_Expo,
	In_Circ,
	Out_Circ,
	In_Out_Circ,
	In_Back,
	Out_Back,
	In_Out_Back,
	In_Elastic,
	Out_Elastic,
	In_Out_Elastic,
	In_Bounce,
	Out_Bounce,
	In_Out_Bounce,
}

// ease is a part of a change from 0 to 1 along an easing: exactly 0 at 0 and exactly 1 at 1, with the part clamped
// to that range. Back and Elastic leave [0, 1] between the ends.
ease :: proc "contextless" (e: Ease, part: $F) -> F where intrinsics.type_is_float(F) {
	x := clamp(part, 0, 1)
	if x <= 0 {
		return 0
	}
	if x >= 1 {
		return 1
	}
	PI :: F(math.PI)
	BACK :: F(1.70158)
	BACK_IN_OUT :: BACK * 1.525
	ELASTIC :: 2 * PI / 3
	ELASTIC_IN_OUT :: 2 * PI / 4.5
	// The power of an In curve, and its mirror for an Out curve.
	in_pow :: #force_inline proc "contextless" (x: F, n: int) -> F {
		y := x
		for _ in 1 ..< n {
			y *= x
		}
		return y
	}
	switch e {
	case .Linear:
		return x
	case .Smoothstep:
		return x * x * (3 - 2 * x)
	case .Smootherstep:
		return x * x * x * (x * (x * 6 - 15) + 10)
	case .In_Quad, .In_Cubic, .In_Quart, .In_Quint:
		return in_pow(x, ease_power(e))
	case .Out_Quad:
		return 1 - (1 - x) * (1 - x)
	case .Out_Cubic, .Out_Quart, .Out_Quint:
		return 1 - in_pow(1 - x, ease_power(e))
	case .In_Out_Quad, .In_Out_Cubic, .In_Out_Quart, .In_Out_Quint:
		n := ease_power(e)
		if x < 0.5 {
			return in_pow(2, n - 1) * in_pow(x, n)
		}
		return 1 - in_pow(-2 * x + 2, n) / 2
	case .In_Sine:
		return 1 - math.cos(x * PI / 2)
	case .Out_Sine:
		return math.sin(x * PI / 2)
	case .In_Out_Sine:
		return -(math.cos(PI * x) - 1) / 2
	case .In_Expo:
		return math.pow(F(2), 10 * x - 10)
	case .Out_Expo:
		return 1 - math.pow(F(2), -10 * x)
	case .In_Out_Expo:
		if x < 0.5 {
			return math.pow(F(2), 20 * x - 10) / 2
		}
		return (2 - math.pow(F(2), -20 * x + 10)) / 2
	case .In_Circ:
		return 1 - math.sqrt(1 - x * x)
	case .Out_Circ:
		return math.sqrt(1 - (x - 1) * (x - 1))
	case .In_Out_Circ:
		if x < 0.5 {
			return (1 - math.sqrt(1 - 4 * x * x)) / 2
		}
		return (math.sqrt(1 - (-2 * x + 2) * (-2 * x + 2)) + 1) / 2
	case .In_Back:
		return (BACK + 1) * x * x * x - BACK * x * x
	case .Out_Back:
		y := x - 1
		return 1 + (BACK + 1) * y * y * y + BACK * y * y
	case .In_Out_Back:
		if x < 0.5 {
			return (2 * x) * (2 * x) * ((BACK_IN_OUT + 1) * 2 * x - BACK_IN_OUT) / 2
		}
		y := 2 * x - 2
		return (y * y * ((BACK_IN_OUT + 1) * y + BACK_IN_OUT) + 2) / 2
	case .In_Elastic:
		return -math.pow(F(2), 10 * x - 10) * math.sin((10 * x - 10.75) * ELASTIC)
	case .Out_Elastic:
		return math.pow(F(2), -10 * x) * math.sin((10 * x - 0.75) * ELASTIC) + 1
	case .In_Out_Elastic:
		if x < 0.5 {
			return(
				-(math.pow(F(2), 20 * x - 10) * math.sin((20 * x - 11.125) * ELASTIC_IN_OUT)) /
				2 \
			)
		}
		return math.pow(F(2), -20 * x + 10) * math.sin((20 * x - 11.125) * ELASTIC_IN_OUT) / 2 + 1
	case .In_Bounce:
		return 1 - ease_bounce(1 - x)
	case .Out_Bounce:
		return ease_bounce(x)
	case .In_Out_Bounce:
		if x < 0.5 {
			return (1 - ease_bounce(1 - 2 * x)) / 2
		}
		return (1 + ease_bounce(2 * x - 1)) / 2
	}
	return x
}

// ease_bezier is a part of a change from 0 to 1 along the cubic Bezier from (0, 0) through (x1, y1) and (x2, y2) to
// (1, 1), at a part across: the curve of CSS's cubic-bezier(), which a designer draws with two handles. x1 and x2 are
// clamped to [0, 1], so the curve is a function of the part; y1 and y2 may leave it, to overshoot.
ease_bezier :: proc "contextless" (x1, y1, x2, y2, part: f64) -> f64 {
	x := clamp(part, 0, 1)
	if x <= 0 {
		return 0
	}
	if x >= 1 {
		return 1
	}
	return cubic(0, y1, y2, 1, weighted_param(clamp(x1, 0, 1), clamp(x2, 0, 1), x))
}

// ease_power is the power of a polynomial easing: 2 for a quad to 5 for a quint.
@(private)
ease_power :: proc "contextless" (e: Ease) -> int {
	#partial switch e {
	case .In_Quad, .Out_Quad, .In_Out_Quad:
		return 2
	case .In_Cubic, .Out_Cubic, .In_Out_Cubic:
		return 3
	case .In_Quart, .Out_Quart, .In_Out_Quart:
		return 4
	}
	return 5
}

// ease_bounce is Out_Bounce: four parabolas, each a bounce lower than the last.
@(private)
ease_bounce :: proc "contextless" (x: $F) -> F {
	N :: F(7.5625)
	D :: F(2.75)
	switch {
	case x < 1 / D:
		return N * x * x
	case x < 2 / D:
		y := x - 1.5 / D
		return N * y * y + 0.75
	case x < 2.5 / D:
		y := x - 2.25 / D
		return N * y * y + 0.9375
	}
	y := x - 2.625 / D
	return N * y * y + 0.984375
}

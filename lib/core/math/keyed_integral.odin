package core_math

import "core:math"

// INTEGRAL_CLAMPED_PIECES is how many pieces key_integral cuts a segment that can leave its range into.
INTEGRAL_CLAMPED_PIECES :: 16

// key_integral is the integral of a curve from time 0 to t, which can fall between two ticks, in value × seconds, with
// rate as for key_value. Before the first key and after the last, the curve holds, whatever its extrapolation. A segment
// integrates by three-point Gauss-Legendre over its parameter, which is exact for its polynomial: of degree 3 without
// weights, and of degree 5, y(u) × x'(u), with them. The value is taken clamped to lo and hi, such as a voice's range of
// pitch: a Bezier segment whose handles leave that range integrates the clamped curve in INTEGRAL_CLAMPED_PIECES pieces
// instead, which is close but not exact. An empty curve is 0.
key_integral :: proc "contextless" (
	keys: []Key($Time),
	t: f64,
	rate: f64 = 1,
	lo: f64 = math.NEG_INF_F64,
	hi: f64 = math.INF_F64,
) -> f64 {
	n := len(keys)
	if n == 0 || t <= 0 {
		return 0
	}
	first := f64(keys[0].time)
	if t <= first {
		return f64(keys[0].value) * t / rate
	}
	total := f64(keys[0].value) * first / rate
	for i in 0 ..< n - 1 {
		k0, k1 := keys[i], keys[i + 1]
		if t <= f64(k0.time) {
			break
		}
		span := f64(k1.time - k0.time)
		s := min((t - f64(k0.time)) / span, 1)
		total += key_segment_integral(keys, i, s, rate, lo, hi) * span / rate
	}
	last := f64(keys[n - 1].time)
	if t > last {
		total += f64(keys[n - 1].value) * (t - last) / rate
	}
	return total
}

// key_segment_integral is the integral of the segment from keys[i] to keys[i + 1] over [0, s] of its duration, as a
// part of the duration: so a segment of value 1 gives s.
@(private)
key_segment_integral :: proc "contextless" (
	keys: []Key($Time),
	i: int,
	s, rate, lo, hi: f64,
) -> f64 {
	k0, k1 := keys[i], keys[i + 1]
	v0, v1 := f64(k0.value), f64(k1.value)
	switch k0.interp {
	case .Constant:
		return v0 * s
	case .Linear:
		return v0 * s + (v1 - v0) * s * s / 2
	case .Bezier, .Auto:
	}
	duration := f64(k1.time - k0.time) / rate
	m0 := key_out_slope(keys, i, rate) * duration
	m1 := key_in_slope(keys, i + 1, rate) * duration
	w0, w1, weighted := key_weights(k0, k1)
	y1, y2 := v0 + m0 * w0, v1 - m1 * w1
	nodes, weights := GAUSS3_NODES, GAUSS3_WEIGHTS
	if !(y1 >= lo && y1 <= hi && y2 >= lo && y2 <= hi) {
		// The handles leave the range, so the curve can: integrate the clamped value piece by piece over the time.
		total := 0.0
		piece := s / INTEGRAL_CLAMPED_PIECES
		for p in 0 ..< INTEGRAL_CLAMPED_PIECES {
			for node, j in nodes {
				v := clamp(key_segment_value(keys, i, (f64(p) + node) * piece, rate), lo, hi)
				total += weights[j] * v * piece
			}
		}
		return total
	}
	if !weighted {
		total := 0.0
		for node, j in nodes {
			total += weights[j] * key_segment_value(keys, i, node * s, rate) * s
		}
		return total
	}
	// With weights, x(u) and y(u) are Bezier curves of the parameter: integrate y(u) x'(u) over [0, u(s)], which solves
	// u as weighted_segment does.
	x1, x2 := w0, 1 - w1
	u := weighted_param(x1, x2, s) if s < 1 else 1
	total := 0.0
	for node, j in nodes {
		at := node * u
		r := 1 - at
		dx := 3 * (r * r * x1 + 2 * r * at * (x2 - x1) + at * at * (1 - x2))
		total += weights[j] * cubic(v0, y1, y2, v1, at) * dx * u
	}
	return total
}

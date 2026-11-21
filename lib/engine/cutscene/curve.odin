package cutscene

import format "cinnabar:engine/asset/format"

// CURVE_SOLVE_STEPS is how many times curve_value halves a weighted Bezier segment's parameter to find the parameter at
// a time. A fixed count, not a tolerance, so another evaluator that does the same arithmetic gets the same value.
CURVE_SOLVE_STEPS :: 48

// curve_value is a curve's value at a time, in ticks on the curve's own time (see docs/cinematics/tracks.md#curves).
// The keys are in rising time, as cutscene_view checks. Before the first key and after the last, the curve holds. At a
// key's time, the value is the key's value, exactly. Between keys, the first key's interpolation decides. hint, when
// given, is where the last call found the time, and makes playback that moves forward a little each call find the
// segment at once; it never changes the value. An empty curve is 0.
//
// The arithmetic is f64, + - * / only, in a fixed order, so the editor's evaluator gives the same values.
curve_value :: proc "contextless" (keys: []format.Cutscene_Key, t: i32, hint: ^int = nil) -> f32 {
	n := len(keys)
	if n == 0 {
		return 0
	}
	if t <= keys[0].time {
		return keys[0].value
	}
	if t >= keys[n - 1].time {
		return keys[n - 1].value
	}
	i := curve_segment(keys, t, hint)
	k0, k1 := keys[i], keys[i + 1]
	if t == k0.time {
		return k0.value
	}
	s := f64(t - k0.time) / f64(k1.time - k0.time)
	switch k0.interp {
	case .Constant:
		return k0.value
	case .Linear:
		return f32(f64(k0.value) + (f64(k1.value) - f64(k0.value)) * s)
	case .Bezier, .Auto:
		return f32(curve_bezier(keys, i, s))
	}
	return k0.value
}

// curve_step is a curve's value at a time as if every key were constant: the value of the last key at or before the
// time, or of the first key before it. Fields that cannot take a value between two keys, such as integers, bools, enums
// and assets, step.
curve_step :: proc "contextless" (keys: []format.Cutscene_Key, t: i32, hint: ^int = nil) -> f32 {
	n := len(keys)
	if n == 0 {
		return 0
	}
	if t <= keys[0].time {
		return keys[0].value
	}
	if t >= keys[n - 1].time {
		return keys[n - 1].value
	}
	return keys[curve_segment(keys, t, hint)].value
}

// curve_segment is the index i of the segment that holds a time: keys[i].time <= t < keys[i + 1].time. The time is
// after the first key and before the last. It tries the hint and the segment after it, and else searches by halves.
@(private)
curve_segment :: proc "contextless" (keys: []format.Cutscene_Key, t: i32, hint: ^int) -> int {
	n := len(keys)
	holds :: proc "contextless" (keys: []format.Cutscene_Key, i: int, t: i32) -> bool {
		return i >= 0 && i + 1 < len(keys) && keys[i].time <= t && t < keys[i + 1].time
	}
	if hint != nil {
		if holds(keys, hint^, t) {
			return hint^
		}
		if holds(keys, hint^ + 1, t) {
			hint^ += 1
			return hint^
		}
	}
	// The last key at or before t: keys[lo].time <= t < keys[hi].time.
	lo, hi := 0, n - 1
	for hi - lo > 1 {
		mid := lo + (hi - lo) / 2
		if keys[mid].time <= t {
			lo = mid
		} else {
			hi = mid
		}
	}
	if hint != nil {
		hint^ = lo
	}
	return lo
}

// curve_bezier is the value of the Bezier segment from keys[i] to keys[i + 1] at s, the part of the segment's duration
// from 0 to 1. Without weights, it is a cubic Hermite curve. With weights, it solves the handles' time for s by halves.
@(private)
curve_bezier :: proc "contextless" (keys: []format.Cutscene_Key, i: int, s: f64) -> f64 {
	k0, k1 := keys[i], keys[i + 1]
	duration := f64(k1.time - k0.time) / format.CUTSCENE_TICKS_PER_SECOND
	v0, v1 := f64(k0.value), f64(k1.value)
	// The tangents as changes of value over the whole segment.
	m0 := curve_out_slope(keys, i) * duration
	m1 := curve_in_slope(keys, i + 1) * duration
	w0, w1 := f64(format.CUTSCENE_TANGENT_WEIGHT), f64(format.CUTSCENE_TANGENT_WEIGHT)
	weighted := false
	if k0.interp == .Bezier && .Weighted in k0.flags {
		w0, weighted = f64(k0.out_weight), true
	}
	if k1.interp == .Bezier && .Weighted in k1.flags {
		w1, weighted = f64(k1.in_weight), true
	}
	if !weighted {
		s2 := s * s
		s3 := s2 * s
		return(
			(2 * s3 - 3 * s2 + 1) * v0 +
			(s3 - 2 * s2 + s) * m0 +
			(-2 * s3 + 3 * s2) * v1 +
			(s3 - s2) * m1 \
		)
	}
	// The handles, in the segment's time from 0 to 1 and in value. Weights from 0 to 1 keep x(u) from falling, so the
	// halves find the one u with x(u) = s.
	x1, x2 := w0, 1 - w1
	y1, y2 := v0 + m0 * w0, v1 - m1 * w1
	lo, hi := 0.0, 1.0
	for _ in 0 ..< CURVE_SOLVE_STEPS {
		mid := (lo + hi) / 2
		if curve_cubic(0, x1, x2, 1, mid) < s {
			lo = mid
		} else {
			hi = mid
		}
	}
	return curve_cubic(v0, y1, y2, v1, (lo + hi) / 2)
}

// curve_cubic is a cubic Bezier's coordinate at u, from its four control points' coordinates.
@(private)
curve_cubic :: proc "contextless" (p0, p1, p2, p3, u: f64) -> f64 {
	r := 1 - u
	return r * r * r * p0 + 3 * r * r * u * p1 + 3 * r * u * u * p2 + u * u * u * p3
}

// curve_out_slope is the slope that leaves a key, in value per second: a Bezier key's own, and the automatic one for
// every other key.
@(private)
curve_out_slope :: proc "contextless" (keys: []format.Cutscene_Key, i: int) -> f64 {
	if keys[i].interp == .Bezier {
		return f64(keys[i].out_slope)
	}
	return curve_auto_slope(keys, i)
}

// curve_in_slope is the slope that reaches a key, in value per second: a Bezier key's own, and the automatic one for
// every other key.
@(private)
curve_in_slope :: proc "contextless" (keys: []format.Cutscene_Key, i: int) -> f64 {
	if keys[i].interp == .Bezier {
		return f64(keys[i].in_slope)
	}
	return curve_auto_slope(keys, i)
}

// curve_auto_slope is an automatic key's slope, in value per second. The first and the last key are flat. A key that is
// a peak, a trough, or level with a neighbour is flat, so the curve does not overshoot between keys of one value.
// Otherwise the slope is that of the line through its neighbours, limited to three times the gentler of its two
// segments' slopes, which keeps the curve between the keys' values (Fritsch and Carlson's condition).
@(private)
curve_auto_slope :: proc "contextless" (keys: []format.Cutscene_Key, i: int) -> f64 {
	if i <= 0 || i >= len(keys) - 1 {
		return 0
	}
	a, k, b := keys[i - 1], keys[i], keys[i + 1]
	TICKS :: f64(format.CUTSCENE_TICKS_PER_SECOND)
	before := (f64(k.value) - f64(a.value)) / (f64(k.time - a.time) / TICKS)
	after := (f64(b.value) - f64(k.value)) / (f64(b.time - k.time) / TICKS)
	if before * after <= 0 {
		return 0
	}
	slope := (f64(b.value) - f64(a.value)) / (f64(b.time - a.time) / TICKS)
	limit := 3 * min(abs(before), abs(after))
	return clamp(slope, -limit, limit)
}

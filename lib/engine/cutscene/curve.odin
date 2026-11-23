package cutscene

import format "cinnabar:engine/asset/format"

// CURVE_SOLVE_STEPS is how many times curve_value halves a weighted Bezier segment's parameter to find the parameter at
// a time. A fixed count, not a tolerance, so another evaluator that does the same arithmetic gets the same value.
CURVE_SOLVE_STEPS :: 48

// curve_value is a curve's value at a time, in ticks on the curve's own time (see docs/cinematics/tracks.md#curves).
// The keys are in rising time, as cutscene_view checks. Before the first key, pre decides, and after the last, post does:
// the curve holds, goes on along its end's slope, repeats, repeats offset by the change over its keys, or repeats back
// and forth (see curve_wrap). At a key's time, the value is the key's value, exactly. Between keys, the first key's
// interpolation decides. hint, when given, is where the last call found the time, and makes playback that moves forward
// a little each call find the segment at once; it never changes the value. An empty curve is 0.
//
// The arithmetic is f64, + - * / only, in a fixed order, so the editor's evaluator gives the same values.
curve_value :: proc "contextless" (
	keys: []format.Cutscene_Key,
	t: i32,
	pre, post: format.Cutscene_Infinity,
	hint: ^int = nil,
) -> f32 {
	n := len(keys)
	if n == 0 {
		return 0
	}
	if t >= keys[0].time && t <= keys[n - 1].time {
		return curve_inside(keys, t, hint)
	}
	before := t < keys[0].time
	if (pre if before else post) == .Linear && n > 1 {
		return f32(curve_extend(keys, t, before))
	}
	local, cycles := curve_wrap(keys, t, pre, post)
	return curve_offset(keys, curve_inside(keys, local, hint), cycles)
}

// curve_step is a curve's value at a time as if every key were constant: the value of the last key at or before the
// time, or of the first key before it. Fields that cannot take a value between two keys, such as integers, bools, enums
// and assets, step. pre and post are as for curve_value, except that linear holds, since a step has no slope.
curve_step :: proc "contextless" (
	keys: []format.Cutscene_Key,
	t: i32,
	pre, post: format.Cutscene_Infinity,
	hint: ^int = nil,
) -> f32 {
	n := len(keys)
	if n == 0 {
		return 0
	}
	if t >= keys[0].time && t <= keys[n - 1].time {
		return curve_step_inside(keys, t, hint)
	}
	local, cycles := curve_wrap(keys, t, pre, post)
	return curve_offset(keys, curve_step_inside(keys, local, hint), cycles)
}

// curve_wrap maps a time outside a curve's keys to the time inside them that gives its value, by the mode of its side:
// pre before the first key, post after the last. Constant and linear hold the end key's time; curve_value extends a
// linear side itself. Cycle repeats the keys' span, first key to last, and oscillate repeats it forward and then
// backward in turn. cycles is how many spans a cycle-with-offset side moves the value by, negative before the first key,
// and 0 for every other mode. A curve whose keys span no time holds. The arithmetic is on whole ticks, so the time
// inside is exact. The time is a floored division by the span, written out, since % truncates toward 0.
@(private)
curve_wrap :: proc "contextless" (
	keys: []format.Cutscene_Key,
	t: i32,
	pre, post: format.Cutscene_Infinity,
) -> (
	local: i32,
	cycles: i64,
) {
	first, last := keys[0].time, keys[len(keys) - 1].time
	if t >= first && t <= last {
		return t, 0
	}
	mode := pre if t < first else post
	span := i64(last) - i64(first)
	if span == 0 || mode == .Constant || mode == .Linear {
		return clamp(t, first, last), 0
	}
	d := i64(t) - i64(first)
	whole := d / span
	r := d - whole * span
	if r < 0 {
		r += span
		whole -= 1
	}
	switch mode {
	case .Constant, .Linear:
	case .Cycle:
		return first + i32(r), 0
	case .Cycle_Offset:
		return first + i32(r), whole
	case .Oscillate:
		if whole % 2 != 0 {
			return first + i32(span - r), 0
		}
		return first + i32(r), 0
	}
	return clamp(t, first, last), 0
}

// curve_offset is a value inside a curve moved by cycles times the change from its first key's value to its last's.
@(private)
curve_offset :: proc "contextless" (keys: []format.Cutscene_Key, v: f32, cycles: i64) -> f32 {
	if cycles == 0 {
		return v
	}
	return f32(f64(v) + f64(cycles) * (f64(keys[len(keys) - 1].value) - f64(keys[0].value)))
}

// curve_extend is a linear side's value: the end key's value, then on along the slope that the curve has at that key,
// from its end segment. A constant segment's slope is 0, a linear one's is its own, and a Bezier or automatic one's is
// its tangent's. The curve has at least two keys.
@(private)
curve_extend :: proc "contextless" (keys: []format.Cutscene_Key, t: i32, before: bool) -> f64 {
	TICKS :: f64(format.CUTSCENE_TICKS_PER_SECOND)
	n := len(keys)
	// The end key, and the segment from a to b that touches it.
	end, a, b := n - 1, n - 2, n - 1
	if before {
		end, a, b = 0, 0, 1
	}
	slope := 0.0
	switch keys[a].interp {
	case .Constant:
	case .Linear:
		slope =
			(f64(keys[b].value) - f64(keys[a].value)) / (f64(keys[b].time - keys[a].time) / TICKS)
	case .Bezier, .Auto:
		slope = curve_out_slope(keys, 0) if before else curve_in_slope(keys, n - 1)
	}
	return f64(keys[end].value) + slope * (f64(i64(t) - i64(keys[end].time)) / TICKS)
}

// curve_inside is curve_value at a time from the first key's to the last's.
@(private)
curve_inside :: proc "contextless" (keys: []format.Cutscene_Key, t: i32, hint: ^int) -> f32 {
	n := len(keys)
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

// curve_step_inside is curve_step at a time from the first key's to the last's.
@(private)
curve_step_inside :: proc "contextless" (keys: []format.Cutscene_Key, t: i32, hint: ^int) -> f32 {
	n := len(keys)
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

// curve_integral is the integral of a curve from 0 to a time in ticks, which can fall between two, in value × seconds:
// an audio section's place in its sound from its pitch (see docs/cinematics/tracks.md#audio-tracks). Before the first
// key and after the last, the curve holds, as a pitch curve's infinity is constant (cutscene_view checks it). A segment integrates by three-point Gauss-Legendre over its parameter, which
// is exact for its polynomial: of degree 3 without weights, and of degree 5, y(u) × x'(u), with them. A pitch is what a
// voice plays, CUTSCENE_MIN_PITCH to CUTSCENE_MAX_PITCH, so a Bezier segment whose handles leave that range integrates
// the clamped curve in CURVE_CLAMPED_PIECES pieces instead, which is close but not exact. An empty curve is 0.
curve_integral :: proc "contextless" (keys: []format.Cutscene_Key, t: f64) -> f64 {
	TICKS :: f64(format.CUTSCENE_TICKS_PER_SECOND)
	n := len(keys)
	if n == 0 || t <= 0 {
		return 0
	}
	first := f64(keys[0].time)
	if t <= first {
		return f64(keys[0].value) * t / TICKS
	}
	total := f64(keys[0].value) * first / TICKS
	for i in 0 ..< n - 1 {
		k0, k1 := keys[i], keys[i + 1]
		if t <= f64(k0.time) {
			break
		}
		span := f64(k1.time - k0.time)
		s := min((t - f64(k0.time)) / span, 1)
		total += curve_segment_integral(keys, i, s) * span / TICKS
	}
	last := f64(keys[n - 1].time)
	if t > last {
		total += f64(keys[n - 1].value) * (t - last) / TICKS
	}
	return total
}

// CURVE_CLAMPED_PIECES is how many pieces curve_integral cuts a segment that leaves the pitch's range into.
CURVE_CLAMPED_PIECES :: 16

// The three-point Gauss-Legendre rule on [0, 1]: its nodes and weights.
@(private)
GAUSS_NODES := [3]f64{0.11270166537925831, 0.5, 0.8872983346207417}
@(private)
GAUSS_WEIGHTS := [3]f64{5.0 / 18.0, 8.0 / 18.0, 5.0 / 18.0}

// curve_segment_integral is the integral of the segment from keys[i] to keys[i + 1] over [0, s] of its duration, as a
// part of the duration: so a segment of value 1 gives s.
@(private)
curve_segment_integral :: proc "contextless" (keys: []format.Cutscene_Key, i: int, s: f64) -> f64 {
	k0, k1 := keys[i], keys[i + 1]
	v0, v1 := f64(k0.value), f64(k1.value)
	switch k0.interp {
	case .Constant:
		return v0 * s
	case .Linear:
		return v0 * s + (v1 - v0) * s * s / 2
	case .Bezier, .Auto:
	}
	duration := f64(k1.time - k0.time) / format.CUTSCENE_TICKS_PER_SECOND
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
	y1, y2 := v0 + m0 * w0, v1 - m1 * w1
	in_range :: proc "contextless" (y: f64) -> bool {
		return y >= format.CUTSCENE_MIN_PITCH && y <= format.CUTSCENE_MAX_PITCH
	}
	if !(in_range(y1) && in_range(y2)) {
		// The handles leave the range, so the curve can: integrate the clamped value piece by piece over the time.
		total := 0.0
		piece := s / CURVE_CLAMPED_PIECES
		for p in 0 ..< CURVE_CLAMPED_PIECES {
			for node, j in GAUSS_NODES {
				v := clamp(
					curve_bezier(keys, i, (f64(p) + node) * piece),
					format.CUTSCENE_MIN_PITCH,
					format.CUTSCENE_MAX_PITCH,
				)
				total += GAUSS_WEIGHTS[j] * v * piece
			}
		}
		return total
	}
	if !weighted {
		total := 0.0
		for node, j in GAUSS_NODES {
			total += GAUSS_WEIGHTS[j] * curve_bezier(keys, i, node * s) * s
		}
		return total
	}
	// With weights, x(u) and y(u) are Bezier curves of the parameter: integrate y(u) x'(u) over [0, u(s)], which solves u
	// as curve_bezier does.
	x1, x2 := w0, 1 - w1
	lo, hi := 0.0, 1.0
	for _ in 0 ..< CURVE_SOLVE_STEPS {
		mid := (lo + hi) / 2
		if curve_cubic(0, x1, x2, 1, mid) < s {
			lo = mid
		} else {
			hi = mid
		}
	}
	u := (lo + hi) / 2 if s < 1 else 1
	total := 0.0
	for node, j in GAUSS_NODES {
		at := node * u
		r := 1 - at
		dx := 3 * (r * r * x1 + 2 * r * at * (x2 - x1) + at * at * (1 - x2))
		total += GAUSS_WEIGHTS[j] * curve_cubic(v0, y1, y2, v1, at) * dx * u
	}
	return total
}

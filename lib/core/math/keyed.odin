package core_math

import "base:intrinsics"
import "core:math"

// key_value is a curve's value at a time. The keys are in rising time. rate is the time's units in a second, so the
// slopes, which are in value per second, fit the time: 1 for seconds, or the ticks in a second for ticks. Before the
// first key, pre decides, and after the last, post does (see Extrapolation and key_wrap). At a key's time, the value is
// the key's value, exactly. Between keys, the first key's interpolation decides. hint, when given, is where the last
// call found the time, and makes playback that moves forward a little each call find the segment at once; it never
// changes the value. An empty curve is 0.
//
// With i32 times the arithmetic is exact (see math.odin).
key_value :: proc "contextless" (
	keys: []Key($Time),
	t: Time,
	rate: f64 = 1,
	pre: Extrapolation = .Constant,
	post: Extrapolation = .Constant,
	hint: ^int = nil,
) -> f32 {
	n := len(keys)
	if n == 0 {
		return 0
	}
	if t >= keys[0].time && t <= keys[n - 1].time {
		return key_inside(keys, t, rate, hint)
	}
	before := t < keys[0].time
	if (pre if before else post) == .Linear && n > 1 {
		return f32(key_extend(keys, t, rate, before))
	}
	local, cycles := key_wrap(keys, t, pre, post)
	return key_offset(keys, key_inside(keys, local, rate, hint), cycles)
}

// key_step is a curve's value at a time as if every key were constant: the value of the last key at or before the
// time, or of the first key before it. Values that cannot fall between two keys, such as integers, bools and enums,
// step. pre and post are as for key_value, except that linear holds, since a step has no slope.
key_step :: proc "contextless" (
	keys: []Key($Time),
	t: Time,
	pre: Extrapolation = .Constant,
	post: Extrapolation = .Constant,
	hint: ^int = nil,
) -> f32 {
	n := len(keys)
	if n == 0 {
		return 0
	}
	if t >= keys[0].time && t <= keys[n - 1].time {
		return key_step_inside(keys, t, hint)
	}
	local, cycles := key_wrap(keys, t, pre, post)
	return key_offset(keys, key_step_inside(keys, local, hint), cycles)
}

// key_wrap maps a time outside a curve's keys to the time inside them that gives its value, by the mode of its side:
// pre before the first key, post after the last. Constant and linear hold the end key's time; key_value extends a
// linear side itself. Cycle repeats the keys' span, first key to last, and oscillate repeats it forward and then
// backward in turn. cycles is how many spans a cycle-with-offset side moves the value by, negative before the first key,
// and 0 for every other mode. A curve whose keys span no time holds. With i32 times the arithmetic is on whole ticks, so
// the time inside is exact; with f32 times it is floored f64, which can land on the last key's time at a repeat's edge.
key_wrap :: proc "contextless" (
	keys: []Key($Time),
	t: Time,
	pre, post: Extrapolation,
) -> (
	local: Time,
	cycles: i64,
) {
	first, last := keys[0].time, keys[len(keys) - 1].time
	if t >= first && t <= last {
		return t, 0
	}
	mode := pre if t < first else post
	when intrinsics.type_is_integer(Time) {
		span := i64(last) - i64(first)
		if span == 0 || mode == .Constant || mode == .Linear {
			return clamp(t, first, last), 0
		}
		r, whole := floor_wrap(i64(t) - i64(first), span)
		switch mode {
		case .Constant, .Linear:
		case .Cycle:
			return first + Time(r), 0
		case .Cycle_Offset:
			return first + Time(r), whole
		case .Oscillate:
			if whole % 2 != 0 {
				return first + Time(span - r), 0
			}
			return first + Time(r), 0
		}
	} else {
		span := f64(last) - f64(first)
		if span <= 0 || mode == .Constant || mode == .Linear {
			return clamp(t, first, last), 0
		}
		d := f64(t) - f64(first)
		whole := math.floor(d / span)
		r := clamp(d - whole * span, 0, span)
		switch mode {
		case .Constant, .Linear:
		case .Cycle:
			return clamp(first + Time(r), first, last), 0
		case .Cycle_Offset:
			return clamp(first + Time(r), first, last), i64(whole)
		case .Oscillate:
			if i64(whole) % 2 != 0 {
				return clamp(first + Time(span - r), first, last), 0
			}
			return clamp(first + Time(r), first, last), 0
		}
	}
	return clamp(t, first, last), 0
}

// key_segment is the index i of the segment that holds a time: keys[i].time <= t < keys[i + 1].time. The time is
// after the first key and before the last. It tries the hint and the segment after it, and else searches by halves.
key_segment :: proc "contextless" (keys: []Key($Time), t: Time, hint: ^int = nil) -> int {
	n := len(keys)
	holds :: proc "contextless" (keys: []Key($Time), i: int, t: Time) -> bool {
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

// find_segment is key_segment over plain times in rising order, such as an animation channel's: the index i with
// times[i] <= t < times[i + 1], and u, how far t is from times[i] to times[i + 1], from 0 to 1. Before the first time it
// is 0 and 0, and at or after the last it is the last segment and 1. There are at least two times.
find_segment :: proc "contextless" (
	times: []$F,
	t: F,
	hint: ^int = nil,
) -> (
	i: int,
	u: F,
) where intrinsics.type_is_float(F) {
	n := len(times)
	if t <= times[0] {
		return 0, 0
	}
	if t >= times[n - 1] {
		return n - 2, 1
	}
	holds :: proc "contextless" (times: []$F, i: int, t: F) -> bool {
		return i >= 0 && i + 1 < len(times) && times[i] <= t && t < times[i + 1]
	}
	found := false
	if hint != nil {
		if holds(times, hint^, t) {
			i, found = hint^, true
		} else if holds(times, hint^ + 1, t) {
			i, found = hint^ + 1, true
		}
	}
	if !found {
		lo, hi := 0, n - 1
		for hi - lo > 1 {
			mid := lo + (hi - lo) / 2
			if times[mid] <= t {
				lo = mid
			} else {
				hi = mid
			}
		}
		i = lo
	}
	if hint != nil {
		hint^ = i
	}
	return i, (t - times[i]) / (times[i + 1] - times[i])
}

// key_out_slope is the slope that leaves a key, in value per second: a Bezier key's own, and the automatic one for
// every other key.
key_out_slope :: proc "contextless" (keys: []Key($Time), i: int, rate: f64 = 1) -> f64 {
	if keys[i].interp == .Bezier {
		return f64(keys[i].out_slope)
	}
	return key_auto_slope(keys, i, rate)
}

// key_in_slope is the slope that reaches a key, in value per second: a Bezier key's own, and the automatic one for
// every other key.
key_in_slope :: proc "contextless" (keys: []Key($Time), i: int, rate: f64 = 1) -> f64 {
	if keys[i].interp == .Bezier {
		return f64(keys[i].in_slope)
	}
	return key_auto_slope(keys, i, rate)
}

// key_auto_slope is an automatic key's slope, in value per second (see auto_slope). The first and the last key are
// flat.
key_auto_slope :: proc "contextless" (keys: []Key($Time), i: int, rate: f64 = 1) -> f64 {
	if i <= 0 || i >= len(keys) - 1 {
		return 0
	}
	a, k, b := keys[i - 1], keys[i], keys[i + 1]
	return auto_slope(
		f64(a.value),
		f64(k.value),
		f64(b.value),
		f64(k.time - a.time) / rate,
		f64(b.time - k.time) / rate,
		f64(b.time - a.time) / rate,
	)
}

// key_segment_value is the value of the Bezier or automatic segment from keys[i] to keys[i + 1] at s, the part of the
// segment's duration from 0 to 1. Without weights, it is a cubic Hermite curve. With weights, it solves the handles'
// time for s by halves.
key_segment_value :: proc "contextless" (
	keys: []Key($Time),
	i: int,
	s: f64,
	rate: f64 = 1,
) -> f64 {
	k0, k1 := keys[i], keys[i + 1]
	duration := f64(k1.time - k0.time) / rate
	v0, v1 := f64(k0.value), f64(k1.value)
	// The tangents as changes of value over the whole segment.
	m0 := key_out_slope(keys, i, rate) * duration
	m1 := key_in_slope(keys, i + 1, rate) * duration
	w0, w1, weighted := key_weights(k0, k1)
	if !weighted {
		return hermite(v0, m0, v1, m1, s)
	}
	return weighted_segment(v0, m0, w0, v1, m1, w1, s)
}

// key_weights is the handles' weights of the segment from k0 to k1, and whether either key gives its own.
@(private)
key_weights :: proc "contextless" (k0, k1: Key($Time)) -> (w0, w1: f64, weighted: bool) {
	w0, w1 = f64(KEY_TANGENT_WEIGHT), f64(KEY_TANGENT_WEIGHT)
	if k0.interp == .Bezier && .Weighted in k0.flags {
		w0, weighted = f64(k0.out_weight), true
	}
	if k1.interp == .Bezier && .Weighted in k1.flags {
		w1, weighted = f64(k1.in_weight), true
	}
	return
}

// key_offset is a value inside a curve moved by cycles times the change from its first key's value to its last's.
@(private)
key_offset :: proc "contextless" (keys: []Key($Time), v: f32, cycles: i64) -> f32 {
	if cycles == 0 {
		return v
	}
	return f32(f64(v) + f64(cycles) * (f64(keys[len(keys) - 1].value) - f64(keys[0].value)))
}

// key_extend is a linear side's value: the end key's value, then on along the slope that the curve has at that key,
// from its end segment. A constant segment's slope is 0, a linear one's is its own, and a Bezier or automatic one's is
// its tangent's. The curve has at least two keys.
@(private)
key_extend :: proc "contextless" (keys: []Key($Time), t: Time, rate: f64, before: bool) -> f64 {
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
			(f64(keys[b].value) - f64(keys[a].value)) / (f64(keys[b].time - keys[a].time) / rate)
	case .Bezier, .Auto:
		slope = key_out_slope(keys, 0, rate) if before else key_in_slope(keys, n - 1, rate)
	}
	when intrinsics.type_is_integer(Time) {
		elapsed := f64(i64(t) - i64(keys[end].time))
	} else {
		elapsed := f64(t) - f64(keys[end].time)
	}
	return f64(keys[end].value) + slope * (elapsed / rate)
}

// key_inside is key_value at a time from the first key's to the last's.
@(private)
key_inside :: proc "contextless" (keys: []Key($Time), t: Time, rate: f64, hint: ^int) -> f32 {
	n := len(keys)
	if t <= keys[0].time {
		return keys[0].value
	}
	if t >= keys[n - 1].time {
		return keys[n - 1].value
	}
	i := key_segment(keys, t, hint)
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
		return f32(key_segment_value(keys, i, s, rate))
	}
	return k0.value
}

// key_step_inside is key_step at a time from the first key's to the last's.
@(private)
key_step_inside :: proc "contextless" (keys: []Key($Time), t: Time, hint: ^int) -> f32 {
	n := len(keys)
	if t <= keys[0].time {
		return keys[0].value
	}
	if t >= keys[n - 1].time {
		return keys[n - 1].value
	}
	return keys[key_segment(keys, t, hint)].value
}

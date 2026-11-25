package core_math

import "core:math"

// Linear_Key is a key of a curve that goes straight from key to key: a value of any float or array of floats, such as a
// color, at a part t of a span, such as a particle's life from 0 to 1. A gradient, or a curve that a shader samples
// from a baked row, is a run of them in rising t.
Linear_Key :: struct($T: typeid) {
	t:     f32,
	value: T,
}

// linear_value is the value of linear keys at t: a line between the two keys around t, and the end key's value past
// either end. At a key's t, it is that key's value. The keys are in rising t, and there is at least one.
linear_value :: proc "contextless" (keys: []Linear_Key($T), t: f32) -> T {
	n := len(keys)
	if t <= keys[0].t {
		return keys[0].value
	}
	if t >= keys[n - 1].t {
		return keys[n - 1].value
	}
	// The first key at or after t: keys[lo].t < t <= keys[hi].t.
	lo, hi := 0, n - 1
	for hi - lo > 1 {
		mid := lo + (hi - lo) / 2
		if t <= keys[mid].t {
			hi = mid
		} else {
			lo = mid
		}
	}
	a, b := keys[lo], keys[hi]
	return math.lerp(a.value, b.value, (t - a.t) / (b.t - a.t))
}

// linear_bake samples linear keys at len(out) evenly spaced parts from 0 to 1, both ends included, for a row that a
// shader reads. Without keys, every sample is fallback.
linear_bake :: proc "contextless" (keys: []Linear_Key($T), out: []T, fallback: T) {
	n := len(out)
	for &sample, i in out {
		if len(keys) == 0 {
			sample = fallback
			continue
		}
		t := f32(i) / f32(n - 1) if n > 1 else 0
		sample = linear_value(keys, t)
	}
}

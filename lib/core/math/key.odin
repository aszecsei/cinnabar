package core_math

// A keyed curve is keys in rising time, each with a value and an interpolation to the next key (see
// docs/core/math.md#keyed-curves). Time is i32, whole ticks of a rate the caller gives, which wrap exactly and are the
// format of a cutscene's channels; or f32, seconds or a part from 0 to 1, for curves that game code builds.
//
// These types are a binary format: format.Cutscene_Key is Key(i32), and the editor mirrors the enums by value. Append
// to an enum; never reorder, rename or remove a member, or change Key's fields.

// KEY_TANGENT_WEIGHT is the weight of a tangent of a key that is not weighted: a third of the segment, which makes a
// Bezier segment a cubic Hermite curve, whose time is linear in its parameter.
KEY_TANGENT_WEIGHT :: 1.0 / 3.0

// Interp is how a curve goes from a key to the next.
Interp :: enum u8 {
	// The key's value holds until the next key.
	Constant,
	Linear,
	// A Bezier curve from the key's out tangent to the next key's in tangent, each a slope and a weight.
	Bezier,
	// A Bezier curve whose tangents the evaluator computes from the keys' neighbours, so it does not overshoot.
	Auto,
}

Key_Flag :: enum u8 {
	// The in and out tangents are set apart. Without it they are one, and an editor moves them together. The value does
	// not read it.
	Broken,
	// The tangents have their own weights. Without it both are KEY_TANGENT_WEIGHT.
	Weighted,
	// The value jumps at the key: a consumer that keeps state across evaluations, such as a pose's history, does not
	// interpolate across it. The value does not read it.
	Teleport,
}
Key_Flags :: bit_set[Key_Flag;u8]

// Extrapolation is what a curve does before its first key or after its last.
Extrapolation :: enum u8 {
	// It holds the end key's value.
	Constant,
	// It goes on along the slope that the curve has at its end key.
	Linear,
	// It repeats the keys, from the first's time to the last's.
	Cycle,
	// It repeats the keys, each repeat moved by the change from the first key's value to the last's.
	Cycle_Offset,
	// It repeats the keys forward, then backward, in turn.
	Oscillate,
}

// Key is a key of a curve. Only a Bezier key has tangents of its own: slopes in value per second (see key_value's
// rate), and, when it is weighted, weights, the part of the segment's duration that each handle reaches, from 0 to 1.
// Other keys have zeros there, and a key that is not weighted has tangents of KEY_TANGENT_WEIGHT.
Key :: struct($Time: typeid) where Time == i32 || Time == f32 {
	time:       Time,
	value:      f32,
	interp:     Interp,
	flags:      Key_Flags,
	reserved:   u16,
	in_slope:   f32,
	in_weight:  f32,
	out_slope:  f32,
	out_weight: f32,
}
#assert(size_of(Key(i32)) == 28 && size_of(Key(f32)) == 28)

// key_constant is a key whose value holds until the next key.
key_constant :: proc "contextless" (time: $Time, value: f32) -> Key(Time) {
	return {time = time, value = value, interp = .Constant}
}

// key_linear is a key with a straight line to the next key.
key_linear :: proc "contextless" (time: $Time, value: f32) -> Key(Time) {
	return {time = time, value = value, interp = .Linear}
}

// key_auto is a key whose tangents the evaluator computes, so the curve through it does not overshoot.
key_auto :: proc "contextless" (time: $Time, value: f32) -> Key(Time) {
	return {time = time, value = value, interp = .Auto}
}

// key_bezier is a key with its own slopes, in value per second, broken when they differ.
key_bezier :: proc "contextless" (time: $Time, value, in_slope, out_slope: f32) -> Key(Time) {
	k := Key(Time) {
		time      = time,
		value     = value,
		interp    = .Bezier,
		in_slope  = in_slope,
		out_slope = out_slope,
	}
	if in_slope != out_slope {
		k.flags += {.Broken}
	}
	return k
}

// key_weighted is a key with its own slopes and weights, broken when the slopes differ.
key_weighted :: proc "contextless" (
	time: $Time,
	value, in_slope, out_slope, in_weight, out_weight: f32,
) -> Key(Time) {
	k := key_bezier(time, value, in_slope, out_slope)
	k.flags += {.Weighted}
	k.in_weight, k.out_weight = in_weight, out_weight
	return k
}

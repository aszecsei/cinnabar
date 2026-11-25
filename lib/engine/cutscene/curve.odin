package cutscene

import core_math "cinnabar:core/math"
import format "cinnabar:engine/asset/format"

// A channel's curve is a keyed curve of core_math with times in ticks (see docs/cinematics/tracks.md#curves and
// docs/core/math.md#keyed-curves). These are its evaluations at a channel's rate.

@(private = "file")
TICKS :: f64(format.CUTSCENE_TICKS_PER_SECOND)

// curve_value is a channel's value at a tick on its section's time, with its pre and post infinity: core_math.key_value.
curve_value :: proc "contextless" (
	keys: []format.Cutscene_Key,
	t: i32,
	pre, post: format.Cutscene_Infinity,
	hint: ^int = nil,
) -> f32 {
	return core_math.key_value(keys, t, TICKS, pre, post, hint)
}

// curve_step is a channel's value at a tick as if every key were constant, for fields that cannot take a value between
// two keys, such as integers, bools, enums and assets: core_math.key_step.
curve_step :: proc "contextless" (
	keys: []format.Cutscene_Key,
	t: i32,
	pre, post: format.Cutscene_Infinity,
	hint: ^int = nil,
) -> f32 {
	return core_math.key_step(keys, t, pre, post, hint)
}

// curve_integral is the integral of a pitch curve from 0 to a time in ticks, which can fall between two, in value ×
// seconds: an audio section's place in its sound (see docs/cinematics/tracks.md#audio-tracks). The pitch is what a voice
// plays, CUTSCENE_MIN_PITCH to CUTSCENE_MAX_PITCH, so a segment that leaves that range integrates the clamped curve.
curve_integral :: proc "contextless" (keys: []format.Cutscene_Key, t: f64) -> f64 {
	return core_math.key_integral(
		keys,
		t,
		TICKS,
		format.CUTSCENE_MIN_PITCH,
		format.CUTSCENE_MAX_PITCH,
	)
}

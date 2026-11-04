package audio

import "core:math"

import "cinnabar:core"

TONE_FREQUENCY :: 440
// About -26 dB, so a test does not startle anyone in headphones.
TONE_GAIN :: 0.05
// How much audio the tone keeps queued: 250 ms. The game cannot write while its frames stop, so this must outlast a code
// reload, about 17 ms in mygame, and the stalls of its first frames, which starve a queue of 100 ms.
TONE_LEAD :: core.AUDIO_SAMPLE_RATE / 4

// Tone is a sine that a game plays through the device, panned by a pose that it presents. It lives in Game_State, so a
// code reload continues it from the same phase.
Tone :: struct {
	// Where the sine is, in cycles.
	phase: f64,
	// The pan at the end of what was queued, from -1, left, to 1, right.
	pan:   f32,
}

// tone_update tops the queue up to TONE_LEAD, with the pan moving from the last call's to this one's. Call it once per
// frame, after the world's Late stage, as render extraction runs.
tone_update :: proc(tone: ^Tone, platform: ^core.Platform_API, pan: f32) {
	count := TONE_LEAD - platform.audio_status().queued
	if count <= 0 {
		return
	}
	frames := make([]core.Audio_Frame, count, platform.frame_allocator)
	tone_render(tone^, pan, frames)
	tone_advance(tone, pan, count, platform.audio_write(frames))
}

// tone_render writes the sine into frames, panned with equal power, so moving does not change the loudness.
tone_render :: proc(tone: Tone, pan: f32, frames: []core.Audio_Frame) {
	for &frame, i in frames {
		t := tone_ramp(i + 1, len(frames))
		left, right := tone_gains(math.lerp(tone.pan, pan, t))
		phase := tone.phase + f64(i) * TONE_FREQUENCY / core.AUDIO_SAMPLE_RATE
		sample := f32(math.sin(phase * math.TAU)) * TONE_GAIN
		frame = {sample * left, sample * right}
	}
}

// tone_advance moves the tone past the frames that the device took, of those that tone_render wrote, so what did not
// fit plays next.
tone_advance :: proc(tone: ^Tone, pan: f32, rendered, written: int) {
	tone.phase = math.mod(tone.phase + f64(written) * TONE_FREQUENCY / core.AUDIO_SAMPLE_RATE, 1)
	tone.pan = math.lerp(tone.pan, pan, tone_ramp(written, rendered))
}

@(private = "file")
tone_ramp :: proc(done, total: int) -> f32 {
	return f32(done) / f32(total)
}

@(private = "file")
tone_gains :: proc(pan: f32) -> (left, right: f32) {
	angle := (clamp(pan, -1, 1) + 1) * math.PI / 4
	return math.cos(angle), math.sin(angle)
}

package audio

import "core:math"
import "core:mem/virtual"
import "core:testing"

import "cinnabar:core"

// What the fake device holds for the running test.
@(private = "file", thread_local)
queued: int
@(private = "file", thread_local)
room: int
@(private = "file", thread_local)
last_written: []core.Audio_Frame

@(private = "file")
fake_platform :: proc(arena: ^virtual.Arena) -> core.Platform_API {
	return {
		frame_allocator = virtual.arena_allocator(arena),
		audio_status = proc() -> core.Audio_Status {
			return {queued = queued}
		},
		audio_write = proc(frames: []core.Audio_Frame) -> int {
			count := min(len(frames), room)
			last_written = frames[:count]
			queued += count
			room -= count
			return count
		},
	}
}

@(test)
tone_update_tops_the_queue_up_to_its_lead :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := fake_platform(&arena)
	queued, room = 0, 1 << 20

	tone: Tone
	tone_update(&tone, &platform, 0)
	testing.expect_value(t, queued, TONE_LEAD)

	// A full queue takes nothing, and the tone stays where it is.
	phase := tone.phase
	last_written = nil
	tone_update(&tone, &platform, 1)
	testing.expect_value(t, len(last_written), 0)
	testing.expect_value(t, tone.phase, phase)

	queued -= 100
	tone_update(&tone, &platform, 1)
	testing.expect_value(t, len(last_written), 100)
	testing.expect_value(t, queued, TONE_LEAD)
}

@(test)
tone_continues_its_phase_across_calls :: proc(t: ^testing.T) {
	whole: [1000]core.Audio_Frame
	tone_render({}, 0, whole[:])

	tone: Tone
	first := whole[:300]
	second: [700]core.Audio_Frame
	tone_render(tone, 0, first)
	tone_advance(&tone, 0, len(first), len(first))
	tone_render(tone, 0, second[:])
	for frame, i in second {
		testing.expectf(t, math.abs(frame.x - whole[300 + i].x) < 1e-4, "frame %d: %v against %v", i, frame.x, whole[300 + i].x)
	}
}

@(test)
tone_repeats_what_the_device_did_not_take :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	platform := fake_platform(&arena)
	queued, room = 0, 300

	tone: Tone
	tone_update(&tone, &platform, 1)
	testing.expect_value(t, queued, 300)
	expected: Tone
	tone_advance(&expected, 1, TONE_LEAD, 300)
	testing.expect_value(t, tone.phase, expected.phase)
	testing.expect_value(t, tone.pan, expected.pan)
	testing.expect(t, tone.pan > 0 && tone.pan < 1, "the pan stops partway, at what was written")
}

@(test)
tone_pans_with_equal_power :: proc(t: ^testing.T) {
	peak :: proc(frames: []core.Audio_Frame) -> (peak: [2]f32) {
		for frame in frames {
			peak = {max(peak.x, math.abs(frame.x)), max(peak.y, math.abs(frame.y))}
		}
		return
	}
	frames: [200]core.Audio_Frame

	tone_render({pan = -1}, -1, frames[:])
	left := peak(frames[:])
	testing.expect(t, math.abs(left.x - TONE_GAIN) < 1e-3, "full left has the whole gain on the left")
	testing.expect(t, left.y < 1e-6, "and nothing on the right")

	tone_render({pan = 1}, 1, frames[:])
	right := peak(frames[:])
	testing.expect(t, right.x < 1e-6, "full right has nothing on the left")
	testing.expect(t, math.abs(right.y - TONE_GAIN) < 1e-3, "and the whole gain on the right")

	tone_render({}, 0, frames[:])
	center := peak(frames[:])
	testing.expect(t, math.abs(center.x - center.y) < 1e-6, "the center is even")
	power := center.x * center.x + center.y * center.y
	testing.expect(t, math.abs(power - TONE_GAIN * TONE_GAIN) < 1e-5, "and has the same power")
}

@(test)
tone_ramps_its_pan_over_a_block :: proc(t: ^testing.T) {
	frames: [4800]core.Audio_Frame
	tone_render({pan = -1}, 1, frames[:])
	start, end: [2]f32
	for frame, i in frames {
		if i < 240 {
			start = {max(start.x, math.abs(frame.x)), max(start.y, math.abs(frame.y))}
		} else if i >= len(frames) - 240 {
			end = {max(end.x, math.abs(frame.x)), max(end.y, math.abs(frame.y))}
		}
	}
	testing.expect(t, start.x > start.y * 5, "the block starts on the left")
	testing.expect(t, end.y > end.x * 5, "and ends on the right")
}

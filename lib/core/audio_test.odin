package core

import "core:slice"
import "core:testing"
import "core:thread"

@(private = "file")
tone_frames :: proc(frames: []Audio_Frame, first: int) {
	for &frame, i in frames {
		frame = {f32(first + i), -f32(first + i)}
	}
}

@(test)
audio_ring_keeps_frames_in_order_across_its_end :: proc(t: ^testing.T) {
	storage: [8]Audio_Frame
	ring := Audio_Ring {
		frames = storage[:],
	}
	in_frames: [6]Audio_Frame
	out_frames: [6]Audio_Frame
	next := 0
	// The third round wraps.
	for _ in 0 ..< 3 {
		tone_frames(in_frames[:], next)
		testing.expect_value(t, audio_ring_write(&ring, in_frames[:]), 6)
		testing.expect_value(t, audio_ring_queued(&ring), 6)
		testing.expect_value(t, audio_ring_read(&ring, out_frames[:]), 6)
		testing.expect(t, slice.equal(in_frames[:], out_frames[:]))
		next += 6
	}
	testing.expect_value(t, audio_ring_queued(&ring), 0)
}

@(test)
audio_ring_write_stops_when_full :: proc(t: ^testing.T) {
	storage: [4]Audio_Frame
	ring := Audio_Ring {
		frames = storage[:],
	}
	frames: [6]Audio_Frame
	tone_frames(frames[:], 0)
	testing.expect_value(t, audio_ring_write(&ring, frames[:]), 4)
	testing.expect_value(t, audio_ring_write(&ring, frames[:]), 0)
	out: [6]Audio_Frame
	testing.expect_value(t, audio_ring_read(&ring, out[:]), 4)
	testing.expect(t, slice.equal(frames[:4], out[:4]))
	testing.expect_value(t, audio_ring_read(&ring, out[:]), 0)
}

@(test)
audio_ring_skip_stops_at_what_is_queued :: proc(t: ^testing.T) {
	storage: [4]Audio_Frame
	ring := Audio_Ring {
		frames = storage[:],
	}
	frames: [3]Audio_Frame
	tone_frames(frames[:], 0)
	audio_ring_write(&ring, frames[:])
	testing.expect_value(t, audio_ring_skip(&ring, 2), 2)
	out: [3]Audio_Frame
	testing.expect_value(t, audio_ring_read(&ring, out[:]), 1)
	testing.expect_value(t, out[0], frames[2])
	testing.expect_value(t, audio_ring_skip(&ring, 2), 0)
}

@(test)
audio_ring_carries_every_frame_between_two_threads :: proc(t: ^testing.T) {
	TOTAL :: 1_000_000
	storage: [64]Audio_Frame
	ring := Audio_Ring {
		frames = storage[:],
	}
	writer := thread.create_and_start_with_data(&ring, proc(data: rawptr) {
		ring := (^Audio_Ring)(data)
		block: [17]Audio_Frame
		next := 0
		for next < TOTAL {
			count := min(len(block), TOTAL - next)
			tone_frames(block[:count], next)
			sent := audio_ring_write(ring, block[:count])
			// What did not fit is generated again, from the same place.
			next += sent
		}
	})
	defer thread.destroy(writer)
	received := 0
	in_order := true
	for received < TOTAL {
		block: [23]Audio_Frame
		count := audio_ring_read(&ring, block[:])
		for frame, i in block[:count] {
			in_order &&= frame.x == f32(received + i)
		}
		received += count
	}
	thread.join(writer)
	testing.expect(t, in_order, "the frames arrive in order")
	testing.expect_value(t, audio_ring_queued(&ring), 0)
}

@(test)
audio_device_fills_with_silence_and_counts_it_only_after_the_first_frame :: proc(t: ^testing.T) {
	storage: [8]Audio_Frame
	device := Audio_Device {
		ring = {frames = storage[:]},
	}
	out: [4]Audio_Frame
	slice.fill(out[:], Audio_Frame{9, 9})
	// Before any frame, silence is not starving.
	audio_device_take(&device, out[:])
	testing.expect_value(t, device.played, 0)
	testing.expect_value(t, device.starved, 0)
	testing.expect_value(t, out[0], Audio_Frame{})

	frames: [2]Audio_Frame
	tone_frames(frames[:], 1)
	audio_ring_write(&device.ring, frames[:])
	slice.fill(out[:], Audio_Frame{9, 9})
	audio_device_take(&device, out[:])
	testing.expect_value(t, device.played, 2)
	testing.expect_value(t, device.starved, 2)
	testing.expect_value(t, out[1], frames[1])
	testing.expect_value(t, out[2], Audio_Frame{})
	testing.expect_value(t, out[3], Audio_Frame{})
}

@(test)
audio_device_skip_counts_what_it_drains :: proc(t: ^testing.T) {
	storage: [8]Audio_Frame
	device := Audio_Device {
		ring = {frames = storage[:]},
	}
	frames: [3]Audio_Frame
	audio_ring_write(&device.ring, frames[:])
	audio_device_skip(&device, 100)
	testing.expect_value(t, device.played, 3)
	testing.expect_value(t, audio_ring_queued(&device.ring), 0)
}

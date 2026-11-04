package core

import "base:runtime"
import "core:log"
import "core:slice"
import "core:sync"
import "core:thread"

// The device's one format, whatever the endpoint's is: 48 kHz stereo, 32-bit float (see docs/core/audio.md#format).
AUDIO_SAMPLE_RATE :: 48000
Audio_Frame :: [2]f32

// The most audio that a writer can queue, about 2.7 seconds. A power of two, so an index wraps with a mask.
AUDIO_RING_FRAMES :: 1 << 17

// Audio_Status is what audio_status gives a writer (see docs/core/audio.md#status).
Audio_Status :: struct {
	// Frames written that the device has not taken.
	queued:  int,
	// Frames that the device has taken since the first write.
	played:  u64,
	// Frames of silence that the device took after the first frame, because the queue was empty.
	starved: u64,
	// Whether a device is open. Without one, the queue still drains at the sample rate.
	open:    bool,
}

@(private)
Audio_Index :: struct #align (64) {
	value: u64,
}

// Audio_Ring is the queue between one writer and the device thread. The indices only grow, and read <= write.
@(private)
Audio_Ring :: struct {
	frames: []Audio_Frame,
	read:   Audio_Index,
	write:  Audio_Index,
}

@(private)
Audio_Device :: struct {
	ring:           Audio_Ring,
	played:         u64,
	starved:        u64,
	open:           bool,
	closing:        bool,
	// The writer's: whether its first write has started the thread.
	started:        bool,
	thread:         ^thread.Thread,
	// The host's. A write can come from the game, whose context holds procedures in its DLL.
	thread_context: runtime.Context,
}

@(private)
audio_ring_queued :: proc(ring: ^Audio_Ring) -> int {
	return int(sync.atomic_load_explicit(&ring.write.value, .Acquire) - sync.atomic_load_explicit(&ring.read.value, .Acquire))
}

// audio_ring_write copies as many frames as fit and returns how many. It is the writer's side.
@(private)
audio_ring_write :: proc(ring: ^Audio_Ring, frames: []Audio_Frame) -> int {
	write := sync.atomic_load_explicit(&ring.write.value, .Relaxed)
	read := sync.atomic_load_explicit(&ring.read.value, .Acquire)
	count := min(len(frames), len(ring.frames) - int(write - read))
	start := int(write) & (len(ring.frames) - 1)
	first := copy(ring.frames[start:], frames[:count])
	copy(ring.frames, frames[first:count])
	sync.atomic_store_explicit(&ring.write.value, write + u64(count), .Release)
	return count
}

// audio_ring_read copies as many queued frames as out holds and returns how many. It is the device thread's side.
@(private)
audio_ring_read :: proc(ring: ^Audio_Ring, out: []Audio_Frame) -> int {
	read := sync.atomic_load_explicit(&ring.read.value, .Relaxed)
	write := sync.atomic_load_explicit(&ring.write.value, .Acquire)
	count := min(len(out), int(write - read))
	start := int(read) & (len(ring.frames) - 1)
	first := copy(out[:count], ring.frames[start:])
	copy(out[first:count], ring.frames)
	sync.atomic_store_explicit(&ring.read.value, read + u64(count), .Release)
	return count
}

// audio_ring_skip drops up to count queued frames and returns how many. It is the device thread's side.
@(private)
audio_ring_skip :: proc(ring: ^Audio_Ring, count: int) -> int {
	read := sync.atomic_load_explicit(&ring.read.value, .Relaxed)
	write := sync.atomic_load_explicit(&ring.write.value, .Acquire)
	skipped := min(count, int(write - read))
	sync.atomic_store_explicit(&ring.read.value, read + u64(skipped), .Release)
	return skipped
}

// audio_device_take fills out for the endpoint: the queue's frames, then silence.
@(private)
audio_device_take :: proc(device: ^Audio_Device, out: []Audio_Frame) {
	count := audio_ring_read(&device.ring, out)
	slice.zero(out[count:])
	played := sync.atomic_add_explicit(&device.played, u64(count), .Relaxed) + u64(count)
	if played > 0 {
		sync.atomic_add_explicit(&device.starved, u64(len(out) - count), .Relaxed)
	}
}

// audio_device_skip drains the queue while no endpoint takes it, so that a writer keeps its pace.
@(private)
audio_device_skip :: proc(device: ^Audio_Device, count: int) {
	sync.atomic_add_explicit(&device.played, u64(audio_ring_skip(&device.ring, count)), .Relaxed)
}

// audio_init allocates the queue from the heap, not the permanent arena, which a soft restart frees.
@(private)
audio_init :: proc(device: ^Audio_Device) {
	device.ring.frames = make([]Audio_Frame, AUDIO_RING_FRAMES, runtime.heap_allocator())
	device.thread_context = context
}

@(private)
audio_shutdown :: proc(device: ^Audio_Device) {
	if device.started {
		sync.atomic_store_explicit(&device.closing, true, .Release)
		thread.join(device.thread)
		thread.destroy(device.thread)
		log.infof("core: audio played %d frames and starved for %d", device.played, device.starved)
	}
	delete(device.ring.frames, runtime.heap_allocator())
}

// audio_write is Platform_API's. The first frames start the device thread, so a game without sound opens no stream.
@(private)
audio_write :: proc(frames: []Audio_Frame) -> int {
	device := &platform.audio
	if len(frames) == 0 {
		return 0
	}
	count := audio_ring_write(&device.ring, frames)
	if !device.started {
		device.started = true
		context = device.thread_context
		device.thread = thread.create_and_start_with_data(device, _audio_thread, device.thread_context, .High, name = "audio")
	}
	return count
}

@(private)
audio_status :: proc() -> Audio_Status {
	device := &platform.audio
	return {
		queued = audio_ring_queued(&device.ring),
		played = sync.atomic_load_explicit(&device.played, .Relaxed),
		starved = sync.atomic_load_explicit(&device.starved, .Relaxed),
		open = sync.atomic_load_explicit(&device.open, .Relaxed),
	}
}

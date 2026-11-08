package core

import "base:runtime"
import "core:log"
import "core:slice"
import "core:sync"
import "core:thread"

import audio "cinnabar:core/audio"

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

// Audio_Writer is who writes to the device: the game, through Platform_API.audio_write, or the audio backend's mixer
// thread, through audio_device_write. The queue takes one producer, so the first write claims the device for its writer
// for good, and the other writer is refused.
Audio_Writer :: enum u32 {
	None,
	Game,
	Backend,
}

@(private)
Audio_Device :: struct {
	ring:           Audio_Ring,
	played:         u64,
	starved:        u64,
	open:           bool,
	closing:        bool,
	// Who writes, which the first write claims (see audio_claim_writer). The device thread starts with the claim.
	writer:         Audio_Writer,
	// Whether a write from the other writer was refused and logged, so that it logs once.
	refused:        bool,
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
	if sync.atomic_load(&device.writer) != .None {
		sync.atomic_store_explicit(&device.closing, true, .Release)
		thread.join(device.thread)
		thread.destroy(device.thread)
		log.infof("core: audio played %d frames and starved for %d", device.played, device.starved)
	}
	delete(device.ring.frames, runtime.heap_allocator())
}

// audio_claim_writer claims the device for who, once: ok is true for the writer that holds it, and first for the write
// that claimed it, which starts the device thread. The other writer is refused, and the first refusal logs an error.
@(private)
audio_claim_writer :: proc(device: ^Audio_Device, who: Audio_Writer) -> (ok: bool, first: bool) {
	assert(who != .None)
	writer, claimed := sync.atomic_compare_exchange_strong(&device.writer, Audio_Writer.None, who)
	if claimed {
		return true, true
	}
	if writer == who {
		return true, false
	}
	if !sync.atomic_exchange(&device.refused, true) {
		log.errorf("core: the audio device takes frames from one writer, the %v, so the %v's are dropped", writer, who)
	}
	return false, false
}

// audio_write_as queues frames from who, when the device is its. The first frames start the device thread, so a game
// without sound opens no stream.
@(private)
audio_write_as :: proc(device: ^Audio_Device, who: Audio_Writer, frames: []Audio_Frame) -> int {
	if len(frames) == 0 {
		return 0
	}
	ok, first := audio_claim_writer(device, who)
	if !ok {
		return 0
	}
	count := audio_ring_write(&device.ring, frames)
	if first {
		context = device.thread_context
		device.thread = thread.create_and_start_with_data(device, _audio_thread, device.thread_context, .High, name = "audio")
	}
	return count
}

// audio_write is Platform_API's, the game's writer.
@(private)
audio_write :: proc(frames: []Audio_Frame) -> int {
	return audio_write_as(&platform.audio, .Game, frames)
}

// audio_device_write and audio_device_status are the device as an audio backend sees it (see
// docs/audio/backends.md#the-contract).
@(private)
audio_device_write :: proc "c" (frames: [^]audio.Device_Frame, count: i32) -> i32 {
	context = platform.audio.thread_context
	return i32(audio_write_as(&platform.audio, .Backend, frames[:count]))
}

@(private)
audio_device_status :: proc "c" (out: ^audio.Device_Status) {
	context = platform.audio.thread_context
	status := audio_status()
	out^ = {
		queued  = i64(status.queued),
		played  = status.played,
		starved = status.starved,
		open    = b32(status.open),
	}
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

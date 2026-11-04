package audio_mixer

import "core:sync"

// Each stream's ring holds about 1.4 s, and its reader tops it up once a chunk's worth of room is free, about every
// 0.7 s. Powers of two, so an index wraps with a mask.
STREAM_RING_FRAMES :: 1 << 16
STREAM_CHUNK_FRAMES :: 1 << 15
// How often the stream thread looks at its streams, in milliseconds. A ring holds far longer.
@(private)
STREAM_WAIT_MS :: 20

// A stream goes Free to Active on the game's thread, Active to Closing on the mix thread, and Closing to Free on the
// stream thread, which is the last to touch its sound.
@(private)
Stream_State :: enum u32 {
	Free,
	Active,
	Closing,
}

// Stream is one playing voice's window on a file: the stream thread writes the ring, and the mix thread reads it.
@(private)
Stream :: struct {
	state:      Stream_State,
	sound:      ^Sound_Data,
	loop:       bool,
	// The stream thread's: the next frame of the file, and the file's time at the first read.
	next_frame: u64,
	modified:   i64,
	opened:     bool,
	// Interleaved like the sound.
	ring:       [^]i16,
	read:       Index,
	write:      Index,
	// Set after the last write: no more frames come.
	ended:      b32,
}

// stream_take gives a playing voice a free stream, or nil. The ring is allocated once, here on the game's thread.
@(private)
stream_take :: proc(m: ^Mixer, sound: ^Sound_Data, loop: bool) -> ^Stream {
	for &stream in m.streams {
		if sync.atomic_load_explicit(&stream.state, .Acquire) != .Free {
			continue
		}
		if stream.ring == nil {
			stream.ring = ([^]i16)(m.host.allocate(STREAM_RING_FRAMES * 2 * size_of(i16), align_of(i16)))
			if stream.ring == nil {
				return nil
			}
		}
		stream.sound = sound
		stream.loop = loop
		stream.next_frame = 0
		stream.opened = false
		stream.read.value = 0
		stream.write.value = 0
		stream.ended = false
		// A stream's voice holds its sound through the stream.
		sync.atomic_store_explicit(&stream.state, .Active, .Release)
		return &stream
	}
	return nil
}

@(private)
streams_busy :: proc(m: ^Mixer) -> bool {
	for &stream in m.streams {
		if sync.atomic_load_explicit(&stream.state, .Acquire) != .Free {
			return true
		}
	}
	return false
}

// stream_ready is whether a voice can start: its first read is done, so it does not start with a gap.
@(private)
stream_ready :: proc(stream: ^Stream) -> bool {
	ended := sync.atomic_load_explicit(&stream.ended, .Acquire)
	return bool(ended) || sync.atomic_load_explicit(&stream.write.value, .Acquire) > stream.read.value
}

// stream_read takes the next frame on the mix thread. ok is false past the end. A stream that the reader has not kept up
// with plays silence, which stats count.
@(private)
stream_read :: proc(m: ^Mixer, stream: ^Stream) -> (frame: [2]f32, ok: bool) {
	// Ended first: if it is set, the last write has been seen too.
	ended := sync.atomic_load_explicit(&stream.ended, .Acquire)
	read := stream.read.value
	if read == sync.atomic_load_explicit(&stream.write.value, .Acquire) {
		if ended {
			return {}, false
		}
		sync.atomic_add_explicit(&m.stream_starved, 1, .Relaxed)
		return {}, true
	}
	index := read & (STREAM_RING_FRAMES - 1)
	if stream.sound.channels == 1 {
		sample := f32(stream.ring[index]) / 32768
		frame = {sample, sample}
	} else {
		frame = {f32(stream.ring[index * 2]) / 32768, f32(stream.ring[index * 2 + 1]) / 32768}
	}
	sync.atomic_store_explicit(&stream.read.value, read + 1, .Release)
	return frame, true
}

// stream_fill reads frames to fill the ring's free space. It opens and closes the file each time, because Windows
// refuses the cooker's rename over a file that is open (see docs/audio/design.md#streaming).
@(private)
stream_fill :: proc(m: ^Mixer, stream: ^Stream) {
	if sync.atomic_load_explicit(&stream.ended, .Relaxed) {
		return
	}
	write := sync.atomic_load_explicit(&stream.write.value, .Relaxed)
	free := STREAM_RING_FRAMES - int(write - sync.atomic_load_explicit(&stream.read.value, .Acquire))
	if free < STREAM_CHUNK_FRAMES {
		return
	}
	sound := stream.sound
	file := m.host.file_open(sound.path)
	if file == nil {
		stream_fail(m, stream)
		return
	}
	defer m.host.file_close(file)
	modified := m.host.file_modified(file)
	if stream.opened && modified != stream.modified {
		// The cooker replaced it, and the new one may not line up with what has played. The game restarts the voice.
		sync.atomic_store_explicit(&stream.ended, true, .Release)
		return
	}
	stream.opened = true
	stream.modified = modified

	frame_size := u64(sound.channels) * size_of(i16)
	for free > 0 {
		if stream.next_frame >= sound.frames {
			if !stream.loop {
				sync.atomic_store_explicit(&stream.ended, true, .Release)
				return
			}
			stream.next_frame = 0
		}
		// Up to the end of the ring, and of the sound.
		start := int(write & (STREAM_RING_FRAMES - 1))
		count := min(free, STREAM_RING_FRAMES - start, int(sound.frames - stream.next_frame))
		read := m.host.file_read_at(
			file,
			sound.offset + stream.next_frame * frame_size,
			&stream.ring[start * int(sound.channels)],
			u64(count) * frame_size,
		)
		frames := int(read / i64(frame_size))
		if read < 0 || frames == 0 {
			stream_fail(m, stream)
			return
		}
		write += u64(frames)
		stream.next_frame += u64(frames)
		free -= frames
		sync.atomic_store_explicit(&stream.write.value, write, .Release)
	}
}

@(private)
stream_fail :: proc(m: ^Mixer, stream: ^Stream) {
	sync.atomic_add_explicit(&m.stream_failed, 1, .Relaxed)
	sync.atomic_store_explicit(&stream.ended, true, .Release)
}

// stream_step is one pass over the streams. It is the stream thread's, or the test's.
stream_step :: proc(m: ^Mixer) {
	for &stream in m.streams {
		switch sync.atomic_load_explicit(&stream.state, .Acquire) {
		case .Free:
		case .Active:
			stream_fill(m, &stream)
		case .Closing:
			sync.atomic_sub_explicit(&stream.sound.users, 1, .Release)
			sync.atomic_store_explicit(&stream.state, .Free, .Release)
		}
	}
}

@(private)
stream_thread_proc :: proc(data: rawptr) {
	m := (^Mixer)(data)
	for !sync.atomic_load_explicit(&m.closing, .Acquire) {
		stream_step(m)
		sleep_ms(STREAM_WAIT_MS)
	}
}

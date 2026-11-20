package audio_mixer

import "core:sync"

import "cinnabar:core/audio/codec"

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
	state:          Stream_State,
	sound:          ^Sound_Data,
	loop:           bool,
	// The stream thread's: the next frame of the file, and the file's time at the first read.
	next_frame:     u64,
	modified:       i64,
	opened:         bool,
	// A compressed sound's decoder, and what it has decoded that the ring has not taken.
	decoder:        codec.Decoder,
	pending:        [^]i16,
	pending_frames: int,
	// Allocated on the game's thread, and kept for the stream's next sound.
	decoder_memory: []byte,
	// Interleaved like the sound.
	ring:           [^]i16,
	read:           Index,
	write:          Index,
	// Set after the last write: no more frames come.
	ended:          b32,
	// A read from another frame: the mix thread asks with a new ticket, and the stream thread answers with it once the
	// ring holds the sound from seek_frame, or once the stream ended. Until then, the mix thread does not read the ring.
	seek_frame:     u64,
	seek_asked:     u32,
	seek_answered:  u32,
}

// stream_take gives a playing voice a free stream, which first reads from start, or nil. The ring and the decoder's memory
// are allocated here, on the game's thread, so the stream thread decodes without allocating.
@(private)
stream_take :: proc(
	m: ^Mixer,
	sound: ^Sound_Data,
	loop: bool,
	start: u64,
) -> (
	taken: ^Stream,
	ticket: u32,
) {
	for &stream in m.streams {
		if sync.atomic_load_explicit(&stream.state, .Acquire) != .Free {
			continue
		}
		if stream.ring == nil {
			stream.ring = ([^]i16)(
				m.host.allocate(STREAM_RING_FRAMES * 2 * size_of(i16), align_of(i16)),
			)
			if stream.ring == nil {
				return nil, 0
			}
		}
		if sound.format != .PCM && !stream_decoder_init(m, &stream, sound) {
			return nil, 0
		}
		stream.pending_frames = 0
		stream.sound = sound
		stream.loop = loop
		stream.next_frame = 0
		stream.opened = false
		stream.read.value = 0
		stream.write.value = 0
		stream.ended = false
		// The first read is the first ticket, which the voice waits for. The stream answered every earlier one.
		stream.seek_frame = start
		stream.seek_answered = stream.seek_asked
		stream.seek_asked += 1
		// A stream's voice holds its sound through the stream.
		sync.atomic_store_explicit(&stream.state, .Active, .Release)
		return &stream, stream.seek_asked
	}
	return nil, 0
}

@(private)
stream_decoder_init :: proc(m: ^Mixer, stream: ^Stream, sound: ^Sound_Data) -> bool {
	channels := int(sound.channels)
	size := codec.memory_bytes(sound.format, channels)
	if len(stream.decoder_memory) < size {
		memory := m.host.allocate(uint(size), codec.MEMORY_ALIGN)
		if memory == nil {
			return false
		}
		if stream.decoder_memory != nil {
			m.host.free(raw_data(stream.decoder_memory))
		}
		stream.decoder_memory = ([^]byte)(memory)[:size]
	}
	return codec.decoder_init(
		&stream.decoder,
		sound.format,
		channels,
		sound.frames,
		u64(sound.skip),
		sound.size,
		stream.decoder_memory,
	)
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

// stream_ask asks the stream thread to read from another frame, on the mix thread, and gives the ticket that it answers.
@(private)
stream_ask :: proc(stream: ^Stream, frame: u64) -> u32 {
	stream.seek_frame = frame
	ticket := stream.seek_asked + 1
	sync.atomic_store_explicit(&stream.seek_asked, ticket, .Release)
	return ticket
}

// stream_ready is whether a voice can start: the stream answered its ticket and has read, so it does not start with a gap.
@(private)
stream_ready :: proc(stream: ^Stream, ticket: u32) -> bool {
	if sync.atomic_load_explicit(&stream.seek_answered, .Acquire) != ticket {
		return false
	}
	ended := sync.atomic_load_explicit(&stream.ended, .Acquire)
	return(
		bool(ended) ||
		sync.atomic_load_explicit(&stream.write.value, .Acquire) > stream.read.value \
	)
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
//
// A seek empties the ring, which the mix thread does not read while it waits for the answer. The answer comes after the
// first read from the new place, or once the stream ended or failed.
@(private)
stream_fill :: proc(m: ^Mixer, stream: ^Stream) {
	asked := sync.atomic_load_explicit(&stream.seek_asked, .Acquire)
	seeking := asked != stream.seek_answered
	if !seeking && sync.atomic_load_explicit(&stream.ended, .Relaxed) {
		return
	}
	defer if seeking {
		sync.atomic_store_explicit(&stream.seek_answered, asked, .Release)
	}
	write := sync.atomic_load_explicit(&stream.write.value, .Relaxed)
	if seeking {
		write = sync.atomic_load_explicit(&stream.read.value, .Acquire)
		sync.atomic_store_explicit(&stream.write.value, write, .Release)
		sync.atomic_store_explicit(&stream.ended, false, .Release)
		stream.pending_frames = 0
	}
	free :=
		STREAM_RING_FRAMES - int(write - sync.atomic_load_explicit(&stream.read.value, .Acquire))
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
	if seeking && !stream_seek(m, stream, file) {
		return
	}
	if sound.format != .PCM {
		stream_fill_decoded(m, stream, file, write, free)
		return
	}

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

// stream_seek moves a stream's place in its file to seek_frame. A loop wraps a frame past its end, and a frame past the end
// of a sound that does not loop ends the stream.
@(private)
stream_seek :: proc(m: ^Mixer, stream: ^Stream, file: rawptr) -> bool {
	sound := stream.sound
	frame := stream.seek_frame
	if stream.loop {
		frame %= sound.frames
	} else if frame >= sound.frames {
		sync.atomic_store_explicit(&stream.ended, true, .Release)
		return false
	}
	if sound.format == .PCM {
		stream.next_frame = frame
		return true
	}
	reader := Stream_Reader{m, file, sound.offset}
	if !codec.decoder_seek(
		&stream.decoder,
		frame,
		sound.seek[:sound.seek_count],
		stream_read_file,
		&reader,
	) {
		stream_fail(m, stream)
		return false
	}
	return true
}

@(private)
Stream_Reader :: struct {
	m:      ^Mixer,
	file:   rawptr,
	offset: u64,
}

@(private)
stream_read_file :: proc(user: rawptr, offset: u64, buffer: rawptr, size: u64) -> i64 {
	reader := (^Stream_Reader)(user)
	return reader.m.host.file_read_at(reader.file, reader.offset + offset, buffer, size)
}

// stream_fill_decoded fills the ring from a compressed sound's decoder. A block that does not fit waits for the next fill.
@(private)
stream_fill_decoded :: proc(m: ^Mixer, stream: ^Stream, file: rawptr, write: u64, free: int) {
	write, free := write, free
	sound := stream.sound
	channels := int(sound.channels)
	reader := Stream_Reader{m, file, sound.offset}
	for free > 0 {
		if stream.pending_frames == 0 {
			frames, count, status := codec.decoder_next(&stream.decoder, stream_read_file, &reader)
			switch status {
			case .Failed:
				stream_fail(m, stream)
				return
			case .End:
				if !stream.loop {
					sync.atomic_store_explicit(&stream.ended, true, .Release)
					return
				}
				codec.decoder_restart(&stream.decoder)
				continue
			case .Frames:
				stream.pending = frames
				stream.pending_frames = count
			}
		}
		start := int(write & (STREAM_RING_FRAMES - 1))
		count := min(free, STREAM_RING_FRAMES - start, stream.pending_frames)
		copy(stream.ring[start * channels:][:count * channels], stream.pending[:count * channels])
		stream.pending = stream.pending[count * channels:]
		stream.pending_frames -= count
		write += u64(count)
		free -= count
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

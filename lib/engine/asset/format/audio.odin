package asset_format

import "core:mem"

import "cinnabar:core/layout"

// Every sound is cooked to this rate, as the audio device and the boundary take (see docs/content/kinds/audio.md#audio).
AUDIO_SAMPLE_RATE :: 48000

// Audio_Blob is the start of an audio blob: a sound as 16-bit PCM at AUDIO_SAMPLE_RATE, with interleaved channels. The
// samples are not compressed, so a stream reads any part of them straight from the file. stream asks the runtime to read
// them as they play, and not to load them (see docs/audio/design.md#streaming).
Audio_Blob :: struct {
	header:      Blob_Header,
	frames:      u64,
	// 1 or 2.
	channels:    u32,
	stream:      b32,
	samples:     Slice,
	source_path: Slice,
}

audio_layout :: proc() -> u64 {
	return layout.hash(Audio_Blob)
}

// audio_check checks the start of an audio blob, which is all that a stream reads of it before it plays: its header, its
// layout and that its samples are the size that its frames say.
audio_check :: proc "contextless" (blob: ^Audio_Blob, guid: Guid) -> bool {
	h := blob.header
	if h.magic != BLOB_MAGIC || h.kind != .Audio || h.guid != guid {
		return false
	}
	return (blob.channels == 1 || blob.channels == 2) && blob.frames > 0 && u64(blob.samples.size) == blob.frames * u64(blob.channels) * size_of(i16)
}

// audio_view checks a whole audio blob: its start, and that its slices are inside it.
audio_view :: proc(data: []byte) -> (blob: ^Audio_Blob, ok: bool) {
	header := blob_header(data) or_return
	if header.kind != .Audio || header.layout != audio_layout() || len(data) < size_of(Audio_Blob) {
		return
	}
	blob = (^Audio_Blob)(raw_data(data))
	if !audio_check(blob, header.guid) {
		return nil, false
	}
	inside :: proc(data: []byte, s: Slice, align: int) -> bool {
		return u64(s.offset) + u64(s.size) <= u64(len(data)) && int(s.offset) % align == 0
	}
	if !inside(data, blob.samples, align_of(i16)) || !inside(data, blob.source_path, 1) {
		return nil, false
	}
	return blob, true
}

// audio_samples is a viewed blob's samples, interleaved.
audio_samples :: proc(data: []byte, blob: ^Audio_Blob) -> []i16 {
	return mem.slice_data_cast([]i16, blob_bytes(data, blob.samples))
}

Audio_Contents :: struct {
	guid:        Guid,
	key:         u64,
	channels:    u32,
	stream:      bool,
	samples:     []i16,
	source_path: string,
}

// audio_write builds an audio blob.
audio_write :: proc(contents: Audio_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Audio_Blob), allocator)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	samples := reserve_bytes(&buffer, len(contents.samples) * size_of(i16), BLOB_ALIGN)
	if len(contents.samples) > 0 {
		mem.copy(&buffer[samples.offset], raw_data(contents.samples), int(samples.size))
	}
	blob := Audio_Blob {
		header = {magic = BLOB_MAGIC, kind = .Audio, layout = audio_layout(), key = contents.key, guid = contents.guid},
		frames = u64(len(contents.samples)) / u64(contents.channels),
		channels = contents.channels,
		stream = b32(contents.stream),
		samples = samples,
		source_path = source_path,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

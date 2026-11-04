package asset_format

import "core:mem"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/adpcm"
import "cinnabar:core/layout"

// Every sound is cooked to this rate, as the audio device and the boundary take (see docs/content/kinds/audio.md#audio).
AUDIO_SAMPLE_RATE :: 48000

// Audio_Blob is the start of an audio blob: a sound at AUDIO_SAMPLE_RATE, with interleaved channels, as 16-bit PCM or
// compressed. stream asks the runtime to read it as it plays, and not to load it (see docs/audio/design.md#streaming). Each
// pass over compressed data throws away skip frames, keeps frames frames and ignores the rest.
Audio_Blob :: struct {
	header:      Blob_Header,
	frames:      u64,
	// 1 or 2.
	channels:    u32,
	stream:      b32,
	data:        Slice,
	source_path: Slice,
	format:      audio.Sound_Format,
	skip:        u32,
}

audio_layout :: proc() -> u64 {
	return layout.hash(Audio_Blob)
}

// audio_check checks the start of an audio blob, which is all that a stream reads of it before it plays: its header, its
// layout and, where its format has a fixed size, that its data is the size that its frames say.
audio_check :: proc "contextless" (blob: ^Audio_Blob, guid: Guid) -> bool {
	h := blob.header
	if h.magic != BLOB_MAGIC || h.kind != .Audio || h.guid != guid {
		return false
	}
	if (blob.channels != 1 && blob.channels != 2) || blob.frames == 0 {
		return false
	}
	size := u64(blob.data.size)
	switch blob.format {
	case .PCM:
		return size == blob.frames * u64(blob.channels) * size_of(i16)
	case .ADPCM:
		return size == adpcm.data_bytes(blob.frames, int(blob.channels))
	case .Vorbis, .Opus:
		return size > 0
	}
	return false
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
	if !inside(data, blob.data, align_of(i16)) || !inside(data, blob.source_path, 1) {
		return nil, false
	}
	return blob, true
}

// audio_data is a viewed blob's data, in its format.
audio_data :: proc(data: []byte, blob: ^Audio_Blob) -> []byte {
	return blob_bytes(data, blob.data)
}

// audio_samples is a viewed PCM blob's samples, interleaved.
audio_samples :: proc(data: []byte, blob: ^Audio_Blob) -> []i16 {
	return mem.slice_data_cast([]i16, audio_data(data, blob))
}

Audio_Contents :: struct {
	guid:        Guid,
	key:         u64,
	frames:      u64,
	channels:    u32,
	stream:      bool,
	format:      audio.Sound_Format,
	skip:        u32,
	data:        []byte,
	source_path: string,
}

// audio_write builds an audio blob.
audio_write :: proc(contents: Audio_Contents, allocator := context.allocator) -> []byte {
	buffer := make([dynamic]byte, size_of(Audio_Blob), allocator)
	source_path := append_bytes(&buffer, transmute([]byte)contents.source_path)
	data := reserve_bytes(&buffer, len(contents.data), BLOB_ALIGN)
	if len(contents.data) > 0 {
		mem.copy(&buffer[data.offset], raw_data(contents.data), int(data.size))
	}
	blob := Audio_Blob {
		header = {magic = BLOB_MAGIC, kind = .Audio, layout = audio_layout(), key = contents.key, guid = contents.guid},
		frames = contents.frames,
		channels = contents.channels,
		stream = b32(contents.stream),
		data = data,
		source_path = source_path,
		format = contents.format,
		skip = contents.skip,
	}
	mem.copy(raw_data(buffer), &blob, size_of(blob))
	return buffer[:]
}

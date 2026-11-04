package cook

import "base:runtime"
import "core:c"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/adpcm"
import "cinnabar:core/audio/opus"

// tools/cook/vorbis, which `just vorbis` builds. Only the cooker links it: the runtime decodes with vendor:stb/vorbis.
foreign import cn_vorbis "../../build/obj/vorbis/out/cn_vorbis.lib"

// The justfile passes the tags, so an update of either cooks every sound again.
OPUS_VERSION :: #config(OPUS_VERSION, "unknown")
VORBIS_VERSION :: #config(VORBIS_VERSION, "unknown")

// How much of the sound's own end comes before it and of its start after it, in the coded data. It is longer than the
// overlap of a Vorbis long block and than Opus's start-up, so the decoder is settled on continuous sound at both ends of a
// pass, and a loop's two sides differ only by coding noise. See docs/audio/design.md#streaming.
AUDIO_ROLL_FRAMES :: 4096
// libvorbis's quality 5, in its scale from -0.1 to 1. About 160 kbps for stereo music.
AUDIO_VORBIS_QUALITY :: 0.5
// For each channel.
AUDIO_OPUS_BITRATE :: 64000
// 20 ms, the longest single frame of Opus's music mode.
AUDIO_OPUS_PACKET_FRAMES :: 960
// Opus's largest packet for one frame.
AUDIO_OPUS_MAX_PACKET :: 1275

@(private = "file")
Vorbis_Write :: #type proc "c" (user: rawptr, data: [^]byte, size: c.long)

@(default_calling_convention = "c")
foreign cn_vorbis {
	cn_vorbis_encode :: proc(samples: [^]i16, frames: u64, channels: c.int, quality: f32, write: Vorbis_Write, user: rawptr) -> c.int ---
}

// audio_encode codes a sound's interleaved samples in a compressed format. skip is what a pass throws away before the
// sound. The data is from the temp allocator.
audio_encode :: proc(format: audio.Sound_Format, samples: []i16, channels: int) -> (data: []byte, skip: u32, ok: bool) {
	#partial switch format {
	case .ADPCM:
		return adpcm.encode(samples, channels, context.temp_allocator), 0, true
	case .Vorbis:
		return encode_vorbis(samples, channels)
	case .Opus:
		return encode_opus(samples, channels)
	}
	return nil, 0, false
}

// rolled is the sound after AUDIO_ROLL_FRAMES of its end, and before as much of its start, wrapping as often as a short
// sound needs.
@(private = "file")
rolled :: proc(samples: []i16, channels: int) -> []i16 {
	frames := len(samples) / channels
	out := make([]i16, (frames + 2 * AUDIO_ROLL_FRAMES) * channels, context.temp_allocator)
	for i in 0 ..< len(out) / channels {
		from := (i + frames - AUDIO_ROLL_FRAMES % frames) % frames
		for c in 0 ..< channels {
			out[i * channels + c] = samples[from * channels + c]
		}
	}
	return out
}

@(private = "file")
Vorbis_Target :: struct {
	bytes:    ^[dynamic]byte,
	context_: runtime.Context,
}

@(private = "file")
encode_vorbis :: proc(samples: []i16, channels: int) -> (data: []byte, skip: u32, ok: bool) {
	input := rolled(samples, channels)
	out := make([dynamic]byte, context.temp_allocator)
	target := Vorbis_Target{&out, context}
	write := proc "c" (user: rawptr, data: [^]byte, size: c.long) {
		target := (^Vorbis_Target)(user)
		context = target.context_
		append(target.bytes, ..data[:size])
	}
	if cn_vorbis_encode(raw_data(input), u64(len(input) / channels), c.int(channels), AUDIO_VORBIS_QUALITY, write, &target) != 0 {
		return nil, 0, false
	}
	return out[:], AUDIO_ROLL_FRAMES, true
}

@(private = "file")
encode_opus :: proc(samples: []i16, channels: int) -> (data: []byte, skip: u32, ok: bool) {
	input := rolled(samples, channels)
	state := make([]byte, opus.encoder_get_size(c.int(channels)), context.temp_allocator)
	encoder := (^opus.Encoder)(raw_data(state))
	if opus.encoder_init(encoder, audio.SAMPLE_RATE, c.int(channels), opus.APPLICATION_AUDIO) != opus.OK {
		return nil, 0, false
	}
	opus.encoder_ctl(encoder, opus.SET_BITRATE_REQUEST, i32(AUDIO_OPUS_BITRATE * channels))
	opus.encoder_ctl(encoder, opus.SET_COMPLEXITY_REQUEST, i32(10))
	opus.encoder_ctl(encoder, opus.SET_SIGNAL_REQUEST, i32(opus.SIGNAL_MUSIC))
	lookahead: i32
	opus.encoder_ctl(encoder, opus.GET_LOOKAHEAD_REQUEST, &lookahead)

	out := make([dynamic]byte, context.temp_allocator)
	packet: [AUDIO_OPUS_MAX_PACKET]byte
	frame := make([]i16, AUDIO_OPUS_PACKET_FRAMES * channels, context.temp_allocator)
	for start := 0; start < len(input); start += len(frame) {
		// The last frame ends in silence, past what a pass keeps.
		count := copy(frame, input[start:])
		for i in count ..< len(frame) {
			frame[i] = 0
		}
		size := opus.encode(encoder, raw_data(frame), AUDIO_OPUS_PACKET_FRAMES, &packet[0], len(packet))
		if size <= 0 {
			return nil, 0, false
		}
		append(&out, u8(size & 0xff), u8(size >> 8))
		append(&out, ..packet[:size])
	}
	return out[:], AUDIO_ROLL_FRAMES + u32(lookahead), true
}

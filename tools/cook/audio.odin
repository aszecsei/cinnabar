package cook

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:slice"

import ma "vendor:miniaudio"

import audio "cinnabar:core/audio"
import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks sounds changes this, which invalidates every cooked sound.
AUDIO_COOK_VERSION :: "audio 2"
// The sounds that the cooker decodes.
AUDIO_EXTENSIONS :: []string{".wav", ".ogg", ".flac", ".mp3"}
// A sound longer than this streams, unless its .meta file says otherwise: loading it would take more than a moment.
AUDIO_STREAM_SECONDS :: 10
// A rate conversion's filter: its zero crossings on each side, how many places between two frames it has taps for, and its
// window's shape, whose side lobes are about 90 dB down.
AUDIO_SINC_ZEROS :: 16
AUDIO_SINC_PLACES :: 512
AUDIO_SINC_BETA :: 8.6
// A blob's slices are u32, so its data must fit in one.
AUDIO_MAX_BYTES :: 4 * 1024 * 1024 * 1024 - 4096

AUDIO_SETTINGS := []Setting_Info {
	{
		key = "stream",
		values = {"auto", "true", "false"},
		default = "auto",
		description = "Read the sound from its blob as it plays, rather than load it. Auto streams a sound longer than 10 seconds.",
	},
	{
		key = "channels",
		values = {"auto", "mono", "stereo"},
		default = "auto",
		description = "The channels of the cooked sound. Auto keeps the source's, and more than two become stereo. A sound placed in the world plays as mono either way, so mono takes half the space.",
	},
	{
		key = "format",
		values = {"pcm", "adpcm", "vorbis", "opus"},
		default = "pcm",
		description = "How the blob stores the sound. Pcm is exact and largest. Adpcm is about 4 times smaller, for short sounds that play often. Vorbis and opus are about 10 times smaller, for music and other long sounds. A sound that does not stream is decoded when it loads, so its format saves disk and not memory.",
	},
}

cook_audio :: proc(options: Cook_Options, assets: []Asset_Source, pass: ^Pass) -> bool {
	problems := &pass.problems
	out_dir := config_dir(options)
	sounds := assets_of(assets, .Audio)
	if len(sounds) > 0 {
		if err := os.make_directory_all(out_dir); err != nil && err != .Exist {
			report_error(problems, out_dir, 0, 0, "%v", err)
			return false
		}
	}
	ok := true
	step_begin(pass, .Audio, "", len(sounds))
	for i in sounds {
		defer step_advance(pass)
		if !cook_sound(&assets[i], out_dir, pass) {
			assets[i].failed = true
			ok = false
		}
	}
	return ok
}

@(private = "file")
audio_setting :: proc(a: Asset_Source, key: string) -> string {
	if value, found := format.meta_value(a.meta, key); found {
		return value
	}
	info, _ := find_setting(AUDIO_SETTINGS, key)
	return info.default
}

@(private = "file")
cook_sound :: proc(a: ^Asset_Source, out_dir: string, pass: ^Pass) -> bool {
	problems := &pass.problems
	if !check_settings(a^, problems) {
		return false
	}
	// A setting is part of the key through the .meta file's text, and so are the codecs through their versions.
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%s\x00%s\x00%s\x00%x\x00", AUDIO_COOK_VERSION, ma.BINDINGS_VERSION_STRING, OPUS_VERSION, VORBIS_VERSION, a.name, format.audio_layout()))
	key = hash.fnv64a(a.source, key)
	key = hash.fnv64a(transmute([]byte)a.meta_text, key)
	guid := a.meta.guid
	key = hash.fnv64a(guid[:], key)
	buffer: [32]u8
	output := fmt.tprintf("%s/%s.blob", out_dir, format.guid_format(guid, &buffer))
	if cooked_key(output, .Audio, format.audio_layout()) == key && !pass.force[guid] {
		pass.current[.Audio] += 1
		return true
	}
	samples, channels, decoded := decode_sound(a.source, audio_setting(a^, "channels"))
	defer delete(samples)
	// A sound that fails keeps its old blob, so the running game keeps the last good version.
	if !decoded {
		report_error(problems, a.path, 0, 0, "cannot decode this sound. It takes .wav, .ogg, .flac or .mp3 with at least one sample.")
		return false
	}
	frames := len(samples) / int(channels)
	stream: bool
	switch audio_setting(a^, "stream") {
	case "true":
		stream = true
	case "false":
		stream = false
	case:
		stream = frames > AUDIO_STREAM_SECONDS * format.AUDIO_SAMPLE_RATE
	}
	sound_format := audio_format_of(audio_setting(a^, "format"))
	data := slice.to_bytes(samples[:])
	skip: u32
	if sound_format != .PCM {
		encoded: bool
		data, skip, encoded = audio_encode(sound_format, samples[:], int(channels))
		if !encoded {
			report_error(problems, a.path, 0, 0, "cannot encode this sound as %v", sound_format)
			return false
		}
	}
	if len(data) > AUDIO_MAX_BYTES {
		report_error(problems, a.path, 0, 0, "is too long: its data takes more than 4 GiB")
		return false
	}
	blob := format.audio_write({guid = guid, key = key, frames = u64(frames), channels = channels, stream = stream, format = sound_format, skip = skip, data = data, source_path = a.name}, context.temp_allocator)
	if !write_blob(output, blob) {
		return false
	}
	pass.cooked[.Audio] += 1
	return true
}

@(private = "file")
audio_format_of :: proc(setting: string) -> audio.Sound_Format {
	switch setting {
	case "adpcm":
		return .ADPCM
	case "vorbis":
		return .Vorbis
	case "opus":
		return .Opus
	}
	return .PCM
}

// decode_sound decodes a sound to 16-bit PCM at the engine's rate, in the channels that the setting asks for. The samples
// are the caller's, from the heap.
@(private = "file")
decode_sound :: proc(source: []byte, channels_setting: string) -> (samples: [dynamic]i16, channels: u32, ok: bool) {
	// The source's channels and rate first, from a decoder that asks for no conversion of them.
	config := ma.decoder_config_init(.s16, 0, 0)
	decoder: ma.decoder
	if ma.decoder_init_memory(raw_data(source), len(source), &config, &decoder) != .SUCCESS {
		return
	}
	channels = decoder.outputChannels
	rate := decoder.outputSampleRate
	ma.decoder_uninit(&decoder)
	switch channels_setting {
	case "mono":
		channels = 1
	case "stereo":
		channels = 2
	case:
		channels = min(channels, 2)
	}
	config = ma.decoder_config_init(.s16, channels, rate)
	if ma.decoder_init_memory(raw_data(source), len(source), &config, &decoder) != .SUCCESS {
		return
	}
	defer ma.decoder_uninit(&decoder)
	// Decoders do not all know their length before they run, so this grows as it reads.
	CHUNK_FRAMES :: 1 << 16
	for {
		start := len(samples)
		resize(&samples, start + CHUNK_FRAMES * int(channels))
		read: u64
		result := ma.decoder_read_pcm_frames(&decoder, &samples[start], CHUNK_FRAMES, &read)
		resize(&samples, start + int(read) * int(channels))
		if result != .SUCCESS || read < CHUNK_FRAMES {
			break
		}
	}
	if len(samples) == 0 {
		return samples, channels, false
	}
	if rate == format.AUDIO_SAMPLE_RATE {
		return samples, channels, true
	}
	converted := convert_rate(samples[:], int(channels), rate)
	delete(samples)
	return converted, channels, true
}

// convert_rate converts a sound to the engine's rate as a loop, with a windowed sinc that reads around the sound's ends: a
// resampler that starts and stops on the sound alone ends short of it, and leaves a step where a loop returns to the start
// (see docs/content/kinds/audio.md#audio). A frame of the result reads the source at a place in proportion, so the loop
// closes exactly, whatever the rates. It has no latency, and a sound that does not loop is no worse for it.
@(private = "file")
convert_rate :: proc(samples: []i16, channels: int, rate: u32) -> (out: [dynamic]i16) {
	frames := len(samples) / channels
	frames_out := max(int(f64(frames) * format.AUDIO_SAMPLE_RATE / f64(rate) + 0.5), 1)
	// Going down in rate, the filter's cutoff goes down with it, and its reach grows.
	cutoff := min(f64(1), f64(format.AUDIO_SAMPLE_RATE) / f64(rate))
	reach := int(math.ceil(AUDIO_SINC_ZEROS / cutoff))
	taps := 2 * reach

	// A row of taps for each place between two frames of the source, and one more for the last to blend towards.
	table := make([]f32, (AUDIO_SINC_PLACES + 1) * taps)
	defer delete(table)
	for place in 0 ..= AUDIO_SINC_PLACES {
		row := table[place * taps:][:taps]
		total: f64
		for &tap, k in row {
			x := f64(k - reach + 1) - f64(place) / AUDIO_SINC_PLACES
			value := cutoff * sinc(cutoff * x) * kaiser(x / f64(reach))
			tap = f32(value)
			total += value
		}
		for &tap in row {
			tap = f32(f64(tap) / total)
		}
	}

	resize(&out, frames_out * channels)
	for frame in 0 ..< frames_out {
		position := f64(frame) * f64(frames) / f64(frames_out)
		whole := int(position)
		place := (position - f64(whole)) * AUDIO_SINC_PLACES
		row := min(int(place), AUDIO_SINC_PLACES - 1)
		blend := f32(place - f64(row))
		near := table[row * taps:][:taps]
		far := table[(row + 1) * taps:][:taps]
		for c in 0 ..< channels {
			sum: f32
			for k in 0 ..< taps {
				from := (whole + k - reach + 1) %% frames
				sum += f32(samples[from * channels + c]) * (near[k] + (far[k] - near[k]) * blend)
			}
			out[frame * channels + c] = i16(clamp(math.round(sum), -32768, 32767))
		}
	}
	return out
}

@(private = "file")
sinc :: proc(x: f64) -> f64 {
	return 1 if abs(x) < 1e-9 else math.sin(math.PI * x) / (math.PI * x)
}

// The Kaiser window, where x runs from -1 to 1 across it.
@(private = "file")
kaiser :: proc(x: f64) -> f64 {
	if abs(x) >= 1 {
		return 0
	}
	// Bessel's I0, by its series.
	i0 :: proc(x: f64) -> f64 {
		sum, term := f64(1), f64(1)
		for k in 1 ..< 32 {
			term *= (x / (2 * f64(k))) * (x / (2 * f64(k)))
			sum += term
		}
		return sum
	}
	return i0(AUDIO_SINC_BETA * math.sqrt(1 - x * x)) / i0(AUDIO_SINC_BETA)
}

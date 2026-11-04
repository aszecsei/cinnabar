package cook

import "core:fmt"
import "core:hash"
import "core:os"

import ma "vendor:miniaudio"

import format "cinnabar:engine/asset/format"

// Changing how the cooker cooks sounds changes this, which invalidates every cooked sound.
AUDIO_COOK_VERSION :: "audio 1"
// The sounds that the cooker decodes.
AUDIO_EXTENSIONS :: []string{".wav", ".ogg", ".flac", ".mp3"}
// A sound longer than this streams, unless its .meta file says otherwise: loading it would take more than a moment.
AUDIO_STREAM_SECONDS :: 10
// A blob's slices are u32, so its samples must fit in one.
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
	// A setting is part of the key through the .meta file's text, and so is the decoder through its version.
	key := hash.fnv64a(transmute([]byte)fmt.tprintf("%s\x00%s\x00%s\x00%x\x00", AUDIO_COOK_VERSION, ma.BINDINGS_VERSION_STRING, a.name, format.audio_layout()))
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
	if len(samples) * size_of(i16) > AUDIO_MAX_BYTES {
		report_error(problems, a.path, 0, 0, "is too long: its samples take more than 4 GiB")
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
	blob := format.audio_write({guid = guid, key = key, channels = channels, stream = stream, samples = samples[:], source_path = a.name}, context.temp_allocator)
	if !write_blob(output, blob) {
		return false
	}
	pass.cooked[.Audio] += 1
	return true
}

// decode_sound decodes a sound to 16-bit PCM at the engine's rate, in the channels that the setting asks for. The samples
// are the caller's, from the heap.
@(private = "file")
decode_sound :: proc(source: []byte, channels_setting: string) -> (samples: [dynamic]i16, channels: u32, ok: bool) {
	// The source's channels first, from a decoder that asks for no conversion of them.
	config := ma.decoder_config_init(.s16, 0, format.AUDIO_SAMPLE_RATE)
	decoder: ma.decoder
	if ma.decoder_init_memory(raw_data(source), len(source), &config, &decoder) != .SUCCESS {
		return
	}
	channels = decoder.outputChannels
	ma.decoder_uninit(&decoder)
	switch channels_setting {
	case "mono":
		channels = 1
	case "stereo":
		channels = 2
	case:
		channels = min(channels, 2)
	}
	config = ma.decoder_config_init(.s16, channels, format.AUDIO_SAMPLE_RATE)
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
	return samples, channels, len(samples) > 0
}

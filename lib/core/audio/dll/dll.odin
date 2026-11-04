// Package audio_dll exports the mixer as a library, audio_cinnabar.dll, as another backend would be. It proves the
// boundary end to end: nothing but the two tables crosses it. See docs/audio/backends.md#loading.
package audio_dll

import "base:runtime"

import audio "cinnabar:core/audio"
import audio_mixer "cinnabar:core/audio/mixer"

@(export)
cinnabar_audio_api :: proc "c" (host: ^audio.Host) -> ^audio.Audio_API {
	context = runtime.default_context()
	return audio_mixer.load(host)
}

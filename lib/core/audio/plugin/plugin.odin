// Package audio_plugin finds the audio backend that a project chose: the mixer and the null backend are built in, and
// any other name is the library audio_<name>.dll beside the executable, which exports cinnabar_audio_api. See
// docs/audio/backends.md#loading.
package audio_plugin

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"

import audio "cinnabar:core/audio"
import audio_mixer "cinnabar:core/audio/mixer"
import audio_null "cinnabar:core/audio/null"

// The entry point that a backend exports.
ENTRY_POINT :: "cinnabar_audio_api"

Entry_Point :: #type proc "c" (host: ^audio.Host) -> ^audio.Audio_API

// load gives the table of the backend with this name, which is never nil: an empty name and mixer are the mixer, none
// is the null backend, and another name is a library. A backend that does not load, or that has another API version or
// layout, logs an error and gives the null backend, so that the game runs without sound rather than not at all.
load :: proc(host: ^audio.Host, name := "") -> ^audio.Audio_API {
	name := name if name != "" else "mixer"
	switch name {
	case "mixer":
		return audio_mixer.load(host)
	case "none":
		return audio_null.load(host)
	}
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		log.errorf("audio: cannot find the executable's directory: %v", err)
		return audio_null.load(host)
	}
	path, _ := filepath.join({dir, fmt.tprintf("audio_%s.dll", name)}, context.temp_allocator)
	return checked(host, load_from(host, path), name)
}

// checked is api if it has this build's API version and layout, and the null backend otherwise.
checked :: proc(host: ^audio.Host, api: ^audio.Audio_API, name: string) -> ^audio.Audio_API {
	if api == nil {
		log.errorf("audio: backend %q did not load, so the game runs without sound", name)
		return audio_null.load(host)
	}
	info := api.info()
	if info.api_version != audio.API_VERSION || info.layout != audio.layout_signature() {
		log.errorf(
			"audio: backend %q has API version %d and layout %x, not %d and %x, so the game runs without sound",
			name,
			info.api_version,
			info.layout,
			audio.API_VERSION,
			audio.layout_signature(),
		)
		return audio_null.load(host)
	}
	return api
}

// load_from loads a backend from a library's path, or gives nil, which it logs. The library stays loaded for the life of
// the process: its threads are the host's, and they run through code reloads and soft restarts.
load_from :: proc(host: ^audio.Host, path: string) -> ^audio.Audio_API {
	library, loaded := dynlib.load_library(path)
	if !loaded {
		log.errorf("audio: cannot load the backend %s", path)
		return nil
	}
	symbol, found := dynlib.symbol_address(library, ENTRY_POINT)
	if !found {
		log.errorf("audio: %s does not export %s", path, ENTRY_POINT)
		dynlib.unload_library(library)
		return nil
	}
	return (Entry_Point)(symbol)(host)
}

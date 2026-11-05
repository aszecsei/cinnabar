package audio_plugin

import "core:log"
import "core:sync"
import "core:testing"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/conformance"
import audio_host "cinnabar:core/audio/host"
import "cinnabar:core/testlog"

@(private = "file")
lock: sync.Mutex

@(private = "file")
host: audio.Host

@(private = "file")
fake_write :: proc "c" (frames: [^]audio.Device_Frame, count: i32) -> i32 {
	return count
}

@(private = "file")
fake_status :: proc "c" (out: ^audio.Device_Status) {
	out^ = {}
}

@(private = "file")
setup :: proc() {
	context.logger = log.nil_logger()
	host = audio_host.table(fake_write, fake_status)
}

// The mixer that just audio-plugin builds, loaded as a library: it has this build's API version and layout, and it
// passes the suite with nothing but the two tables between it and this process.
@(test)
the_mixer_loads_as_a_plugin :: proc(t: ^testing.T) {
	sync.guard(&lock)
	setup()
	api := load_from(&host, "build/obj/audio/audio_cinnabar.dll")
	testing.expect(t, api != nil)
	if api == nil {
		return
	}
	defer api.shutdown()
	info := api.info()
	testing.expect_value(t, string(info.name), "mixer")
	testing.expect_value(t, info.api_version, audio.API_VERSION)
	testing.expect_value(t, info.layout, audio.layout_signature())
	conformance.run(t, api)
}

// Empty and mixer are the mixer, none is the null backend, and a backend that is not beside the executable gives the null
// backend, so the game still runs.
@(test)
names_choose_backends :: proc(t: ^testing.T) {
	sync.guard(&lock)
	setup()
	context.logger = testlog.expected_errors()
	mixer := load(&host)
	testing.expect_value(t, string(mixer.info().name), "mixer")
	testing.expect_value(t, string(load(&host, "mixer").info().name), "mixer")
	testing.expect_value(t, string(load(&host, "none").info().name), "null")
	testing.expect_value(t, string(load(&host, "no_such_backend").info().name), "null")
	mixer.shutdown()
}

@(private = "file")
other_version :: proc "c" () -> audio.Backend_Info {
	return {api_version = audio.API_VERSION + 1, layout = audio.layout_signature(), name = "other", version = "1"}
}

@(private = "file")
other_layout :: proc "c" () -> audio.Backend_Info {
	return {api_version = audio.API_VERSION, layout = audio.layout_signature() + 1, name = "other", version = "1"}
}

@(private = "file")
same :: proc "c" () -> audio.Backend_Info {
	return {api_version = audio.API_VERSION, layout = audio.layout_signature(), name = "same", version = "1"}
}

// A backend built against another boundary never runs: it gives the null backend, as one that does not load does.
@(test)
a_backend_of_another_boundary_is_refused :: proc(t: ^testing.T) {
	sync.guard(&lock)
	setup()
	context.logger = testlog.expected_errors()
	testing.expect_value(t, string(checked(&host, &audio.Audio_API{info = other_version}, "other").info().name), "null")
	testing.expect_value(t, string(checked(&host, &audio.Audio_API{info = other_layout}, "other").info().name), "null")
	testing.expect_value(t, string(checked(&host, nil, "other").info().name), "null")
	testing.expect_value(t, string(checked(&host, &audio.Audio_API{info = same}, "same").info().name), "same")
}

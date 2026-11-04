package audio_null

import "core:log"
import "core:sync"
import "core:testing"

import audio "cinnabar:core/audio"
import "cinnabar:core/audio/conformance"
import audio_host "cinnabar:core/audio/host"

// The backend's state is one per process, and the test runner runs tests on several threads.
@(private = "file")
lock: sync.Mutex

@(private = "file")
host: audio.Host

@(private = "file")
no_write :: proc "c" (frames: [^]audio.Device_Frame, count: i32) -> i32 {
	return count
}

@(private = "file")
no_status :: proc "c" (out: ^audio.Device_Status) {
	out^ = {}
}

// The suite expects stale handles, which the null backend reports, so the log is quiet.
@(test)
passes_conformance :: proc(t: ^testing.T) {
	sync.guard(&lock)
	{
		context.logger = log.nil_logger()
		host = audio_host.table(no_write, no_status)
	}
	conformance.run(t, load(&host))
}

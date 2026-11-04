// Package audio_host is the host's side of the audio boundary: the Host table that a backend calls, built from the
// host's heap, log, audio device and files. It is host code, like the backend. See docs/audio/backends.md#the-contract.
package audio_host

import "base:runtime"
import "core:log"
import "core:mem"

import audio "cinnabar:core/audio"

// The host is one per process, so its state is too. The game never imports this package.
@(private)
state: struct {
	ctx: runtime.Context,
}

// table returns the procedures to give a backend's loader. They run with the calling context's logger. The device's
// procedures are core's, which this package cannot import.
table :: proc(device_write: proc "c" (frames: [^]audio.Device_Frame, count: i32) -> i32, device_status: proc "c" (out: ^audio.Device_Status)) -> audio.Host {
	state.ctx = context
	return {
		allocate = allocate,
		free = free,
		log = log_message,
		device_write = device_write,
		device_status = device_status,
		file_open = file_open,
		file_read_at = file_read_at,
		file_modified = file_modified,
		file_close = file_close,
	}
}

// host_context is the host's context for a thread that is not the one that called table: the temporary allocator of the
// calling thread is its own, not the host's.
@(private)
host_context :: proc "contextless" () -> runtime.Context {
	ctx := state.ctx
	ctx.temp_allocator = {}
	return ctx
}

@(private)
allocate :: proc "c" (size, align: uint) -> rawptr {
	context = host_context()
	data, _ := mem.alloc_bytes(int(size), int(align), runtime.heap_allocator())
	return raw_data(data)
}

@(private)
free :: proc "c" (ptr: rawptr) {
	context = host_context()
	mem.free(ptr, runtime.heap_allocator())
}

@(private)
log_message :: proc "c" (level: audio.Log_Level, message: cstring) {
	context = host_context()
	context.temp_allocator = runtime.heap_allocator()
	switch level {
	case .Debug:
		log.debug(string(message))
	case .Info:
		log.info(string(message))
	case .Warning:
		log.warn(string(message))
	case .Error:
		log.error(string(message))
	}
}

// Package physics_host is the host's side of the physics boundary: the Host table that a backend calls, built from the
// host's heap, job system and log. It is host code, like the backend. See docs/physics/design.md#the-boundary.
package physics_host

import "base:runtime"
import "core:log"
import "core:mem"

import "cinnabar:core/jobs"
import "cinnabar:core/physics"

// The host is one per process, so its state is too. The game never imports this package.
@(private)
state: struct {
	ctx:     runtime.Context,
	run_job: proc "c" (data: rawptr),
}

// table returns the procedures to give a backend's loader. They run with the calling context's logger. bind must
// follow with the loaded table before the backend runs a job.
table :: proc() -> physics.Host {
	state.ctx = context
	return {
		allocate = allocate,
		reallocate = reallocate,
		free = free,
		jobs_run = jobs_run,
		jobs_wait = jobs_wait,
		worker_count = worker_count,
		log = log_message,
	}
}

// bind tells the host which procedure runs the backend's jobs.
bind :: proc(api: ^physics.Physics_API) {
	state.run_job = api.run_job if api != nil else nil
}

@(private)
allocate :: proc "c" (size, align: uint) -> rawptr {
	context = state.ctx
	data, _ := mem.alloc_bytes_non_zeroed(int(size), int(align), runtime.heap_allocator())
	return raw_data(data)
}

@(private)
reallocate :: proc "c" (ptr: rawptr, old_size, new_size, align: uint) -> rawptr {
	context = state.ctx
	data, _ := mem.resize_bytes_non_zeroed(([^]byte)(ptr)[:old_size], int(new_size), int(align), runtime.heap_allocator())
	return raw_data(data)
}

@(private)
free :: proc "c" (ptr: rawptr) {
	context = state.ctx
	mem.free(ptr, runtime.heap_allocator())
}

@(private)
run_backend_job :: proc(data: rawptr) {
	state.run_job(data)
}

// jobs.run copies the jobs, so they go in batches from the stack: the backend calls this from many jobs at once, and
// no allocator here is safe for that.
@(private)
jobs_run :: proc "c" (data: [^]rawptr, count: u32, counter: ^jobs.Counter) {
	context = state.ctx
	BATCH :: 64
	batch: [BATCH]jobs.Job
	for start := 0; start < int(count); start += BATCH {
		n := min(BATCH, int(count) - start)
		for i in 0 ..< n {
			batch[i] = {run_backend_job, data[start + i]}
		}
		jobs.run(batch[:n], counter)
	}
}

@(private)
jobs_wait :: proc "c" (counter: ^jobs.Counter) {
	context = state.ctx
	jobs.wait(counter)
}

@(private)
worker_count :: proc "c" () -> u32 {
	context = state.ctx
	return u32(jobs.worker_count())
}

@(private)
log_message :: proc "c" (level: physics.Log_Level, message: cstring) {
	context = state.ctx
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

// Package jobs is the fiber job system: one worker thread per core, a pool of fibers and atomic counters.
// See docs/core/jobs-and-memory.md#job-system.
//
// The types are shared. The scheduler runs in the host: the game calls it through Platform_API, because the
// game DLL has its own, uninitialized copy of this package.
package jobs

import "base:runtime"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:thread"

FIBER_COUNT :: 128
// Reserved per fiber. Only the touched pages are committed.
FIBER_STACK_SIZE :: 1024 * 1024
FIBER_STACK_COMMIT :: 64 * 1024

Job_Proc :: #type proc(data: rawptr)

Job :: struct {
	procedure: Job_Proc,
	data:      rawptr,
}

// Counter counts unfinished jobs. A zero Counter is ready to use. run adds to it, and wait suspends the
// calling fiber until it is zero again. A counter must outlive the jobs that it counts.
Counter :: struct {
	value:   int,
	// Fibers that wait for zero. Only the scheduler uses this list, under its mutex.
	waiters: rawptr,
}

// Mutex is a fiber-aware lock. A fiber that finds it locked suspends, and its thread runs other jobs, so the
// holder may wait on counters or take other fiber locks while it holds the mutex. A zero Mutex is unlocked.
// Use it only from jobs and the main fiber. An OS lock is still fine for a short section that never waits.
Mutex :: struct {
	locked:  bool,
	// Fibers that wait for the lock, oldest first. Only the scheduler uses these, under its mutex.
	waiters: rawptr,
	last:    rawptr,
}

@(private)
Fiber :: struct {
	handle:     rawptr,
	job:        Job,
	counter:    ^Counter,
	background: bool,
	next:       ^Fiber,
	// The job's scratch memory, in context.temp_allocator. It moves with the fiber between threads.
	scratch:    virtual.Arena,
}

@(private)
Action :: enum u8 {
	None,
	Finished,
	Wait,
	Lock,
}

@(private)
Worker :: struct {
	thread:    ^thread.Thread,
	// The fiber that schedules on this thread. A fiber that finishes or waits switches to it.
	scheduler: rawptr,
	current:   ^Fiber,
	// What the current fiber asks the scheduler to do after the switch. Registering a waiter only after the
	// fiber has switched out means no other thread can resume it while it still runs here.
	action:    Action,
	wait_for:  ^Counter,
	lock_for:  ^Mutex,
}

@(private)
Pending :: struct {
	job:        Job,
	counter:    ^Counter,
	background: bool,
}

@(private)
state: struct {
	context_base: runtime.Context,
	// workers[0] is the main thread, which schedules jobs while its main fiber waits.
	workers:      []Worker,
	fibers:       []Fiber,
	main_fiber:   Fiber,
	mutex:        sync.Mutex,
	cond:         sync.Cond,
	free:         [dynamic]^Fiber,
	queue:        [dynamic]Pending,
	queue_head:   int,
	ready:        [dynamic]^Fiber,
	main_ready:   bool,
	stopping:     bool,
	// Counts the frame jobs, which must finish within the frame.
	frame_jobs:   Counter,
	initialized:  bool,
}

@(private, thread_local)
local_worker: ^Worker

// init starts the workers and makes the calling thread the main thread. The main thread runs jobs while its
// main fiber waits, so a wait from the frame code makes progress even with no other workers.
init :: proc(worker_count := 0) -> bool {
	count := worker_count > 0 ? worker_count : max(os.get_processor_core_count() - 1, 1)
	state.context_base = context
	state.workers = make([]Worker, count + 1)
	state.fibers = make([]Fiber, FIBER_COUNT)
	state.free = make([dynamic]^Fiber, 0, FIBER_COUNT)
	state.queue = make([dynamic]Pending)
	state.ready = make([dynamic]^Fiber)

	state.main_fiber.handle = _thread_to_fiber(&state.main_fiber)
	if state.main_fiber.handle == nil {
		log.error("jobs: cannot make the main thread a fiber")
		return false
	}
	main := &state.workers[0]
	main.current = &state.main_fiber
	main.scheduler = _fiber_create(FIBER_STACK_SIZE, FIBER_STACK_COMMIT, main_scheduler, nil)
	local_worker = main
	for &f in state.fibers {
		f.handle = _fiber_create(FIBER_STACK_SIZE, FIBER_STACK_COMMIT, fiber_main, &f)
		if f.handle == nil || main.scheduler == nil {
			log.error("jobs: cannot create fibers")
			return false
		}
		append(&state.free, &f)
	}
	for &w in state.workers[1:] {
		w.thread = thread.create_and_start_with_data(&w, worker_main, state.context_base)
	}
	state.initialized = true
	log.infof("jobs: %d workers and the main thread", count)
	return true
}

// shutdown stops the workers. Call it from the main fiber with no jobs left.
shutdown :: proc() {
	if !state.initialized {
		return
	}
	sync.lock(&state.mutex)
	state.stopping = true
	sync.cond_broadcast(&state.cond)
	sync.unlock(&state.mutex)
	for &w in state.workers[1:] {
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	for &f in state.fibers {
		_fiber_delete(f.handle)
		virtual.arena_destroy(&f.scratch)
	}
	_fiber_delete(state.workers[0].scheduler)
	_fiber_to_thread()
	local_worker = nil
	delete(state.workers)
	delete(state.fibers)
	delete(state.free)
	delete(state.queue)
	delete(state.ready)
	state = {}
}

worker_count :: proc() -> int {
	return len(state.workers)
}

// run starts frame jobs and adds them to the counter. Frame jobs must finish before the frame ends, because
// the host reloads the game DLL only with no game code on any fiber stack.
run :: proc(jobs: []Job, counter: ^Counter) {
	sync.atomic_add(&state.frame_jobs.value, len(jobs))
	push(jobs, counter, false)
}

// run_background starts jobs that may continue across frames. They must run only host code, so a reload
// cannot unload code that a fiber is running. The GPU backend compiles pipelines this way.
run_background :: proc(jobs: []Job, counter: ^Counter) {
	push(jobs, counter, true)
}

// wait suspends the calling fiber until the counter is zero. It must be called from a job or the main fiber.
wait :: proc(counter: ^Counter) {
	if sync.atomic_load(&counter.value) == 0 {
		return
	}
	w := current_worker()
	assert(w != nil, "jobs: wait outside the job system")
	w.action = .Wait
	w.wait_for = counter
	_fiber_switch(w.scheduler)
}

// lock takes the mutex. If another fiber holds it, the calling fiber suspends until the holder hands it over.
lock :: proc(m: ^Mutex) {
	if _, ok := sync.atomic_compare_exchange_strong(&m.locked, false, true); ok {
		return
	}
	w := current_worker()
	assert(w != nil, "jobs: lock outside the job system")
	w.action = .Lock
	w.lock_for = m
	_fiber_switch(w.scheduler)
	// The unlocking fiber handed the mutex to this one, so it is held now.
}

// unlock releases the mutex, or hands it straight to the oldest waiting fiber.
unlock :: proc(m: ^Mutex) {
	sync.guard(&state.mutex)
	f := (^Fiber)(m.waiters)
	if f == nil {
		sync.atomic_store(&m.locked, false)
		return
	}
	m.waiters = f.next
	if m.waiters == nil {
		m.last = nil
	}
	make_ready(f)
}

// guard locks the mutex until the end of the enclosing scope: `if jobs.guard(&m) { ... }`.
@(deferred_in = unlock)
guard :: proc(m: ^Mutex) -> bool {
	lock(m)
	return true
}

// drain_frame waits for every frame job. It returns false if some frame jobs were still running, which means
// game code started jobs without waiting for them.
drain_frame :: proc() -> bool {
	drained := sync.atomic_load(&state.frame_jobs.value) == 0
	wait(&state.frame_jobs)
	return drained
}

@(private = "file")
push :: proc(jobs: []Job, counter: ^Counter, background: bool) {
	if len(jobs) == 0 {
		return
	}
	sync.atomic_add(&counter.value, len(jobs))
	sync.guard(&state.mutex)
	for job in jobs {
		append(&state.queue, Pending{job, counter, background})
	}
	if len(jobs) == 1 {
		sync.cond_signal(&state.cond)
	} else {
		sync.cond_broadcast(&state.cond)
	}
}

// A fiber can move to another thread at every wait, so the worker must be read again after each one.
// The call stops the compiler from reusing a thread-local address across a switch.
@(private = "file")
current_worker :: #force_no_inline proc() -> ^Worker {
	return local_worker
}

@(private = "file")
fiber_main :: proc "system" (param: rawptr) {
	f := (^Fiber)(param)
	context = state.context_base
	for {
		virtual.arena_free_all(&f.scratch)
		context.temp_allocator = virtual.arena_allocator(&f.scratch)
		f.job.procedure(f.job.data)
		// The frame count goes first, so a fiber that the job's counter resumes never sees a finished job as running.
		if !f.background {
			finish(&state.frame_jobs)
		}
		finish(f.counter)
		w := current_worker()
		w.action = .Finished
		_fiber_switch(w.scheduler)
	}
}

// finish counts down a finished job and resumes the counter's waiters when it reaches zero.
// A waiter that sees zero can return at once and free the counter, so the counter is not touched after it
// reaches zero: the waiter list is taken out first, and the count goes to zero with the last access.
// Counts go down only under the mutex, so the check for the last job is exact. run only adds.
@(private = "file")
finish :: proc(counter: ^Counter) {
	sync.guard(&state.mutex)
	waiters := (^Fiber)(counter.waiters)
	counter.waiters = nil
	if _, last := sync.atomic_compare_exchange_strong(&counter.value, 1, 0); !last {
		counter.waiters = waiters
		sync.atomic_sub(&counter.value, 1)
		return
	}
	for f := waiters; f != nil; {
		next := f.next
		make_ready(f)
		f = next
	}
}

// make_ready queues a resumed fiber. The main fiber resumes only on the main thread. The caller holds the mutex.
@(private = "file")
make_ready :: proc(f: ^Fiber) {
	f.next = nil
	if f == &state.main_fiber {
		state.main_ready = true
		sync.cond_broadcast(&state.cond)
		return
	}
	append(&state.ready, f)
	sync.cond_signal(&state.cond)
}

@(private = "file")
worker_main :: proc(data: rawptr) {
	w := (^Worker)(data)
	local_worker = w
	w.scheduler = _thread_to_fiber(nil)
	schedule(w, false)
	_fiber_to_thread()
}

@(private = "file")
main_scheduler :: proc "system" (param: rawptr) {
	context = state.context_base
	schedule(&state.workers[0], true)
}

// schedule runs fibers on one thread. On a worker it returns at shutdown. On the main thread it switches back
// to the main fiber when that is ready, and continues from there at the main fiber's next wait.
@(private = "file")
schedule :: proc(w: ^Worker, main: bool) {
	// The main thread first enters its scheduler from a waiting main fiber.
	after_switch(w)
	for {
		next: ^Fiber
		sync.lock(&state.mutex)
		for next == nil {
			switch {
			case main && state.main_ready:
				state.main_ready = false
				next = &state.main_fiber
			case !main && state.stopping:
				sync.unlock(&state.mutex)
				return
			case len(state.ready) > 0:
				next = pop(&state.ready)
			case state.queue_head < len(state.queue) && len(state.free) > 0:
				pending := state.queue[state.queue_head]
				state.queue_head += 1
				if state.queue_head == len(state.queue) {
					clear(&state.queue)
					state.queue_head = 0
				}
				next = pop(&state.free)
				next.job, next.counter, next.background = pending.job, pending.counter, pending.background
			case:
				sync.cond_wait(&state.cond, &state.mutex)
			}
		}
		// A wakeup that the main thread used for its main fiber may have been meant for queued work.
		if next == &state.main_fiber && (state.queue_head < len(state.queue) || len(state.ready) > 0) {
			sync.cond_signal(&state.cond)
		}
		sync.unlock(&state.mutex)

		w.current = next
		_fiber_switch(next.handle)
		after_switch(w)
	}
}

// after_switch carries out what the fiber that switched out asked for.
@(private = "file")
after_switch :: proc(w: ^Worker) {
	f := w.current
	action, counter, m := w.action, w.wait_for, w.lock_for
	w.current, w.action, w.wait_for, w.lock_for = nil, .None, nil, nil
	sync.guard(&state.mutex)
	switch action {
	case .None:
	case .Finished:
		append(&state.free, f)
	case .Wait:
		if sync.atomic_load(&counter.value) == 0 {
			make_ready(f)
		} else {
			f.next = (^Fiber)(counter.waiters)
			counter.waiters = f
		}
	case .Lock:
		// unlock runs under the scheduler mutex too, so the lock cannot be released between this check and the queueing.
		if _, ok := sync.atomic_compare_exchange_strong(&m.locked, false, true); ok {
			make_ready(f)
		} else {
			f.next = nil
			if m.last == nil {
				m.waiters = f
			} else {
				(^Fiber)(m.last).next = f
			}
			m.last = f
		}
	}
}

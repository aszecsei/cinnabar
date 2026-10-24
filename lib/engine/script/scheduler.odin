package script

import "core:c"
import "core:log"
import "core:slice"
import "core:time"

import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/ecs"

MAX_WAITERS :: 4096

// Wait_Kind is what a coroutine waits for. See docs/scripting.md#coroutines.
@(private)
Wait_Kind :: enum u8 {
	None,
	// wait_frames, and a plain coroutine.yield, which waits one frame.
	Frames,
	// wait, in world time.
	Time,
	// wait_realtime.
	Real_Time,
	// wait_until: a predicate that the scheduler calls each frame.
	Until,
	// wait_event: an event sent to an entity.
	Event,
}

@(private)
Wait :: struct {
	kind:      Wait_Kind,
	frame:     u64,
	time:      f64,
	// Registry references: the wait_until predicate, and the wait_event name.
	predicate: c.int,
	event:     c.int,
	entity:    ecs.Entity,
}

// Waiter is a thread that the scheduler runs: a script from spawn_script, or a behaviour's coroutine.
@(private)
Waiter :: struct {
	// A registry reference to the thread, and the thread itself, which the reference keeps alive.
	thread:  c.int,
	state:   ^luau.State,
	// The behaviour that started it, or the zero handle.
	owner:   Instance_Handle,
	wait:    Wait,
	// The order in which coroutines started, which breaks ties between coroutines that are due together.
	seq:     u64,
	live:    bool,
	// Set by stop while the thread runs. It is freed when it yields.
	stopped: bool,
	running: bool,
}

// protected_call calls the function below the top nargs values, and logs an error with a traceback. The watchdog's
// deadline is set if no outer call set one.
@(private)
protected_call :: proc(r: ^Runtime, L: ^luau.State, nargs, nresults: c.int) -> bool {
	function := luau.gettop(L) - nargs
	luau.getref(L, r.traceback)
	luau.insert(L, function)
	saved := r.bindings.deadline
	if saved == {} {
		r.bindings.deadline = time.tick_add(time.tick_now(), r.budget)
	}
	r.bindings.ctx = context
	status := luau.pcall(L, nargs, nresults, function)
	r.bindings.deadline = saved
	luau.remove(L, function)
	if status != .OK {
		log.errorf("script: %s", luau.toodinstring(L, -1))
		luau.pop(L, 1)
		return false
	}
	return true
}

// traceback_binding is the message handler of protected_call: it adds the stack to the error message.
@(private)
traceback_binding :: proc(L: ^luau.State) -> c.int {
	size: c.size_t
	message := luau.L_tolstring(L, 1, &size)
	luau.L_traceback(L, L, cstring(message), 1)
	return 1
}

// resume_state resumes a thread with the top nargs values of its stack, under the watchdog.
@(private)
resume_state :: proc(r: ^Runtime, co: ^luau.State, nargs: c.int) -> luau.Status {
	saved := r.bindings.deadline
	r.bindings.ctx = context
	r.bindings.deadline = time.tick_add(time.tick_now(), r.budget)
	status := luau.resume(co, r.L, nargs)
	r.bindings.deadline = saved
	return status
}

// add_waiter makes a thread the scheduler's. The thread is on top of L's stack, and stays there.
@(private)
add_waiter :: proc(r: ^Runtime, L: ^luau.State, owner: Instance_Handle) -> int {
	index := -1
	for w, i in r.waiters[:r.waiter_used] {
		if !w.live {
			index = i
			break
		}
	}
	if index < 0 {
		if r.waiter_used == MAX_WAITERS {
			raise(L, "too many coroutines")
		}
		index = r.waiter_used
		r.waiter_used += 1
	}
	luau.pushvalue(L, -1)
	r.waiter_seq += 1
	r.waiters[index] = {
		thread = luau.ref(L, -1),
		state  = luau.tothread(L, -2),
		owner  = owner,
		seq    = r.waiter_seq,
		live   = true,
	}
	luau.pop(L, 1)
	return index
}

// run_waiter resumes a waiter's thread with the top nargs values of its stack. When the thread yields, its next wait
// is the one that its wait call set, or the next frame.
@(private)
run_waiter :: proc(r: ^Runtime, index: int, nargs: c.int = 0) -> luau.Status {
	w := &r.waiters[index]
	saved_current, saved_pending := r.current_waiter, r.pending_wait
	r.current_waiter, r.pending_wait = index, {}
	w.running = true
	status := resume_state(r, w.state, nargs)
	w.running = false
	pending := r.pending_wait
	r.current_waiter, r.pending_wait = saved_current, saved_pending

	switch status {
	case .YIELD:
		luau.settop(w.state, 0)
		if w.stopped {
			release_wait(r, pending)
			free_waiter(r, index)
		} else {
			release_wait(r, w.wait)
			w.wait = pending.kind != .None ? pending : {kind = .Frames, frame = r.frame + 1}
		}
	case .OK:
		free_waiter(r, index)
	case .ERRRUN, .ERRSYNTAX, .ERRMEM, .ERRERR, .BREAK:
		log.errorf("script: %s\n%s", luau.toodinstring(w.state, -1), luau.debugtrace(w.state))
		free_waiter(r, index)
	}
	return status
}

@(private)
release_wait :: proc(r: ^Runtime, wait: Wait) {
	if wait.kind == .Until {
		luau.unref(r.L, wait.predicate)
	}
	if wait.kind == .Event {
		luau.unref(r.L, wait.event)
	}
}

@(private)
free_waiter :: proc(r: ^Runtime, index: int) {
	w := &r.waiters[index]
	if !w.live {
		return
	}
	release_wait(r, w.wait)
	luau.unref(r.L, w.thread)
	w^ = {}
}

// stop_waiter stops a thread. A thread that is running stops when it yields.
@(private)
stop_waiter :: proc(r: ^Runtime, index: int) {
	if r.waiters[index].running {
		r.waiters[index].stopped = true
	} else {
		free_waiter(r, index)
	}
}

// stop_owned stops every coroutine that an instance started.
@(private)
stop_owned :: proc(r: ^Runtime, owner: Instance_Handle) {
	for &w, i in r.waiters[:r.waiter_used] {
		if w.live && w.owner == owner {
			stop_waiter(r, i)
		}
	}
}

// stop_thread stops the waiter with this thread reference.
@(private)
stop_thread :: proc(r: ^Runtime, thread: c.int) {
	for &w, i in r.waiters[:r.waiter_used] {
		if w.live && w.thread == thread {
			stop_waiter(r, i)
		}
	}
}

// start_coroutine_binding is self:start_coroutine(fn, ...), like Unity's StartCoroutine. The coroutine runs until
// its first wait before start_coroutine returns it.
@(private)
start_coroutine_binding :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	i := check_instance(r, L, 1)
	if .Active not_in i.flags {
		raise(L, "a coroutine cannot start on an inactive entity")
	}
	luau.L_checktype(L, 2, .FUNCTION)
	top := luau.gettop(L)
	co := luau.newthread(L)
	for k in 2 ..= top {
		luau.xpush(L, co, k)
	}
	index := add_waiter(r, L, handle_of(r, i))
	run_waiter(r, index, top - 2)
	return 1
}

@(private)
stop_coroutine_binding :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	owner := handle_of(r, check_instance(r, L, 1))
	co := luau.tothread(L, 2)
	if co == nil {
		luau.L_typeerrorL(L, 2, "thread")
	}
	for &w, i in r.waiters[:r.waiter_used] {
		if w.live && w.state == co && w.owner == owner {
			stop_waiter(r, i)
		}
	}
	return 0
}

@(private)
register_waits :: proc(r: ^Runtime) {
	define(r, "wait", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		seconds := luau.L_optnumber(L, 1, 0)
		return set_wait(r, L, {kind = .Time, time = world_time(r) + seconds})
	})
	define(r, "wait_realtime", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		return set_wait(r, L, {kind = .Real_Time, time = r.platform.time_seconds() + luau.L_checknumber(L, 1)})
	})
	define(r, "wait_frames", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		n := max(1, u64(luau.L_optnumber(L, 1, 1)))
		return set_wait(r, L, {kind = .Frames, frame = r.frame + n})
	})
	define(r, "wait_until", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		luau.L_checktype(L, 1, .FUNCTION)
		check_waiting(r, L)
		luau.pushvalue(L, 1)
		return set_wait(r, L, {kind = .Until, predicate = luau.ref(L, -1)})
	})
	define(r, "wait_event", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		e := check_entity(L, 1)
		luau.L_checkstring(L, 2)
		check_waiting(r, L)
		luau.pushvalue(L, 2)
		return set_wait(r, L, {kind = .Event, entity = e, event = luau.ref(L, -1)})
	})
}

// check_waiting raises an error unless the running thread is one that the scheduler runs. A callback such as start
// runs outside of any coroutine, so it cannot wait.
@(private = "file")
check_waiting :: proc(r: ^Runtime, L: ^luau.State) {
	if r.current_waiter < 0 || r.waiters[r.current_waiter].state != L {
		raise(L, "wait works only in a coroutine that the engine runs: use self:start_coroutine")
	}
}

@(private = "file")
set_wait :: proc(r: ^Runtime, L: ^luau.State, wait: Wait) -> c.int {
	check_waiting(r, L)
	r.pending_wait = wait
	return script_host.YIELD
}

@(private)
world_time :: proc(r: ^Runtime) -> f64 {
	return r.world != nil ? time.duration_seconds(r.world.clock.time) : r.platform.time_seconds()
}

// run_coroutines resumes the coroutines that are due: by wake time, and then in the order they started.
@(private)
run_coroutines :: proc(r: ^Runtime) {
	Due :: struct {
		index: int,
		seq:   u64,
		key:   f64,
	}
	now, real_now := world_time(r), r.platform.time_seconds()
	due := make([dynamic]Due, frame(r))
	for &w, i in r.waiters[:r.waiter_used] {
		if !w.live || w.stopped || w.running {
			continue
		}
		switch w.wait.kind {
		case .None, .Event:
		case .Frames:
			if w.wait.frame <= r.frame {
				append(&due, Due{i, w.seq, 0})
			}
		case .Time:
			if w.wait.time <= now {
				append(&due, Due{i, w.seq, w.wait.time})
			}
		case .Real_Time:
			if w.wait.time <= real_now {
				append(&due, Due{i, w.seq, 0})
			}
		case .Until:
			luau.getref(r.L, w.wait.predicate)
			if !protected_call(r, r.L, 0, 1) {
				free_waiter(r, i)
				continue
			}
			if luau.toboolean(r.L, -1) {
				append(&due, Due{i, w.seq, 0})
			}
			luau.pop(r.L, 1)
		}
	}
	slice.sort_by(due[:], proc(a, b: Due) -> bool {return a.key < b.key || a.key == b.key && a.seq < b.seq})
	for d in due {
		w := &r.waiters[d.index]
		if w.live && w.seq == d.seq && !w.stopped {
			run_waiter(r, d.index)
		}
	}
}

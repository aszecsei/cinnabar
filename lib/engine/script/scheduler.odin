package script

import "core:c"
import "core:log"
import "core:slice"
import "core:time"

import "cinnabar:core/luau"
import script_host "cinnabar:core/script"
import "cinnabar:engine/ecs"

MAX_WAITERS :: 4096

// Wait is what a coroutine waits for, with what that wait needs, and nil before its first wait. See
// docs/scripting/behaviours.md#coroutines.
@(private)
Wait :: union {
	Wait_Frames,
	Wait_Time,
	Wait_Real_Time,
	Wait_Until,
	Wait_Event,
	Wait_Fixed,
}

// Wait_Frames is wait_frames, and a plain coroutine.yield, which waits one frame: the frame that it resumes in.
@(private)
Wait_Frames :: struct {
	frame: u64,
}

// Wait_Time is wait, in world time.
@(private)
Wait_Time :: struct {
	time: f64,
}

// Wait_Real_Time is wait_realtime.
@(private)
Wait_Real_Time :: struct {
	time: f64,
}

// Wait_Until is wait_until: a registry reference to the predicate that the scheduler calls each frame.
@(private)
Wait_Until :: struct {
	predicate: c.int,
}

// Wait_Event is wait_event: an event sent to an entity, with a registry reference to the event's name.
@(private)
Wait_Event :: struct {
	event:  c.int,
	entity: ecs.Entity,
}

// Wait_Fixed is wait_fixed: the end of the next fixed tick, which fixed_events resumes.
@(private)
Wait_Fixed :: struct {}

// Waiter_Status is where a waiter is. A Free slot is given out again. A Waiting waiter is resumed when its wait is
// over. A Running waiter's code runs: its thread, or its wait_until predicate. A Stopping waiter was stopped while it
// ran, and is freed when its code returns, so a stop never frees a slot under running code. become changes it.
@(private)
Waiter_Status :: enum u8 {
	Free,
	Waiting,
	Running,
	Stopping,
}

// Waiter_Id names a waiter by its index and the sequence number that add_waiter gave it. A freed index is given out
// again with a new number, so an old id finds nothing. The zero id finds nothing either.
@(private)
Waiter_Id :: struct {
	index: int,
	seq:   u64,
}

// Waiter_Owner is what started a waiter: a behaviour's start_coroutine, or spawn_script.
@(private)
Waiter_Owner :: union {
	Instance_Handle,
	Main_Script,
}

// Waiter is a thread that the scheduler runs: a script from spawn_script, or a behaviour's coroutine.
@(private)
Waiter :: struct {
	// A registry reference to the thread, and the thread itself, which the reference keeps alive.
	thread:  c.int,
	state:   ^luau.State,
	owner:   Waiter_Owner,
	wait:    Wait,
	// The order in which coroutines started, which breaks ties between coroutines that are due together.
	seq:     u64,
	status:  Waiter_Status,
}

// become moves a waiter to a status, and checks that the scheduler makes that change: a new waiter waits, a waiting one
// runs, a running one waits again or is stopped. free_waiter frees one.
@(private)
become :: proc(w: ^Waiter, to: Waiter_Status) {
	from := w.status
	allowed: bool
	switch to {
	case .Free:
		allowed = from != .Free
	case .Waiting:
		allowed = from == .Free || from == .Running
	case .Running:
		allowed = from == .Waiting
	case .Stopping:
		allowed = from == .Running
	}
	assert(allowed, "a waiter cannot make that change")
	w.status = to
}

// waiter_due is whether the waiter at index is still the one with seq, waiting to be resumed. A waiter that was freed,
// whose slot went to another, that is stopping or that runs is not.
@(private)
waiter_due :: proc(r: ^Runtime, index: int, seq: u64) -> bool {
	w := &r.waiters[index]
	return w.seq == seq && w.status == .Waiting
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
add_waiter :: proc(r: ^Runtime, L: ^luau.State, owner: Waiter_Owner) -> int {
	index := -1
	for w, i in r.waiters[:r.waiter_used] {
		if w.status == .Free {
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
	}
	become(&r.waiters[index], .Waiting)
	luau.pop(L, 1)
	return index
}

// run_waiter resumes a waiter's thread with the top nargs values of its stack. When the thread yields, its next wait
// is the one that its wait call set, or the next frame.
@(private)
run_waiter :: proc(r: ^Runtime, index: int, nargs: c.int = 0) -> luau.Status {
	w := &r.waiters[index]
	saved_current, saved_pending := r.current_waiter, r.pending_wait
	r.current_waiter, r.pending_wait = index, nil
	become(w, .Running)
	zone := begin_callback(r, waiter_class(r, w), .Coroutine)
	status := resume_state(r, w.state, nargs)
	end_callback(r, zone)
	pending := r.pending_wait
	r.current_waiter, r.pending_wait = saved_current, saved_pending

	switch status {
	case .YIELD:
		luau.settop(w.state, 0)
		if w.status == .Stopping {
			release_wait(r, pending)
			free_waiter(r, index)
		} else {
			release_wait(r, w.wait)
			w.wait = pending != nil ? pending : Wait_Frames{frame = r.frame + 1}
			become(w, .Waiting)
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
	#partial switch w in wait {
	case Wait_Until:
		luau.unref(r.L, w.predicate)
	case Wait_Event:
		luau.unref(r.L, w.event)
	}
}

@(private)
free_waiter :: proc(r: ^Runtime, index: int) {
	w := &r.waiters[index]
	if w.status == .Free {
		return
	}
	// A main script ends with its thread, however the thread ends.
	if script, is_main := w.owner.(Main_Script); is_main {
		end_main(r, script, {index, w.seq})
	}
	release_wait(r, w.wait)
	luau.unref(r.L, w.thread)
	become(w, .Free)
	w^ = {}
}

// stop_waiter stops a waiter. One whose code runs, its thread or its predicate, stops when that code returns.
@(private)
stop_waiter :: proc(r: ^Runtime, index: int) {
	w := &r.waiters[index]
	switch w.status {
	case .Free, .Stopping:
	case .Running:
		become(w, .Stopping)
	case .Waiting:
		free_waiter(r, index)
	}
}

// stop_owned stops every coroutine that an instance started.
@(private)
stop_owned :: proc(r: ^Runtime, owner: Instance_Handle) {
	for &w, i in r.waiters[:r.waiter_used] {
		if handle, ok := w.owner.(Instance_Handle); ok && w.status != .Free && handle == owner {
			stop_waiter(r, i)
		}
	}
}

// stop_waiter_id stops the waiter that id names, if it still lives.
@(private)
stop_waiter_id :: proc(r: ^Runtime, id: Waiter_Id) {
	if id.index < 0 || id.index >= r.waiter_used {
		return
	}
	w := &r.waiters[id.index]
	if w.status != .Free && w.seq == id.seq {
		stop_waiter(r, id.index)
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
		if handle, ok := w.owner.(Instance_Handle); ok && w.status != .Free && w.state == co && handle == owner {
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
		return set_wait(r, L, Wait_Time{time = world_time(r) + seconds})
	})
	define(r, "wait_realtime", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		return set_wait(r, L, Wait_Real_Time{time = r.platform.time_seconds() + luau.L_checknumber(L, 1)})
	})
	define(r, "wait_frames", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		n := max(1, u64(luau.L_optnumber(L, 1, 1)))
		return set_wait(r, L, Wait_Frames{frame = r.frame + n})
	})
	define(r, "wait_until", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		luau.L_checktype(L, 1, .FUNCTION)
		check_waiting(r, L)
		luau.pushvalue(L, 1)
		return set_wait(r, L, Wait_Until{predicate = luau.ref(L, -1)})
	})
	define(r, "wait_fixed", proc(L: ^luau.State) -> c.int {
		return set_wait(runtime_of(L), L, Wait_Fixed{})
	})
	define(r, "wait_event", proc(L: ^luau.State) -> c.int {
		r := runtime_of(L)
		e := check_entity(L, 1)
		luau.L_checkstring(L, 2)
		check_waiting(r, L)
		luau.pushvalue(L, 2)
		return set_wait(r, L, Wait_Event{entity = e, event = luau.ref(L, -1)})
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
	// A coroutine that a predicate starts during the scan waits for the next frame's, whichever slot it takes.
	last_seq := r.waiter_seq
	for &w, i in r.waiters[:r.waiter_used] {
		if w.status != .Waiting || w.seq > last_seq {
			continue
		}
		switch wait in w.wait {
		case Wait_Event, Wait_Fixed:
		case Wait_Frames:
			if wait.frame <= r.frame {
				append(&due, Due{i, w.seq, 0})
			}
		case Wait_Time:
			if wait.time <= now {
				append(&due, Due{i, w.seq, wait.time})
			}
		case Wait_Real_Time:
			if wait.time <= real_now {
				append(&due, Due{i, w.seq, 0})
			}
		case Wait_Until:
			// The predicate is the waiter's code: while it runs, a stop of the waiter waits for it to return, so its
			// slot is not freed and given to a coroutine that the predicate starts.
			luau.getref(r.L, wait.predicate)
			become(&w, .Running)
			zone := begin_callback(r, waiter_class(r, &w), .Coroutine)
			called := protected_call(r, r.L, 0, 1)
			end_callback(r, zone)
			// A predicate that failed, or that stopped its own coroutine, ends the waiter.
			if !called || w.status == .Stopping {
				if called {
					luau.pop(r.L, 1)
				}
				free_waiter(r, i)
				continue
			}
			become(&w, .Waiting)
			if luau.toboolean(r.L, -1) {
				append(&due, Due{i, w.seq, 0})
			}
			luau.pop(r.L, 1)
		case:
		}
	}
	slice.sort_by(due[:], proc(a, b: Due) -> bool {return a.key < b.key || a.key == b.key && a.seq < b.seq})
	for d in due {
		if waiter_due(r, d.index, d.seq) {
			run_waiter(r, d.index)
		}
	}
}

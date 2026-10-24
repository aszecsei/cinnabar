// Package script is the game side of scripting: the VM's bindings and globals, and running scripts on their own
// threads. The VM and its heap belong to the host (see cinnabar:core/script, package script_host). See docs/scripting.md.
package script

import "core:c"
import "core:log"
import "core:strings"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import script_host "cinnabar:core/script"

// The watchdog's limit for one resume (see docs/scripting.md#watchdog).
DEFAULT_BUDGET :: 100 * time.Millisecond
// The incremental collector's work per frame.
GC_STEP_KB :: 64

// Runtime is the script VM of one Game_State. It must not move after init: the VM keeps a pointer to its bindings.
Runtime :: struct {
	platform: ^core.Platform_API,
	bindings: script_host.Bindings,
	L:        ^luau.State,
	budget:   time.Duration,
}

// runtime_of is the Runtime of a VM, for bindings.
runtime_of :: proc "contextless" (L: ^luau.State) -> ^Runtime {
	return container_of((^script_host.Bindings)(luau.callbacks(L).userdata), Runtime, "bindings")
}

// Register_Proc defines the game's bindings with define. init and reload both call it, so each binding is defined
// in one place.
Register_Proc :: #type proc(r: ^Runtime)

// Thread is a script coroutine that the VM keeps alive until release. It is a registry reference, so it stays valid
// across code reloads.
Thread :: distinct c.int

Resume_Result :: enum u8 {
	Yielded,
	Finished,
	Failed,
}

// init opens the VM, defines the engine's and the game's bindings, and sandboxes the globals.
init :: proc(r: ^Runtime, platform: ^core.Platform_API, register: Register_Proc) -> bool {
	r.platform = platform
	r.budget = DEFAULT_BUDGET
	r.bindings.ctx = context
	r.L = platform.script_open(&r.bindings)
	if r.L == nil {
		log.error("script: cannot open the VM")
		return false
	}
	register_engine(r)
	register(r)
	luau.L_sandbox(r.L)
	return true
}

// reload registers every binding again after a code reload. Closures in the VM find the new procedures by their
// binding IDs.
reload :: proc(r: ^Runtime, platform: ^core.Platform_API, register: Register_Proc) {
	r.platform = platform
	r.bindings.ctx = context
	script_host.clear(&r.bindings)
	register_engine(r)
	register(r)
}

destroy :: proc(r: ^Runtime) {
	if r.L != nil {
		r.platform.script_close(r.L)
	}
	r.L = nil
}

// define registers a binding and sets the global with its name: "print" sets a global function, and "Debug.log" the
// field log of the global table Debug. The globals are read-only to scripts, so a code reload can define new
// bindings, but scripts cannot replace them.
define :: proc(r: ^Runtime, name: string, procedure: script_host.Binding_Proc) {
	script_host.register(&r.bindings, name, procedure)
	L := r.L
	luau.pushvalue(L, luau.GLOBALSINDEX)
	field := name
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		library := cstring_of(r, name[:dot])
		field = name[dot + 1:]
		if luau.rawgetfield(L, -1, library) != .TABLE {
			// A library that a code reload adds is read-only like the others.
			luau.pop(L, 1)
			luau.newtable(L)
			luau.setreadonly(L, -1, luau.getreadonly(L, -2))
			luau.pushvalue(L, -1)
			set_field(L, -3, library)
		}
		luau.remove(L, -2)
	}
	r.platform.script_push_binding(L, name)
	set_field(L, -2, cstring_of(r, field))
	luau.pop(L, 1)
}

// set_field sets t[k] to the value on top of the stack, and pops it. It works on a read-only table too.
@(private = "file")
set_field :: proc(L: ^luau.State, index: c.int, k: cstring) {
	t := luau.absindex(L, index)
	readonly := luau.getreadonly(L, t)
	luau.setreadonly(L, t, false)
	luau.rawsetfield(L, t, k)
	luau.setreadonly(L, t, readonly)
}

@(private = "file")
cstring_of :: proc(r: ^Runtime, s: string) -> cstring {
	return strings.clone_to_cstring(s, r.platform.frame_allocator)
}

// spawn compiles source and starts it on a new sandboxed thread, which runs until its first yield. chunkname names
// the script in errors and tracebacks.
spawn :: proc(r: ^Runtime, chunkname, source: string) -> (thread: Thread, ok: bool) {
	L := r.L
	co := luau.newthread(L)
	thread = Thread(luau.ref(L, -1))
	luau.pop(L, 1)
	luau.L_sandboxthread(co)

	size: c.size_t
	bytecode := luau.compile(raw_data(source), c.size_t(len(source)), nil, &size)
	status := luau.load(co, cstring_of(r, chunkname), bytecode, size, 0)
	luau.free_bytecode(bytecode)
	if status != .OK {
		log.errorf("script: %s", luau.toodinstring(co, -1))
		release(r, thread)
		return 0, false
	}
	if resume(r, thread) == .Failed {
		release(r, thread)
		return 0, false
	}
	return thread, true
}

// resume runs a thread until it yields, returns or fails. A failure logs the error with a traceback. The watchdog
// stops a thread that runs longer than the runtime's budget.
resume :: proc(r: ^Runtime, thread: Thread) -> Resume_Result {
	L := r.L
	luau.getref(L, c.int(thread))
	co := luau.tothread(L, -1)
	luau.pop(L, 1)
	if co == nil || luau.status(co) != .OK && luau.status(co) != .YIELD {
		return .Failed
	}
	r.bindings.ctx = context
	r.bindings.deadline = time.tick_add(time.tick_now(), r.budget)
	status := luau.resume(co, L, 0)
	r.bindings.deadline = {}
	switch status {
	case .YIELD:
		luau.settop(co, 0)
		return .Yielded
	case .OK:
		luau.settop(co, 0)
		return .Finished
	case .ERRRUN, .ERRSYNTAX, .ERRMEM, .ERRERR, .BREAK:
	}
	log.errorf("script: %s\n%s", luau.toodinstring(co, -1), luau.debugtrace(co))
	return .Failed
}

// release lets the VM collect a thread.
release :: proc(r: ^Runtime, thread: Thread) {
	luau.unref(r.L, c.int(thread))
}

// step runs the incremental collector for one frame's budget. Run it once per script phase.
step :: proc(r: ^Runtime) {
	luau.gc(r.L, .STEP, GC_STEP_KB)
}

@(private = "file")
register_engine :: proc(r: ^Runtime) {
	define(r, "Debug.log", proc(L: ^luau.State) -> c.int {return log_binding(L, .Info)})
	define(r, "Debug.warn", proc(L: ^luau.State) -> c.int {return log_binding(L, .Warning)})
	define(r, "Debug.error", proc(L: ^luau.State) -> c.int {return log_binding(L, .Error)})
}

// log_binding logs its arguments, separated by spaces, with the script's location.
@(private = "file")
log_binding :: proc(L: ^luau.State, level: log.Level) -> c.int {
	n := luau.gettop(L)
	luau.L_where(L, 1)
	builder := strings.builder_make(runtime_of(L).platform.frame_allocator)
	strings.write_string(&builder, luau.toodinstring(L, -1))
	for i in 1 ..= n {
		if i > 1 {
			strings.write_byte(&builder, ' ')
		}
		size: c.size_t
		text := luau.L_tolstring(L, i, &size)
		strings.write_string(&builder, string(text[:size]))
		luau.pop(L, 1)
	}
	log.log(level, strings.to_string(builder))
	return 0
}

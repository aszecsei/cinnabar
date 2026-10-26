// Package script is the game side of scripting: the VM's bindings and globals, and running scripts on their own
// threads. The VM and its heap belong to the host (see cinnabar:core/script, package script_host). See docs/scripting/README.md.
package script

import "core:c"
import "core:log"
import "core:strings"
import "core:time"

import "cinnabar:core"
import "cinnabar:core/luau"
import "cinnabar:core/profile"
import script_host "cinnabar:core/script"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The watchdog's limit for one resume (see docs/scripting/embedding.md#watchdog).
DEFAULT_BUDGET :: 100 * time.Millisecond
// The incremental collector's work per frame.
GC_STEP_KB :: 64

// Runtime is the script VM of one Game_State. It must not move after init: the VM keeps a pointer to its bindings.
Runtime :: struct {
	platform:     ^core.Platform_API,
	bindings:     script_host.Bindings,
	L:            ^luau.State,
	budget:       time.Duration,
	// The world and the assets live in Game_State too, so the pointers stay valid across reloads. Tests may leave
	// them nil.
	world:            ^ecs.World,
	assets:           ^asset.Assets,
	// A registry reference to the shared global table, which module environments read through to.
	globals:          c.int,
	modules:          [MAX_MODULES]Module,
	module_count:     int,
	// Registrations, which reload clears: the methods of each engine type, and the exposed components.
	light_methods:    [Light_Tag]Type_Methods,
	userdata_methods: [Userdata_Tag]Type_Methods,
	defined:          [MAX_DEFINED]Defined,
	defined_count:    int,
	defining_engine:  bool,
	exposed:          [MAX_EXPOSED]Exposed,
	exposed_count:    int,
	fields:           [MAX_FIELDS]Field,
	field_count:      int,
	// Registry references to the Time and Input tables, which begin_phase updates.
	time_table:       c.int,
	input_table:      c.int,
	input:            core.Input,
	frame:            u64,
	// The script phase's structural changes, in frame memory. See end_phase.
	commands:         ecs.Commands,
	// Behaviours and the scheduler. See behaviour.odin and scheduler.odin.
	instances:        [MAX_INSTANCES]Instance,
	instance_used:    int,
	// The memory category that set_category last gave a thread.
	category:         c.int,
	// While set, no script code runs for the world's changes (see set_quiet).
	quiet:            bool,
	waiters:          [MAX_WAITERS]Waiter,
	waiter_used:      int,
	waiter_seq:       u64,
	// The waiter that is running, or -1, and the wait that its wait call asked for.
	current_waiter:   int,
	pending_wait:     Wait,
	// Registry references: the event queue, and protected_call's message handler.
	events:           c.int,
	traceback:        c.int,
	// The VM has a code generator, so modules with the Native flag run as machine code.
	native:           bool,
	// The host calls the direct access handlers (see direct.odin).
	direct_access:    bool,
	// The profiler's depth inside the callback that runs, below which Profile.finish closes nothing (see profile.odin).
	profile_base:      int,
	warned_unbalanced: bool,
	coroutine_name:    profile.Name,
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

// init opens the VM, defines the engine's and the game's bindings, and sandboxes the globals. Scripts see the world
// and load from the assets. Register the world's components before init, because the game's Register_Proc exposes
// them.
init :: proc(r: ^Runtime, platform: ^core.Platform_API, world: ^ecs.World, assets: ^asset.Assets, register: Register_Proc) -> bool {
	r.platform = platform
	r.world = world
	r.assets = assets
	r.budget = DEFAULT_BUDGET
	r.module_count = 0
	r.instance_used = 0
	r.waiter_used = 0
	r.current_waiter = -1
	r.bindings.ctx = context
	r.L = platform.script_open(&r.bindings)
	if r.L == nil {
		log.error("script: cannot open the VM")
		return false
	}
	// The code generator lives in luau.dll, so its machine code survives a code reload.
	r.native = bool(luau.codegen_supported())
	if r.native {
		luau.codegen_create(r.L)
	}
	// Values in the VM that a code reload keeps: the metatables hold dispatcher closures, which stay valid.
	create_metatables(r)
	enable_direct(r)
	create_frame_values(r)
	create_math_values(r)
	r.platform.script_push_binding(r.L, "Script.traceback")
	r.traceback = luau.ref(r.L, -1)
	luau.pop(r.L, 1)
	luau.newtable(r.L)
	r.events = luau.ref(r.L, -1)
	luau.pop(r.L, 1)
	register_engine(r)
	register(r)
	run_prelude(r)
	luau.L_sandbox(r.L)
	if world != nil {
		ecs.watch(world, {BEHAVIOURS_ID}, activity = true)
	}
	luau.pushvalue(r.L, luau.GLOBALSINDEX)
	r.globals = luau.ref(r.L, -1)
	luau.pop(r.L, 1)
	return true
}

// reload registers every binding again after a code reload. Closures in the VM find the new procedures by their
// binding IDs.
reload :: proc(r: ^Runtime, platform: ^core.Platform_API, register: Register_Proc) {
	r.platform = platform
	r.bindings.ctx = context
	script_host.clear(&r.bindings)
	r.light_methods = {}
	r.userdata_methods = {}
	r.exposed_count = 0
	r.field_count = 0
	r.defined_count = 0
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
// bindings, but scripts cannot replace them. signature is the binding's Luau type for the definition file, such as
// "(count: number) -> string". Without one, it takes and returns anything.
define :: proc(r: ^Runtime, name: string, procedure: script_host.Binding_Proc, signature := "") {
	script_host.register(&r.bindings, name, procedure)
	record_defined(r, name, signature)
	r.platform.script_push_binding(r.L, name)
	set_path(r, name)
}

// register_binding registers a binding without setting a global, for metamethods and the prelude's natives.
@(private)
register_binding :: proc(r: ^Runtime, name: string, procedure: script_host.Binding_Proc) {
	script_host.register(&r.bindings, name, procedure)
}

// set_path pops the value on top of the stack into the global with this name: "Key" or "Quaternion.identity". It
// creates a missing library table, and works after the sandbox made the globals read-only.
@(private)
set_path :: proc(r: ^Runtime, name: string) {
	L := r.L
	value := luau.gettop(L)
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
	luau.pushvalue(L, value)
	set_field(L, -2, cstring_of(r, field))
	luau.settop(L, value - 1)
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

@(private)
cstring_of :: proc(r: ^Runtime, s: string) -> cstring {
	return strings.clone_to_cstring(s, r.platform.frame_allocator)
}

// spawn_source compiles source and starts it on a new sandboxed thread, which runs until its first yield. chunkname
// names the script in errors and tracebacks. Source scripts cannot require: use spawn_script for script assets.
spawn_source :: proc(r: ^Runtime, chunkname, source: string) -> (thread: Thread, ok: bool) {
	L := r.L
	co := luau.newthread(L)
	thread = Thread(luau.ref(L, -1))
	luau.pop(L, 1)
	luau.L_sandboxthread(co)

	bytecode := compile(source)
	status := luau.load(co, cstring_of(r, chunkname), raw_data(bytecode), c.size_t(len(bytecode)), 0)
	luau.free_bytecode(raw_data(bytecode))
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

// compile compiles source with the settings that the engine's globals need. Release the result with
// luau.free_bytecode. A failed compilation gives bytecode that luau.load reports as an error.
compile :: proc(source: string) -> []byte {
	mutable_globals := format.script_mutable_globals()
	options := luau.Compile_Options {
		optimizationLevel = 1,
		debugLevel        = 2,
		mutableGlobals    = &mutable_globals[0],
	}
	size: c.size_t
	bytecode := luau.compile(raw_data(source), c.size_t(len(source)), &options, &size)
	return bytecode[:size]
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

// METAMETHODS are the bindings in the engine types' metatables. Each is registered by name, like any binding.
@(private = "file")
METAMETHODS :: [?]struct {
	tag:       Userdata_Tag,
	event:     cstring,
	binding:   string,
} {
	{.World_Position, "__add", "WorldPosition.__add"},
	{.World_Position, "__sub", "WorldPosition.__sub"},
	{.World_Position, "__eq", "WorldPosition.__eq"},
	{.World_Position, "__tostring", "WorldPosition.__tostring"},
	{.World_Position, "__namecall", "Userdata.__namecall"},
	{.Quaternion, "__mul", "Quaternion.__mul"},
	{.Quaternion, "__eq", "Quaternion.__eq"},
	{.Quaternion, "__index", "Quaternion.__index"},
	{.Quaternion, "__tostring", "Quaternion.__tostring"},
	{.Quaternion, "__namecall", "Userdata.__namecall"},
	{.Component_Ref, "__index", "ComponentRef.__index"},
	{.Component_Ref, "__newindex", "ComponentRef.__newindex"},
	{.Component_Ref, "__eq", "ComponentRef.__eq"},
	{.Component_Ref, "__tostring", "ComponentRef.__tostring"},
}

@(private = "file")
USERDATA_NAMES := [Userdata_Tag]cstring {
	.None           = "userdata",
	.World_Position = "WorldPosition",
	.Quaternion     = "Quaternion",
	.Component_Ref  = "ComponentRef",
}

// create_metatables makes the metatables of the engine's types. Luau sets each only once, so init makes them, and a
// code reload keeps them.
@(private = "file")
create_metatables :: proc(r: ^Runtime) {
	L := r.L
	luau.newtable(L)
	for event in ([?][2]cstring{{"__index", "Light.__index"}, {"__namecall", "Light.__namecall"}, {"__tostring", "Light.__tostring"}}) {
		r.platform.script_push_binding(L, string(event[1]))
		luau.rawsetfield(L, -2, event[0])
	}
	luau.setreadonly(L, -1, true)
	luau.pushlightuserdata(L, nil)
	luau.pushvalue(L, -2)
	luau.setmetatable(L, -2)
	luau.pop(L, 2)
	luau.setlightuserdataname(L, c.int(Light_Tag.Entity), "Entity")
	luau.setlightuserdataname(L, c.int(Light_Tag.Component_Type), "ComponentType")

	for tag in Userdata_Tag {
		if tag == .None {
			continue
		}
		luau.newtable(L)
		luau.pushstring(L, USERDATA_NAMES[tag])
		luau.rawsetfield(L, -2, "__type")
		for m in METAMETHODS {
			if m.tag == tag {
				r.platform.script_push_binding(L, m.binding)
				luau.rawsetfield(L, -2, m.event)
			}
		}
		luau.setreadonly(L, -1, true)
		luau.setuserdatametatable(L, c.int(tag))
	}
}

@(private = "file")
register_engine :: proc(r: ^Runtime) {
	r.defining_engine = true
	defer r.defining_engine = false
	bind :: proc(r: ^Runtime, name: string, procedure: script_host.Binding_Proc) {
		script_host.register(&r.bindings, name, procedure)
	}
	bind(r, "Light.__index", light_index)
	bind(r, "Light.__namecall", light_namecall)
	bind(r, "Light.__tostring", light_tostring)
	bind(r, "Userdata.__namecall", userdata_namecall)
	bind(r, "WorldPosition.__add", position_add)
	bind(r, "WorldPosition.__sub", position_sub)
	bind(r, "WorldPosition.__eq", position_eq)
	bind(r, "WorldPosition.__tostring", position_tostring)
	bind(r, "Quaternion.__mul", quaternion_mul)
	bind(r, "Quaternion.__eq", quaternion_eq)
	bind(r, "Quaternion.__index", quaternion_index)
	bind(r, "Quaternion.__tostring", quaternion_tostring)
	bind(r, "ComponentRef.__index", ref_index)
	bind(r, "ComponentRef.__newindex", ref_newindex)
	bind(r, "ComponentRef.__eq", ref_eq)
	bind(r, "ComponentRef.__tostring", ref_tostring)
	bind(r, "Script.traceback", traceback_binding)
	register_behaviours(r)
	register_waits(r)
	register_direct(r)

	define(r, "require", require_binding)
	define(r, "Debug.log", proc(L: ^luau.State) -> c.int {return log_binding(L, .Info)})
	define(r, "Debug.warn", proc(L: ^luau.State) -> c.int {return log_binding(L, .Warning)})
	define(r, "Debug.error", proc(L: ^luau.State) -> c.int {return log_binding(L, .Error)})
	register_frame(r)
	register_math(r)
	register_profile(r)
	if r.world != nil {
		register_world(r)
	}
}

// userdata_namecall is the __namecall of the engine's full userdata.
@(private)
userdata_namecall :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	atom: c.int
	name := string(luau.namecallatom(L, &atom))
	tag := Userdata_Tag(luau.userdatatag(L, 1))
	if tag < min(Userdata_Tag) || tag > max(Userdata_Tag) {
		raise(L, "this value has no methods")
	}
	procedure := find_method(&r.userdata_methods[tag], atom, name)
	if procedure == nil {
		raise(L, strings.concatenate({string(USERDATA_NAMES[tag]), " has no method ", name}, frame(r)))
	}
	return procedure(L)
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

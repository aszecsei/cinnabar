package script

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"

import "cinnabar:core/luau"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

MAX_MODULES :: 256

// Module is a script asset that the runtime has run. See docs/scripting/tooling-and-hot-reload.md#modules-and-require.
@(private)
Module :: struct {
	guid:   format.Guid,
	handle: asset.Handle,
	state:  Module_State,
	// A registry reference to the module's result, once it is Loaded.
	result: c.int,
	// For a Main module: the registry reference of its thread, which the scheduler runs.
	thread: c.int,
}

// Main_Script is a script that spawn_script started. It stays valid when a script hot reload restarts the script.
Main_Script :: distinct u32

@(private)
Module_State :: enum u8 {
	Unloaded,
	// Its top level is running, so another require of it is a cycle.
	Loading,
	Loaded,
	// It runs as a thread from spawn_script, and has no result to require.
	Main,
}

// spawn_script starts a script asset on a new sandboxed thread, which runs until its first wait. Then the scheduler
// runs it, like a coroutine: coroutine.yield waits one frame. Its requires load the modules that the cooker
// resolved. stop ends it.
spawn_script :: proc(r: ^Runtime, guid: format.Guid) -> (script: Main_Script, ok: bool) {
	m := module_for(r, guid)
	if m == nil {
		return
	}
	if m.state != .Unloaded {
		log.errorf("script: %s already runs", guid_text(r, guid))
		return
	}
	if !start_main(r, m) {
		return
	}
	return Main_Script(module_index(r, m) + 1), true
}

// stop ends a script that spawn_script started.
stop :: proc(r: ^Runtime, script: Main_Script) {
	if int(script) < 1 || int(script) > r.module_count {
		return
	}
	m := &r.modules[script - 1]
	if m.state == .Main {
		stop_thread(r, m.thread)
	}
}

// start_main runs a Main module's top level on a new sandboxed thread, until its first wait.
@(private = "file")
start_main :: proc(r: ^Runtime, m: ^Module) -> bool {
	bytecode, chunkname, native := load_module_asset(r, m) or_return
	L := r.L
	co := luau.newthread(L)
	luau.L_sandboxthread(co)
	// The main script's thread allocates in its module's category, for as long as it runs.
	luau.setmemcat(co, category_of(module_index(r, m)))
	if luau.load(co, chunkname, raw_data(bytecode), c.size_t(len(bytecode)), 0) != .OK {
		log.errorf("script: %s", luau.toodinstring(co, -1))
		luau.pop(L, 1)
		return false
	}
	compile_native(r, co, native)
	m.state = .Main
	index := add_waiter(r, L, {})
	luau.pop(L, 1)
	m.thread = r.waiters[index].thread
	switch run_waiter(r, index) {
	case .OK, .YIELD:
		return true
	case .ERRRUN, .ERRSYNTAX, .ERRMEM, .ERRERR, .BREAK:
	}
	return false
}

@(private)
module_index :: proc(r: ^Runtime, m: ^Module) -> int {
	return int((uintptr(m) - uintptr(&r.modules[0])) / size_of(Module))
}

// reload_changed reloads the modules whose blobs the asset runtime swapped: pass it asset.poll's result, at the end of
// the frame, when no script runs. See docs/scripting/tooling-and-hot-reload.md#script-hot-reload.
reload_changed :: proc(r: ^Runtime, changed: []asset.Handle) {
	// Modules first, so a main script that restarts already requires their new versions.
	for main in ([2]bool{false, true}) {
		for h in changed {
			for &m in r.modules[:r.module_count] {
				if m.handle == h && (m.state == .Main) == main {
					reload_module(r, &m)
				}
			}
		}
	}
}

// reload_module runs a module's new version. A required module's table is patched in place, so every holder of it
// sees the new code. A main script restarts. If the new version fails, the old one stays.
@(private = "file")
reload_module :: proc(r: ^Runtime, m: ^Module) {
	switch m.state {
	case .Unloaded, .Loading:
		// It loads the new version when it is next required.
		return
	case .Main:
		stop_thread(r, m.thread)
		m.state = .Unloaded
		if start_main(r, m) {
			log.infof("script: restarted %s", module_name(r, m))
		}
		return
	case .Loaded:
	}
	L := r.L
	top := luau.gettop(L)
	defer luau.settop(L, top)
	bytecode, chunkname, native, ok := load_module_asset(r, m)
	if !ok {
		return
	}
	luau.newtable(L)
	luau.newtable(L)
	luau.getref(L, r.globals)
	luau.setfield(L, -2, "__index")
	luau.setreadonly(L, -1, true)
	luau.setmetatable(L, -2)
	luau.setsafeenv(L, -1, true)
	env := luau.gettop(L)
	if luau.load(L, chunkname, raw_data(bytecode), c.size_t(len(bytecode)), env) != .OK {
		log.errorf("script: %s keeps its old version: %s", module_name(r, m), luau.toodinstring(L, -1))
		return
	}
	luau.remove(L, env)
	compile_native(r, L, native)
	m.state = .Loading
	previous := set_category(r, L, category_of(module_index(r, m)))
	ran := protected_call(r, L, 0, 1)
	set_category(r, L, previous)
	m.state = .Loaded
	if !ran {
		log.errorf("script: %s keeps its old version", module_name(r, m))
		return
	}
	luau.getref(L, m.result)
	if !luau.istable(L, -1) || !luau.istable(L, -2) {
		// Nothing can be patched: the cache gets the new value, and modules that required the old one keep it.
		log.warnf("script: %s does not return a table, so the modules that required it keep the old value", module_name(r, m))
		luau.pop(L, 1)
		luau.unref(L, m.result)
		m.result = luau.ref(L, -1)
		return
	}
	patch_module(r, L, luau.gettop(L), luau.gettop(L) - 1)
	log.infof("script: reloaded %s", module_name(r, m))
}

// patch_module makes the old table at old match the new table at new: every key of the new one, and none that the new
// one lacks. A behaviour class keeps its own __index and __newindex, which find the patched methods in it. Its
// instances get the defaults of new fields, and then on_reload.
@(private = "file")
patch_module :: proc(r: ^Runtime, L: ^luau.State, old, new: c.int) {
	is_class := is_class(L, old) && is_class(L, new)
	keep :: proc(L: ^luau.State, is_class: bool) -> bool {
		key, _ := key_atom(L, -1)
		return is_class && luau.type(L, -1) == .STRING && (key == "__index" || key == "__newindex")
	}
	readonly := luau.getreadonly(L, old)
	luau.setreadonly(L, old, false)
	defer luau.setreadonly(L, old, readonly)

	// The class's old fields, to find the new ones.
	old_fields: c.int = 0
	if is_class {
		luau.rawgetfield(L, old, "__fields")
		old_fields = luau.gettop(L)
	}

	// Remove the keys that the new version lacks. Clearing a field during next is allowed.
	luau.pushnil(L)
	for luau.next(L, old) {
		luau.pop(L, 1)
		kept := keep(L, is_class)
		luau.pushvalue(L, -1)
		missing := luau.rawget(L, new) == .NIL
		luau.pop(L, 1)
		if missing && !kept {
			luau.pushvalue(L, -1)
			luau.pushnil(L)
			luau.rawset(L, old)
		}
	}
	luau.pushnil(L)
	for luau.next(L, new) {
		luau.pushvalue(L, -2)
		if keep(L, is_class) {
			luau.pop(L, 2)
			continue
		}
		luau.insert(L, -2)
		luau.rawset(L, old)
	}
	if !is_class {
		return
	}

	luau.rawgetfield(L, old, "__fields")
	fields := luau.gettop(L)
	updates := luau.rawgetfield(L, old, "update") == .FUNCTION
	luau.pop(L, 1)
	fixed_updates := luau.rawgetfield(L, old, "fixed_update") == .FUNCTION
	luau.pop(L, 1)
	for &i, index in r.instances[:r.instance_used] {
		if .Live not_in i.flags {
			continue
		}
		luau.getref(L, i.table)
		instance := luau.gettop(L)
		luau.getmetatable(L, instance)
		same := luau.rawequal(L, -1, old)
		luau.pop(L, 1)
		if !same {
			luau.pop(L, 1)
			continue
		}
		luau.pushnil(L)
		for luau.next(L, fields) {
			luau.pushvalue(L, -2)
			is_new := luau.rawget(L, old_fields) == .NIL
			luau.pop(L, 1)
			luau.pushvalue(L, -2)
			unset := luau.rawget(L, instance) == .NIL
			luau.pop(L, 1)
			if is_new && unset {
				luau.pushvalue(L, -2)
				luau.rawgetfield(L, -2, "default")
				luau.rawset(L, instance)
			}
			luau.pop(L, 1)
		}
		luau.pop(L, 1)
		if updates {
			i.flags += {.Updates}
		} else {
			i.flags -= {.Updates}
		}
		if fixed_updates {
			i.flags += {.Fixed_Updates}
		} else {
			i.flags -= {.Fixed_Updates}
		}
		call_method(r, {u32(index), i.generation}, "on_reload")
	}
}

// require_binding is the global require. It finds the calling module by its chunk name, and loads the module that
// the cooker resolved the path to. A module runs once, and later requires get its result.
@(private)
require_binding :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	path := checkodinstring(L, 1)
	// The caller can be a C function, as in pcall(require, path), so the module is the nearest Luau caller.
	requirer := module_by_chunkname(r, luau.caller_source(L))
	if requirer == nil {
		raise(L, "require works only in cooked scripts")
	}
	data, _ := asset.data(r.assets, requirer.handle)
	blob, _ := format.script_view(data)
	target, found := format.script_find_require(data, blob, path)
	if !found {
		raise(L, fmt.aprintf("the cooker did not resolve require(%q) in this script. Cook the content again.", path, allocator = frame(r)))
	}
	return push_module(r, L, target)
}

// push_module pushes a module's result, and runs the module first if it has not run.
@(private)
push_module :: proc(r: ^Runtime, L: ^luau.State, guid: format.Guid) -> c.int {
	m := module_for(r, guid)
	if m == nil {
		raise(L, "too many modules")
	}
	switch m.state {
	case .Loaded:
		luau.getref(L, m.result)
		return 1
	case .Loading:
		raise(L, fmt.aprintf("require cycle at %s", module_name(r, m), allocator = frame(r)))
	case .Main:
		raise(L, fmt.aprintf("%s runs as a script, so it cannot be required", module_name(r, m), allocator = frame(r)))
	case .Unloaded:
	}
	bytecode, chunkname, native, ok := load_module_asset(r, m)
	if !ok {
		raise(L, fmt.aprintf("cannot load the module %s", guid_text(r, guid), allocator = frame(r)))
	}
	// The module runs in its own environment, which reads through to the shared globals, like a sandboxed thread.
	luau.newtable(L)
	luau.newtable(L)
	luau.getref(L, r.globals)
	luau.setfield(L, -2, "__index")
	luau.setreadonly(L, -1, true)
	luau.setmetatable(L, -2)
	luau.setsafeenv(L, -1, true)
	env := luau.gettop(L)
	status := luau.load(L, chunkname, raw_data(bytecode), c.size_t(len(bytecode)), env)
	luau.remove(L, env)
	if status == .OK {
		compile_native(r, L, native)
		m.state = .Loading
		previous := set_category(r, L, category_of(module_index(r, m)))
		status = luau.pcall(L, 0, 1, 0)
		set_category(r, L, previous)
	}
	if status != .OK {
		// The module can be required again, for example after a fix.
		m.state = .Unloaded
		luau.error(L)
	}
	if luau.isnil(L, -1) {
		luau.pop(L, 1)
		luau.pushboolean(L, true)
	}
	m.result = luau.ref(L, -1)
	m.state = .Loaded
	return 1
}

// load_module_asset loads a module's blob, and returns its bytecode, its chunk name and whether it is native code. The
// bytecode is valid until the end of the frame.
@(private)
load_module_asset :: proc(r: ^Runtime, m: ^Module) -> (bytecode: []byte, chunkname: cstring, native: bool, ok: bool) {
	m.handle = asset.load(r.assets, m.guid) or_return
	data, _ := asset.data(r.assets, m.handle)
	blob, valid := format.script_view(data)
	if !valid {
		log.errorf("script: the blob of %s is not a script from this cooker", guid_text(r, m.guid))
		return
	}
	chunkname = fmt.caprintf("@%s", format.blob_string(data, blob.source_path), allocator = frame(r))
	return format.blob_bytes(data, blob.bytecode), chunkname, .Native in blob.flags, true
}

// compile_native compiles the function on top of L's stack, and the functions inside it, to machine code, if the
// module is native and the VM has a code generator. Without one, the module runs as bytecode.
@(private)
compile_native :: proc(r: ^Runtime, L: ^luau.State, native: bool) {
	if native && r.native {
		luau.codegen_compile(L, -1)
	}
}

@(private)
module_for :: proc(r: ^Runtime, guid: format.Guid) -> ^Module {
	for &m in r.modules[:r.module_count] {
		if m.guid == guid {
			return &m
		}
	}
	if r.module_count == MAX_MODULES {
		log.errorf("script: more than %d modules", MAX_MODULES)
		return nil
	}
	m := &r.modules[r.module_count]
	m^ = {
		guid   = guid,
		result = luau.NOREF,
	}
	r.module_count += 1
	return m
}

// module_by_chunkname finds the module whose chunk name is "@" and its source path.
@(private)
module_by_chunkname :: proc(r: ^Runtime, chunkname: string) -> ^Module {
	if len(chunkname) == 0 || chunkname[0] != '@' {
		return nil
	}
	for &m in r.modules[:r.module_count] {
		if m.state != .Unloaded && module_name(r, &m) == chunkname[1:] {
			return &m
		}
	}
	return nil
}

// module_name is a module's source path, such as "game/scripts/hello.luau".
@(private)
module_name :: proc(r: ^Runtime, m: ^Module) -> string {
	data, ok := asset.data(r.assets, m.handle)
	if !ok {
		return guid_text(r, m.guid)
	}
	blob, _ := format.script_view(data)
	return format.blob_string(data, blob.source_path) if blob != nil else guid_text(r, m.guid)
}

// Temporary text in the runtime goes to frame memory. Bindings run on the main fiber, whose temp allocator is never
// freed.
@(private)
frame :: proc(r: ^Runtime) -> runtime.Allocator {
	return r.platform.frame_allocator
}

@(private)
guid_text :: proc(r: ^Runtime, guid: format.Guid) -> string {
	buffer := new([32]u8, frame(r))
	return format.guid_format(guid, buffer)
}

// raise raises a Luau error with the caller's location. It does not return, and skips the defers of the frames that
// it leaves.
raise :: proc(L: ^luau.State, message: string) -> ! {
	luau.L_errorL(L, "%s", fmt.caprintf("%s", message, allocator = frame(runtime_of(L))))
}

@(private)
checkodinstring :: proc(L: ^luau.State, n: c.int) -> string {
	size: c.size_t
	s := luau.L_checklstring(L, n, &size)
	return string(s[:size])
}

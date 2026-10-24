package script

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"

import "cinnabar:core/luau"
import "cinnabar:engine/asset"
import format "cinnabar:engine/asset/format"

MAX_MODULES :: 256

// Module is a script asset that the runtime has run. See docs/scripting.md#modules-and-require.
@(private)
Module :: struct {
	guid:   format.Guid,
	handle: asset.Handle,
	state:  Module_State,
	// A registry reference to the module's result, once it is Loaded.
	result: c.int,
}

@(private)
Module_State :: enum u8 {
	Unloaded,
	// Its top level is running, so another require of it is a cycle.
	Loading,
	Loaded,
	// It runs as a thread from spawn_script, and has no result to require.
	Main,
}

// spawn_script starts a script asset on a new sandboxed thread, which runs until its first yield. Its requires load
// the modules that the cooker resolved.
spawn_script :: proc(r: ^Runtime, guid: format.Guid) -> (thread: Thread, ok: bool) {
	m := module_for(r, guid)
	if m == nil {
		return
	}
	if m.state != .Unloaded {
		log.errorf("script: %s already runs", guid_text(r, guid))
		return
	}
	bytecode, chunkname := load_module_asset(r, m) or_return
	L := r.L
	co := luau.newthread(L)
	thread = Thread(luau.ref(L, -1))
	luau.pop(L, 1)
	luau.L_sandboxthread(co)
	if luau.load(co, chunkname, raw_data(bytecode), c.size_t(len(bytecode)), 0) != .OK {
		log.errorf("script: %s", luau.toodinstring(co, -1))
		release(r, thread)
		return 0, false
	}
	m.state = .Main
	if resume(r, thread) == .Failed {
		release(r, thread)
		return 0, false
	}
	return thread, true
}

// require_binding is the global require. It finds the calling module by its chunk name, and loads the module that
// the cooker resolved the path to. A module runs once, and later requires get its result.
@(private)
require_binding :: proc(L: ^luau.State) -> c.int {
	r := runtime_of(L)
	path := checkodinstring(L, 1)
	ar: luau.Debug
	requirer: ^Module
	if luau.getinfo(L, 1, "s", &ar) {
		requirer = module_by_chunkname(r, string(ar.source))
	}
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
	bytecode, chunkname, ok := load_module_asset(r, m)
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
		m.state = .Loading
		status = luau.pcall(L, 0, 1, 0)
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

// load_module_asset loads a module's blob, and returns its bytecode and chunk name. The bytecode is valid until the
// end of the frame.
@(private)
load_module_asset :: proc(r: ^Runtime, m: ^Module) -> (bytecode: []byte, chunkname: cstring, ok: bool) {
	m.handle = asset.load(r.assets, m.guid) or_return
	data, _ := asset.data(r.assets, m.handle)
	blob, valid := format.script_view(data)
	if !valid {
		log.errorf("script: the blob of %s is not a script from this cooker", guid_text(r, m.guid))
		return
	}
	chunkname = fmt.caprintf("@%s", format.blob_string(data, blob.source_path), allocator = frame(r))
	return format.blob_bytes(data, blob.bytecode), chunkname, true
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
@(private)
raise :: proc(L: ^luau.State, message: string) -> ! {
	luau.L_errorL(L, "%s", fmt.caprintf("%s", message, allocator = frame(runtime_of(L))))
}

@(private)
checkodinstring :: proc(L: ^luau.State, n: c.int) -> string {
	size: c.size_t
	s := luau.L_checklstring(L, n, &size)
	return string(s[:size])
}

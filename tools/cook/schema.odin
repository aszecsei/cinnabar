package cook

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:time"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"

// The engine's prelude, which defines Behaviour and Field. The runtime runs the same source.
PRELUDE :: #load("../../lib/engine/script/prelude.luau", string)

// A behaviour script's top level that runs longer than this at cook time is stopped.
SCHEMA_BUDGET :: 2 * time.Second

// The prelude's natives at cook time. A module's top level must not call into the engine, so each raises an error.
@(private = "file")
COOK_NATIVES :: `
local function unavailable()
	error("the engine is not available when the cooker reads a behaviour's fields", 3)
end
-- Every engine global, such as World, is missing at cook time. Reading one names it.
setmetatable(_G, {__index = function(_, name)
	error(tostring(name) .. " is not available when the cooker reads a behaviour's fields", 2)
end})
return {
	get_enabled = unavailable,
	set_enabled = unavailable,
	start_coroutine = unavailable,
	stop_coroutine = unavailable,
	stop_all_coroutines = unavailable,
}
`

// Schema_VM runs the top level of behaviour scripts to read their fields (see docs/content/kinds/scripts.md#scripts).
Schema_VM :: struct {
	L:        ^luau.State,
	ctx:      runtime.Context,
	config:   Script_Config,
	scripts:  []Script_Source,
	problems: ^Problems,
	deadline: time.Tick,
}

@(private = "file")
MODULES_KEY :: "cinnabar.modules"

// schema_vm_open makes the VM: the built-in libraries, the prelude with the cook-time natives, and a require that
// follows the requires that the cooker resolved.
schema_vm_open :: proc(vm: ^Schema_VM, config: Script_Config, scripts: []Script_Source, problems: ^Problems) -> bool {
	vm^ = {
		L        = luau.L_newstate(),
		ctx      = context,
		config   = config,
		scripts  = scripts,
		problems = problems,
	}
	L := vm.L
	callbacks := luau.callbacks(L)
	callbacks.userdata = vm
	callbacks.interrupt = proc "c" (L: ^luau.State, gc: c.int) {
		vm := (^Schema_VM)(luau.callbacks(L).userdata)
		if gc < 0 && vm.deadline != {} && time.tick_diff(vm.deadline, time.tick_now()) > 0 {
			vm.deadline = {}
			luau.L_errorL(L, "the top level ran for more than %d seconds", c.int(SCHEMA_BUDGET / time.Second))
		}
	}
	luau.L_openlibs(L)
	if !run_chunk(vm, "=cook/natives", COOK_NATIVES, 0, 1) || !run_chunk(vm, "=engine/prelude.luau", PRELUDE, 1, 2) {
		return false
	}
	luau.setglobal(L, "Field")
	luau.setglobal(L, "Behaviour")
	luau.pushcfunction(L, schema_require, "require")
	luau.setglobal(L, "require")
	luau.newtable(L)
	luau.setfield(L, luau.REGISTRYINDEX, MODULES_KEY)
	luau.L_sandbox(L)
	return true
}

schema_vm_close :: proc(vm: ^Schema_VM) {
	if vm.L != nil {
		luau.close(vm.L)
	}
	vm.L = nil
}

// run_chunk compiles and calls source with the top nargs values as arguments.
@(private = "file")
run_chunk :: proc(vm: ^Schema_VM, chunkname: cstring, source: string, nargs, nresults: c.int) -> bool {
	L := vm.L
	bytecode := compile_source(vm.config, source)
	defer luau.free_bytecode(raw_data(bytecode))
	if luau.load(L, chunkname, raw_data(bytecode), c.size_t(len(bytecode)), 0) != .OK {
		report_error(vm.problems, "", 0, 0, "%s", luau.toodinstring(L, -1))
		return false
	}
	luau.insert(L, -1 - nargs)
	if luau.pcall(L, nargs, nresults, 0) != .OK {
		report_error(vm.problems, "", 0, 0, "%s", luau.toodinstring(L, -1))
		return false
	}
	return true
}

// read_schema runs a behaviour script's top level and reads the class that it returns. A script that returns no class
// has no schema, and is not an error.
read_schema :: proc(vm: ^Schema_VM, index: int) -> (class_name: string, fields: []format.Field_Entry, ok: bool) {
	L := vm.L
	s := &vm.scripts[index]
	top := luau.gettop(L)
	defer luau.settop(L, top)
	co := luau.newthread(L)
	luau.L_sandboxthread(co)
	bytecode := compile_source(vm.config, string(s.source))
	defer luau.free_bytecode(raw_data(bytecode))
	if luau.load(co, fmt.ctprintf("@%s", s.name), raw_data(bytecode), c.size_t(len(bytecode)), 0) != .OK {
		report_error(vm.problems, s.path, 0, 0, "%s", luau.toodinstring(co, -1))
		return
	}
	vm.deadline = time.tick_add(time.tick_now(), SCHEMA_BUDGET)
	status := luau.resume(co, L, 0)
	vm.deadline = {}
	if status != .OK {
		message := status == .YIELD ? "it yields" : luau.toodinstring(co, -1)
		report_error(
			vm.problems,
			s.path,
			0,
			0,
			"a behaviour script's top level runs when it is cooked, so it may only require modules and define classes: %s",
			message,
		)
		return
	}
	if luau.gettop(co) == 0 || !luau.istable(co, -1) || luau.rawgetfield(co, -1, "__behaviour") != .STRING {
		return "", nil, true
	}
	class_name = strings.clone(luau.toodinstring(co, -1), context.temp_allocator)
	luau.pop(co, 1)
	luau.rawgetfield(co, -1, "__fields")
	entries := make([dynamic]format.Field_Entry, context.temp_allocator)
	luau.pushnil(co)
	for luau.next(co, -2) {
		entry := format.Field_Entry {
			name = strings.clone(luau.toodinstring(co, -2), context.temp_allocator),
		}
		luau.rawgetfield(co, -1, "__field")
		kind := luau.toodinstring(co, -1)
		luau.rawgetfield(co, -2, "default")
		switch kind {
		case "number":
			entry.kind = .Number
			entry.number = luau.tonumber(co, -1)
		case "boolean":
			entry.kind = .Boolean
			entry.number = luau.toboolean(co, -1) ? 1 : 0
		case "string":
			entry.kind = .String
			entry.text = strings.clone(luau.toodinstring(co, -1), context.temp_allocator)
		case "vector":
			entry.kind = .Vector
			entry.vector = luau.tovector(co, -1)^
		case "entity":
			entry.kind = .Entity
		case "asset":
			entry.kind = .Asset
			luau.rawgetfield(co, -3, "kind")
			entry.text = strings.clone(luau.toodinstring(co, -1), context.temp_allocator)
			luau.pop(co, 1)
		}
		append(&entries, entry)
		luau.pop(co, 3)
	}
	slice.sort_by(entries[:], proc(a, b: format.Field_Entry) -> bool {return a.name < b.name})
	return class_name, entries[:], true
}

// schema_require loads a module for a behaviour script's top level, as the runtime's require does: by the requires
// that the cooker resolved, once, in its own environment.
@(private = "file")
schema_require :: proc "c" (L: ^luau.State) -> c.int {
	vm := (^Schema_VM)(luau.callbacks(L).userdata)
	context = vm.ctx
	path := string(luau.L_checkstring(L, 1))
	requirer := -1
	if source := luau.caller_source(L); strings.has_prefix(source, "@") {
		for s, i in vm.scripts {
			if s.name == source[1:] {
				requirer = i
			}
		}
	}
	if requirer < 0 {
		luau.L_errorL(L, "require works only in cooked scripts")
	}
	target := -1
	for r in vm.scripts[requirer].resolved {
		if r.entry.path == path {
			target = r.target
		}
	}
	if target < 0 {
		luau.L_errorL(L, "the cooker did not resolve require(\"%s\")", fmt.ctprintf("%s", path))
	}
	t := &vm.scripts[target]
	luau.getfield(L, luau.REGISTRYINDEX, MODULES_KEY)
	cache := luau.gettop(L)
	key := fmt.ctprintf("%s", t.name)
	if luau.rawgetfield(L, cache, key) != .NIL {
		return 1
	}
	luau.pop(L, 1)

	luau.newtable(L)
	luau.newtable(L)
	luau.pushvalue(L, luau.GLOBALSINDEX)
	luau.setfield(L, -2, "__index")
	luau.setreadonly(L, -1, true)
	luau.setmetatable(L, -2)
	env := luau.gettop(L)
	bytecode := compile_source(vm.config, string(t.source))
	status := luau.load(L, fmt.ctprintf("@%s", t.name), raw_data(bytecode), c.size_t(len(bytecode)), env)
	luau.free_bytecode(raw_data(bytecode))
	if status != .OK {
		luau.error(L)
	}
	luau.call(L, 0, 1)
	if luau.isnil(L, -1) {
		luau.pop(L, 1)
		luau.pushboolean(L, true)
	}
	luau.pushvalue(L, -1)
	luau.rawsetfield(L, cache, key)
	return 1
}

// dependency_hash hashes the sources of every module that a script requires, directly or not. A behaviour's field
// defaults can come from them, so a changed dependency cooks its dependents again.
dependency_hash :: proc(scripts: []Script_Source, index: int) -> u64 {
	seen := make([]bool, len(scripts), context.temp_allocator)
	pending := make([dynamic]int, context.temp_allocator)
	append(&pending, index)
	seen[index] = true
	order := make([dynamic]int, context.temp_allocator)
	for len(pending) > 0 {
		i := pop(&pending)
		for r in scripts[i].resolved {
			if !seen[r.target] {
				seen[r.target] = true
				append(&pending, r.target)
				append(&order, r.target)
			}
		}
	}
	slice.sort(order[:])
	key := hash.fnv64a(transmute([]byte)PRELUDE)
	for i in order {
		key = hash.fnv64a(transmute([]byte)scripts[i].name, key)
		key = hash.fnv64a(scripts[i].source, key)
	}
	return key
}

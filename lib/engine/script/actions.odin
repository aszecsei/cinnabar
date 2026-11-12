package script

import "core:c"
import "core:fmt"
import "core:log"

import "cinnabar:core/luau"
import "cinnabar:core/profile"
import "cinnabar:engine/ecs"

// Script actions: Luau classes that Action.define makes, which an agent's decision starts by name, and which run in the
// fixed step (see docs/ai/agents.md#script-actions). This package runs their instances; lib/engine/ai decides when,
// through the fixed hook, since it is above this package.

// The most script actions that run at once.
MAX_ACTIONS :: 4096

// Action_Handle is a running script action. The zero handle is none.
Action_Handle :: struct {
	index:      u32,
	generation: u32,
}

// Action_Status is how an action is after its start or a tick.
Action_Status :: enum u8 {
	Running,
	Succeeded,
	Failed,
}

// Action_Value is an action's argument: a number, a boolean, a string, a vector, an entity or a position.
Action_Value :: union {
	f64,
	bool,
	string,
	[3]f32,
	ecs.Entity,
	ecs.World_Position,
}

Action_Arg :: struct {
	name:  string,
	value: Action_Value,
}

// Action_Instance is a running action's instance table and the entity that it acts for. live is false for a free slot,
// whose generation the next start raises.
@(private)
Action_Instance :: struct {
	table:         c.int,
	entity:        ecs.Entity,
	generation:    u32,
	live:          bool,
	profile_class: profile.Name,
}

// Fixed_Hook is called in each fixed step, after the behaviours' fixed_update: lib/engine/ai runs its script actions in
// it. It is a registration, which reload clears.
Fixed_Hook :: struct {
	procedure: proc(r: ^Runtime, data: rawptr),
	data:      rawptr,
}

// set_fixed_hook gives the fixed step what it calls after the behaviours' fixed_update. Call it from the game's
// Register_Proc, so a reload sets it again.
set_fixed_hook :: proc(r: ^Runtime, hook: Fixed_Hook) {
	r.fixed_hook = hook
}

// push_action_class pushes the class that Action.define made for a name, or nil.
@(private = "file")
push_action_class :: proc(r: ^Runtime, name: string) -> bool {
	L := r.L
	luau.getref(L, r.action_registry)
	luau.pushlstring(L, raw_data(name), c.size_t(len(name)))
	found := luau.rawget(L, -2) == .TABLE
	luau.remove(L, -2)
	return found
}

// action_defined is whether a module has defined an action of the name.
action_defined :: proc(r: ^Runtime, name: string) -> bool {
	if r.L == nil || r.action_registry == 0 {
		return false
	}
	defer luau.pop(r.L, 1)
	return push_action_class(r, name)
}

@(private)
action_at :: proc(r: ^Runtime, h: Action_Handle) -> ^Action_Instance {
	if h.generation == 0 || int(h.index) >= r.action_used {
		return nil
	}
	a := &r.actions[h.index]
	return a if a.live && a.generation == h.generation else nil
}

@(private)
push_action_key :: proc(L: ^luau.State) {
	luau.pushlightuserdatatagged(L, nil, c.int(Light_Tag.Action_Key))
}

// action_of is the running action whose instance table is at idx.
@(private)
action_of :: proc(r: ^Runtime, L: ^luau.State, idx: c.int) -> (Action_Handle, bool) {
	if !luau.istable(L, idx) {
		return {}, false
	}
	t := luau.absindex(L, idx)
	push_action_key(L)
	luau.rawget(L, t)
	defer luau.pop(L, 1)
	if !luau.isinteger64(L, -1) {
		return {}, false
	}
	packed := u64(luau.tointeger64(L, -1, nil))
	h := Action_Handle{u32(packed), u32(packed >> 32)}
	return h, action_at(r, h) != nil
}

// push_action_value pushes an argument as its parameter's kind takes it, or gives false for one of another kind.
@(private = "file")
push_action_value :: proc(r: ^Runtime, L: ^luau.State, kind: string, value: Action_Value) -> bool {
	switch v in value {
	case f64:
		if kind != "number" {
			return false
		}
		luau.pushnumber(L, v)
	case bool:
		if kind != "boolean" {
			return false
		}
		luau.pushboolean(L, b32(v))
	case string:
		if kind != "string" {
			return false
		}
		luau.pushlstring(L, raw_data(v), c.size_t(len(v)))
	case [3]f32:
		if kind != "vector" {
			return false
		}
		push_vector(L, v)
	case ecs.Entity:
		if kind != "entity" {
			return false
		}
		push_entity(L, v)
	case ecs.World_Position:
		if kind != "position" {
			return false
		}
		push_position(L, v)
	case:
		return false
	}
	return true
}

// start_action makes an instance of the action named name for an entity, with its parameters' defaults and then the
// arguments, and calls its start. It fails for a name that no module defined, an argument that the action has no
// parameter for or of another kind, a start that raises an error, or when MAX_ACTIONS run. Call it in a fixed step.
start_action :: proc(r: ^Runtime, name: string, e: ecs.Entity, args: []Action_Arg) -> (h: Action_Handle, status: Action_Status) {
	assert(r.phase == .Fixed, "script: actions start in a fixed step")
	L := r.L
	top := luau.gettop(L)
	defer luau.settop(L, top)
	if !push_action_class(r, name) {
		log.warnf("script: no module defines the action %s", name)
		return {}, .Failed
	}
	class := luau.gettop(L)
	slot := -1
	for a, i in r.actions[:r.action_used] {
		if !a.live {
			slot = i
			break
		}
	}
	if slot < 0 {
		if r.action_used == MAX_ACTIONS {
			log.errorf("script: more than %d script actions run, so %s fails", MAX_ACTIONS, name)
			return {}, .Failed
		}
		slot = r.action_used
		r.action_used += 1
	}

	luau.createtable(L, 0, 4)
	t := luau.gettop(L)
	push_entity(L, e)
	luau.rawsetfield(L, t, "entity")
	luau.rawgetfield(L, class, "__params")
	params := luau.gettop(L)
	luau.pushnil(L)
	for luau.next(L, params) {
		luau.pushvalue(L, -2)
		luau.rawgetfield(L, -2, "default")
		luau.rawset(L, t)
		luau.pop(L, 1)
	}
	for arg in args {
		luau.pushlstring(L, raw_data(arg.name), c.size_t(len(arg.name)))
		if luau.rawget(L, params) != .TABLE {
			log.warnf("script: the action %s has no parameter %s", name, arg.name)
			return {}, .Failed
		}
		luau.rawgetfield(L, -1, "__param")
		kind := luau.toodinstring(L, -1)
		luau.pushlstring(L, raw_data(arg.name), c.size_t(len(arg.name)))
		if !push_action_value(r, L, kind, arg.value) {
			log.warnf("script: the action %s's parameter %s is a %s, and its argument is not", name, arg.name, kind)
			return {}, .Failed
		}
		luau.rawset(L, t)
		luau.pop(L, 2)
	}
	a := &r.actions[slot]
	a^ = {
		entity        = e,
		generation    = a.generation + 1,
		live          = true,
		profile_class = profile.name(&r.platform.profile, fmt.aprintf("%s", name, allocator = frame(r)), .Script),
	}
	if a.generation == 0 {
		a.generation = 1
	}
	h = {u32(slot), a.generation}
	push_action_key(L)
	luau.pushinteger64(L, i64(u64(h.generation) << 32 | u64(h.index)))
	luau.rawset(L, t)
	luau.pushvalue(L, class)
	luau.setmetatable(L, t)
	luau.pushvalue(L, t)
	a.table = luau.ref(L, -1)
	luau.pop(L, 1)

	if ok, _ := call_action(r, h, "start"); !ok {
		end_action(r, h)
		return {}, .Failed
	}
	return h, .Running
}

// call_action calls a method of a running action, if its class has one, with dt as its argument if it is set, and
// gives its result. ok is false when it raises an error.
@(private = "file")
call_action :: proc(r: ^Runtime, h: Action_Handle, name: cstring, dt: Maybe(f64) = nil) -> (ok: bool, status: Action_Status) {
	L := r.L
	a := action_at(r, h)
	if a == nil {
		return false, .Failed
	}
	top := luau.gettop(L)
	defer luau.settop(L, top)
	luau.getref(L, a.table)
	luau.getmetatable(L, -1)
	if luau.rawgetfield(L, -1, name) != .FUNCTION {
		return true, .Succeeded
	}
	luau.pushvalue(L, -3)
	nargs: c.int = 1
	if delta, has := dt.?; has {
		luau.pushnumber(L, delta)
		nargs = 2
	}
	zone := begin_callback(r, a.profile_class, .Event)
	called := protected_call(r, L, nargs, 1)
	end_callback(r, zone)
	if !called {
		return false, .Failed
	}
	#partial switch luau.type(L, -1) {
	case .NIL:
		return true, .Running
	case .STRING:
		switch luau.toodinstring(L, -1) {
		case "running":
			return true, .Running
		case "succeeded":
			return true, .Succeeded
		case "failed":
			return true, .Failed
		}
	}
	log.errorf("script: an action's %s gives \"running\", \"succeeded\", \"failed\" or nothing", name)
	return false, .Failed
}

// tick_action calls a running action's tick with the tick's length, and gives how it is: running until its tick gives
// "succeeded" or "failed". An action without tick succeeds, and one whose tick raises an error fails. The action
// keeps running until stop_action, whatever its status.
tick_action :: proc(r: ^Runtime, h: Action_Handle, dt: f64) -> Action_Status {
	assert(r.phase == .Fixed, "script: actions tick in a fixed step")
	if action_at(r, h) == nil {
		return .Failed
	}
	ok, status := call_action(r, h, "tick", dt)
	return status if ok else .Failed
}

// stop_action calls a running action's stop, stops the coroutines that it started, and frees it. A stale handle does
// nothing.
stop_action :: proc(r: ^Runtime, h: Action_Handle) {
	if action_at(r, h) == nil {
		return
	}
	call_action(r, h, "stop")
	end_action(r, h)
}

// end_action stops a running action's coroutines and frees it, without calling stop.
@(private = "file")
end_action :: proc(r: ^Runtime, h: Action_Handle) {
	a := action_at(r, h)
	if a == nil {
		return
	}
	stop_owned(r, h)
	luau.unref(r.L, a.table)
	a.live = false
	a.table = 0
}

// action_entity is the entity that a running action acts for, or 0 for a stale handle.
action_entity :: proc(r: ^Runtime, h: Action_Handle) -> ecs.Entity {
	if a := action_at(r, h); a != nil {
		return a.entity
	}
	return 0
}

// run_fixed_hook calls the fixed hook, if one is set.
@(private)
run_fixed_hook :: proc(r: ^Runtime) {
	if r.fixed_hook.procedure == nil {
		return
	}
	p := &r.platform.profile
	profile.begin(p, profile.name(p, "Script actions", .Frame))
	r.fixed_hook.procedure(r, r.fixed_hook.data)
	profile.end(p)
}

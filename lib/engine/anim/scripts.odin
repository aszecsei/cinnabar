package anim

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Animation library that scripts see (see docs/animation/design.md#scripts): an Animator's parameters by name, its
// state, and its root motion in the world. A behaviour gets the graph's events as on_animation_event.

@(private = "file")
REGISTRY_KEY :: "cinnabar.anim"

// register_scripts defines the Animation library, which reaches s, and exposes Animator and Root_Motion. A game's
// Register_Proc calls it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.expose(r, Animator, DEFAULT_ANIMATOR)
	script.expose(r, Root_Motion)

	script.define(r, "Animation.set_float", proc(L: ^luau.State) -> c.int {
		a, index, ok := parameter_args(L, .Float)
		if !ok {
			return 0
		}
		set_parameter(a, index, f32(luau.L_checknumber(L, 3)))
		return 0
	}, "(entity: Entity, name: string, value: number) -> ()")
	script.define(r, "Animation.set_bool", proc(L: ^luau.State) -> c.int {
		a, index, ok := parameter_args(L, .Bool)
		if !ok {
			return 0
		}
		luau.L_checktype(L, 3, .BOOLEAN)
		set_parameter(a, index, 1 if luau.toboolean(L, 3) else 0)
		return 0
	}, "(entity: Entity, name: string, value: boolean) -> ()")
	script.define(r, "Animation.trigger", proc(L: ^luau.State) -> c.int {
		a, index, ok := parameter_args(L, .Trigger)
		if !ok {
			return 0
		}
		fire(a, index)
		return 0
	}, "(entity: Entity, name: string) -> ()")
	script.define(r, "Animation.reset_trigger", proc(L: ^luau.State) -> c.int {
		a, index, ok := parameter_args(L, .Trigger)
		if !ok {
			return 0
		}
		a.instance.triggers &~= 1 << u32(index)
		return 0
	}, "(entity: Entity, name: string) -> ()")
	script.define(r, "Animation.get_float", proc(L: ^luau.State) -> c.int {
		a, index, ok := parameter_args(L, .Float)
		luau.pushnumber(L, f64(a.instance.parameters[index]) if ok else 0)
		return 1
	}, "(entity: Entity, name: string) -> number")
	script.define(r, "Animation.get_bool", proc(L: ^luau.State) -> c.int {
		a, index, ok := parameter_args(L, .Bool)
		luau.pushboolean(L, b32(ok && a.instance.parameters[index] != 0))
		return 1
	}, "(entity: Entity, name: string) -> boolean")
	script.define(r, "Animation.state", proc(L: ^luau.State) -> c.int {
		a := animator_arg(L)
		name := state_name(state_of(L), a)
		if name == "" {
			luau.pushnil(L)
		} else {
			luau.pushodinstring(L, name)
		}
		return 1
	}, "(entity: Entity) -> string?")
	script.define(r, "Animation.root_motion", proc(L: ^luau.State) -> c.int {
		w := script.runtime_of(L).world
		e := script.check_entity(L, 1)
		delta, _, ok := root_motion_world(w, e)
		yaw: f32
		if ok {
			yaw = ecs.get(w, e, Root_Motion).yaw
		}
		script.push_vector(L, delta)
		luau.pushnumber(L, f64(yaw))
		return 2
	}, "(entity: Entity) -> (vector, number)")
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	s := (^State)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	return s
}

// animator_arg reads the entity in the first argument, and raises an error unless it has an Animator.
@(private = "file")
animator_arg :: proc(L: ^luau.State) -> ^Animator {
	w := script.runtime_of(L).world
	e := script.check_entity(L, 1)
	a := ecs.get(w, e, Animator) if w != nil && ecs.is_alive(w, e) else nil
	if a == nil {
		script.raise(L, fmt.tprintf("entity %v has no Animator", e))
	}
	return a
}

// parameter_args reads the entity and the parameter's name. It raises an error for a name that the graph does not
// have, or a parameter of another kind. While the graph loads, or if it cannot load, it is not ok, and the call does
// nothing: the graph starts with its defaults.
@(private = "file")
parameter_args :: proc(L: ^luau.State, kind: format.Animation_Graph_Parameter_Kind) -> (a: ^Animator, index: int, ok: bool) {
	a = animator_arg(L)
	name := luau.L_checkstring(L, 2)
	s := state_of(L)
	if _, ready := ready_graph(s, a); !ready {
		return
	}
	found: format.Animation_Graph_Parameter_Kind
	index, found, ok = parameter(s, a, string(name))
	if !ok {
		script.raise(L, fmt.tprintf("the entity's animation graph has no parameter %s", name))
	}
	if found != kind {
		script.raise(L, fmt.tprintf("the parameter %s is a %v, not a %v", name, found, kind))
	}
	return
}

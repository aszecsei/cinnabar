package nav

import "core:c"
import "core:fmt"

import "cinnabar:core/luau"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The Navigation library that scripts see (see docs/ai/navigation.md#scripts): the queries, synchronous, for a few
// calls, and an entity's path requests. Scripts name an agent type by its name, as the project's nav.agents gives it;
// a name that no loaded navmesh has finds nothing.

@(private = "file")
REGISTRY_KEY :: "cinnabar.nav"

@(private = "file", rodata)
STATUS_NAMES := [Path_Status]cstring {
	.None    = "none",
	.Pending = "pending",
	.Found   = "found",
	.Partial = "partial",
	.Failed  = "failed",
}

// register_scripts defines the Navigation library, which reaches s, and exposes Nav_Path. A game's Register_Proc calls
// it, so init and every reload define them again.
register_scripts :: proc(r: ^script.Runtime, s: ^State) {
	luau.pushlightuserdata(r.L, s)
	luau.setfield(r.L, luau.REGISTRYINDEX, REGISTRY_KEY)
	script.expose(r, Nav_Path)

	script.define(r, "Navigation.nearest", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		point := script.check_position(L, 1)
		agent, known := agent_arg(L, s, 2).?
		if !known {
			return 0
		}
		extents: Maybe([3]f32)
		if !luau.isnoneornil(L, 3) {
			extents = script.check_vector(L, 3)
		}
		m, _, on, ok := snap(s, point, agent, extents)
		if !ok {
			return 0
		}
		script.push_position(L, world(m, on))
		return 1
	}, "(point: WorldPosition, agent: string, extents: vector?) -> WorldPosition?")
	script.define(r, "Navigation.find_path", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		start, goal := script.check_position(L, 1), script.check_position(L, 2)
		path: Path_Result = {status = .Failed}
		if agent, ok := agent_arg(L, s, 3).?; ok {
			max_nodes := int(luau.L_optinteger(L, 4, DEFAULT_MAX_NODES))
			path = find_path(s, start, goal, agent, max(max_nodes, 1), s.platform.frame_allocator)
		}
		luau.createtable(L, 0, 2)
		luau.pushstring(L, STATUS_NAMES[path.status])
		luau.rawsetfield(L, -2, "status")
		push_positions(L, path.corners)
		luau.rawsetfield(L, -2, "corners")
		return 1
	}, "(start: WorldPosition, goal: WorldPosition, agent: string, max_nodes: number?) -> NavPath")
	script.define(r, "Navigation.raycast", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		start, end := script.check_position(L, 1), script.check_position(L, 2)
		agent, known := agent_arg(L, s, 3).?
		if !known {
			return 0
		}
		hit, ok := raycast(s, start, end, agent)
		if !ok {
			return 0
		}
		luau.createtable(L, 0, 3)
		luau.pushnumber(L, f64(hit.t))
		luau.rawsetfield(L, -2, "t")
		script.push_position(L, hit.position)
		luau.rawsetfield(L, -2, "position")
		if normal, walled := hit.wall.?; walled {
			script.push_vector(L, normal)
			luau.rawsetfield(L, -2, "normal")
		}
		return 1
	}, "(start: WorldPosition, finish: WorldPosition, agent: string) -> NavRaycastHit?")
	script.define(r, "Navigation.random_point", proc(L: ^luau.State) -> c.int {
		s := state_of(L)
		around, radius := script.check_position(L, 1), f32(luau.L_checknumber(L, 2))
		agent, known := agent_arg(L, s, 3).?
		if !known {
			return 0
		}
		at, ok := random_point(s, around, radius, agent, &script.runtime_of(L).random, allocator = s.platform.frame_allocator)
		if !ok {
			return 0
		}
		script.push_position(L, at.position)
		return 1
	}, "(around: WorldPosition, radius: number, agent: string) -> WorldPosition?")
	script.define(r, "Navigation.request_path", proc(L: ^luau.State) -> c.int {
		s, _, e := path_args(L)
		request_path(requests(s), e, script.check_position(L, 2))
		return 0
	}, "(entity: Entity, goal: WorldPosition) -> ()")
	script.define(r, "Navigation.path", proc(L: ^luau.State) -> c.int {
		s, w, e := path_args(L)
		corners := path_corners(s, w, e)
		if corners == nil {
			return 0
		}
		push_positions(L, corners)
		return 1
	}, "(entity: Entity) -> { WorldPosition }?")
}

@(private = "file")
state_of :: proc(L: ^luau.State) -> ^State {
	luau.getfield(L, luau.REGISTRYINDEX, REGISTRY_KEY)
	s := (^State)(luau.tolightuserdata(L, -1))
	luau.pop(L, 1)
	return s
}

// agent_arg is the agent type that a string argument names, or nil when no loaded navmesh has it.
@(private = "file")
agent_arg :: proc(L: ^luau.State, s: ^State, idx: c.int) -> Maybe(Agent_Type) {
	name := luau.L_checkstring(L, idx)
	if agent, ok := agent_type(s, string(name)); ok {
		return agent
	}
	return nil
}

// path_args reads the entity in the first argument, and raises an error unless it has a Nav_Path.
@(private = "file")
path_args :: proc(L: ^luau.State) -> (^State, ^ecs.World, ecs.Entity) {
	s, w, e := state_of(L), script.runtime_of(L).world, script.check_entity(L, 1)
	if !ecs.is_alive(w, e) || !ecs.has(w, e, Nav_Path) {
		script.raise(L, fmt.tprintf("entity %v has no path: give it a NavPath", e))
	}
	return s, w, e
}

@(private = "file")
push_positions :: proc(L: ^luau.State, positions: []ecs.World_Position) {
	luau.createtable(L, c.int(len(positions)), 0)
	for p, i in positions {
		script.push_position(L, p)
		luau.rawseti(L, -2, c.int(i + 1))
	}
}

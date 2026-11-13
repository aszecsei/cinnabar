// Package nav is navigation (see docs/ai/navigation.md): the component that asks the cooker to bake navmeshes (see
// docs/content/kinds/nav-meshes.md), and the runtime that loads them with their scene, answers queries on them,
// solves path requests, and moves agents along their paths around each other. The cooker bakes them with Recast. The runtime reads their blobs with no part of Recast or
// Detour linked, and holds no static state, so a code reload keeps it and jobs can query it.
package nav

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The AI components' stable IDs, 128 to 143 (see docs/world/ecs.md#component-registry).
NAV_MESH_VOLUME_ID :: ecs.Component_Id(128)
NAV_PATH_ID :: ecs.Component_Id(129)
NAV_AGENT_ID :: ecs.Component_Id(134)
NAV_AGENT_STATE_ID :: ecs.Component_Id(135)

// Nav_Mesh_Volume is defined in format with its defaults, which the cooker reads too.
Nav_Mesh_Volume :: format.Nav_Mesh_Volume

#assert(NAV_MESH_VOLUME_ID == format.SCENE_NAV_MESH_VOLUME_ID)

// Agent_Type is an agent type by its index in the project's nav.agents, which is its bit in Nav_Mesh_Volume.agents and
// its navmeshes' agent_index. agent_type finds one by its name.
Agent_Type :: distinct u32

// Path_Status is where a Nav_Path's request is. None is no request, which is not a path.
Path_Status :: enum u8 {
	None,
	// Asked for, and not solved yet.
	Pending,
	// To the goal.
	Found,
	// To the reachable point nearest the goal, which the path could not reach, or which the search's node budget did not.
	Partial,
	// No path: no navmesh of the agent type holds the entity, or none is near it.
	Failed,
}

// Path_Handle is a path in the state's pool. The zero handle is none.
Path_Handle :: struct {
	index:      u32,
	generation: u32,
}

// Nav_Path is an entity's path, which request_path asks for and the paths system solves (see
// docs/ai/navigation.md#path-requests). The path itself is in the state's pool, which path_corners reads, so the
// component stays small.
Nav_Path :: struct {
	// The agent type whose navmeshes the path is found on.
	agent:   Agent_Type,
	status:  Path_Status `editor:"read" script:"read"`,
	// The path's corners, from the start to its end.
	corners: u32 `editor:"read" script:"read"`,
	path:    Path_Handle `editor:"-" script:"-"`,
}

#assert(size_of(Nav_Path) <= ecs.MAX_COMPONENT_SIZE)

// Nav_Agent makes its entity an agent of the crowd (see docs/ai/navigation.md#crowds): move_to sends it to a target,
// and the crowd system walks it there along its path and around the other agents, through the Character that it needs
// on the same entity. Its speeds are in meters per second, and its distances in meters.
Nav_Agent :: struct {
	// The agent type whose navmeshes it walks on.
	agent:             Agent_Type,
	max_speed:         f32 `editor:"range=0,50"`,
	// How fast its velocity changes, in meters per second squared.
	acceleration:      f32 `editor:"range=0,200"`,
	// The circle that the others avoid, and that it keeps away from them.
	radius:            f32 `editor:"range=0.05,10"`,
	// An agent gives way to those of a higher priority, shares the way with those of its own, and keeps its way from
	// those of a lower.
	priority:          u8,
	// How near its target it stops.
	stopping_distance: f32 `editor:"range=0,10"`,
}

DEFAULT_NAV_AGENT :: Nav_Agent {
	max_speed         = 3.5,
	acceleration      = 8,
	radius            = 0.3,
	priority          = 50,
	stopping_distance = 0.2,
}

#assert(size_of(Nav_Agent) <= ecs.MAX_COMPONENT_SIZE)

// Move_Status is where an agent's move is. Idle is no move, before the first or after stop.
Move_Status :: enum u8 {
	Idle,
	// Toward its target, or waiting for its path.
	Moving,
	// Within its stopping distance of its target.
	Arrived,
	// No path reaches its target, or none starts where it is.
	Failed,
}

// Crowd_Handle is an agent in the state's crowd. The zero handle is none.
Crowd_Handle :: struct {
	index:      u32,
	generation: u32,
}

// Nav_Agent_State is the crowd's runtime state of a Nav_Agent, which the crowd system adds and writes: its move's
// status and the velocities of its last tick, which an animator's parameter can follow. Its corridor and steering are
// in the state's crowd, keyed by the slot here.
Nav_Agent_State :: struct {
	crowd:    Crowd_Handle `editor:"-" script:"-"`,
	status:   Move_Status `editor:"read" script:"read"`,
	// The velocity that it chose, after avoidance, and the one that its path asked for, in meters per second.
	velocity: [3]f32 `editor:"read" script:"read"`,
	desired:  [3]f32 `editor:"read" script:"read"`,
}

#assert(size_of(Nav_Agent_State) <= ecs.MAX_COMPONENT_SIZE)

// register_components registers Nav_Mesh_Volume, Nav_Path, Nav_Agent and Nav_Agent_State. Call it with the engine's
// components, in init and on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Nav_Mesh_Volume, NAV_MESH_VOLUME_ID, format.DEFAULT_NAV_MESH_VOLUME)
	ecs.register_component(r, Nav_Path, NAV_PATH_ID)
	ecs.register_component(r, Nav_Agent, NAV_AGENT_ID, DEFAULT_NAV_AGENT)
	ecs.register_component(r, Nav_Agent_State, NAV_AGENT_STATE_ID)
}

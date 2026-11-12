// Package nav is navigation (see docs/ai/navigation.md): the component that asks the cooker to bake navmeshes (see
// docs/content/kinds/nav-meshes.md), and the runtime that loads them with their scene, answers queries on them and
// solves path requests. The cooker bakes them with Recast. The runtime reads their blobs with no part of Recast or
// Detour linked, and holds no static state, so a code reload keeps it and jobs can query it.
package nav

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The AI components' stable IDs, 128 to 143 (see docs/world/ecs.md#component-registry).
NAV_MESH_VOLUME_ID :: ecs.Component_Id(128)
NAV_PATH_ID :: ecs.Component_Id(129)

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

// register_components registers Nav_Mesh_Volume and Nav_Path. Call it with the engine's components, in init and
// on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Nav_Mesh_Volume, NAV_MESH_VOLUME_ID, format.DEFAULT_NAV_MESH_VOLUME)
	ecs.register_component(r, Nav_Path, NAV_PATH_ID)
}

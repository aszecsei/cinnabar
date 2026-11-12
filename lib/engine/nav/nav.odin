// Package nav is navigation: for now the component that asks the cooker to bake navmeshes (see
// docs/content/kinds/nav-meshes.md). The cooker bakes them with Recast, and the runtime reads their blobs with no part of
// Recast or Detour linked.
package nav

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The AI components' stable IDs, 128 to 143 (see docs/world/ecs.md#component-registry).
NAV_MESH_VOLUME_ID :: ecs.Component_Id(128)

// Nav_Mesh_Volume is defined in format with its defaults, which the cooker reads too.
Nav_Mesh_Volume :: format.Nav_Mesh_Volume

#assert(NAV_MESH_VOLUME_ID == format.SCENE_NAV_MESH_VOLUME_ID)

// register_components registers Nav_Mesh_Volume. Call it with the engine's components, in init and on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Nav_Mesh_Volume, NAV_MESH_VOLUME_ID, format.DEFAULT_NAV_MESH_VOLUME)
}

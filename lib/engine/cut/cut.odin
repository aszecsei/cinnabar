// Package cut registers the level design components that cut meshes (see docs/editor/mesh-editing.md#cutters-and-cut-targets):
// Mesh_Cutter, the volume that a cut removes, and Cut_Target, a mesh that cutters can cut. The editor reads them and
// does the cut, and saves the result as an ordinary mesh. No system of the game reads them, as none reads
// Nav_Mesh_Volume, so they are registered only for the scene, the editor and its helpers.
package cut

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The level design components' stable IDs, 176 to 191 (see docs/world/ecs.md#component-registry).
MESH_CUTTER_ID :: ecs.Component_Id(176)
CUT_TARGET_ID :: ecs.Component_Id(177)

// Both are defined in format, with Mesh_Cutter's defaults, so the cooker can read them from a scene's text.
Mesh_Cutter :: format.Mesh_Cutter
Mesh_Cutter_Shape :: format.Mesh_Cutter_Shape
Cut_Target :: format.Cut_Target

DEFAULT_EXTENT :: format.MESH_CUTTER_DEFAULT_EXTENT

#assert(MESH_CUTTER_ID == format.SCENE_MESH_CUTTER_ID)
#assert(CUT_TARGET_ID == format.SCENE_CUT_TARGET_ID)

// register_components registers Mesh_Cutter and Cut_Target. Call it with the engine's components, in init and
// on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(
		r,
		Mesh_Cutter,
		MESH_CUTTER_ID,
		format.DEFAULT_MESH_CUTTER,
		category = "Level Design",
	)
	ecs.register_component(r, Cut_Target, CUT_TARGET_ID, category = "Level Design")
}

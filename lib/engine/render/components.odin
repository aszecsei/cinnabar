package render

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The render components' stable IDs (see docs/world.md). Engine components take IDs below 1000.
CAMERA_ID :: ecs.Component_Id(32)
MESH_RENDERER_ID :: ecs.Component_Id(33)

// The view of a Camera that leaves a field at 0, as a component added in the editor does.
DEFAULT_VERTICAL_FOV :: math.PI / 3
DEFAULT_NEAR :: 0.05

// Camera makes its entity a camera: the frame can be drawn from its presented Transform. Game_State holds the active
// camera's entity (see docs/rendering.md#components). 0 in a field means its default.
Camera :: struct {
	// In radians.
	vertical_fov: f32 `editor:"range=0.1,3"`,
	// In meters. The far plane is at infinity.
	near:         f32 `editor:"range=0.001,10"`,
}

// Mesh_Renderer draws a mesh asset at its entity's Transform, each of its first submeshes with the material or
// instance in its slot, or the default material without one.
Mesh_Renderer :: struct {
	mesh:         format.Guid `asset:"mesh"`,
	materials:    [MAX_MATERIAL_SLOTS]format.Guid `asset:"material"`,
	cast_shadows: bool,
}

// register_components registers the render components. Call it with the engine's components, in init and on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Camera, CAMERA_ID)
	ecs.register_component(r, Mesh_Renderer, MESH_RENDERER_ID)
}

// camera_view is the view from a Camera entity: its presented pose, and its field of view and near plane. It fails if
// the entity is not a live camera.
camera_view :: proc(w: ^ecs.World, entity: ecs.Entity) -> (view: View, ok: bool) {
	camera := ecs.get(w, entity, Camera)
	if camera == nil {
		return
	}
	pose := ecs.presented(w, entity) or_return
	return {
			position = pose.position,
			rotation = pose.rotation,
			vertical_fov = camera.vertical_fov > 0 ? camera.vertical_fov : DEFAULT_VERTICAL_FOV,
			near = camera.near > 0 ? camera.near : DEFAULT_NEAR,
		},
		true
}

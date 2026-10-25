package render

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The render components' stable IDs (see docs/world.md). Engine components take IDs below 1000.
CAMERA_ID :: ecs.Component_Id(32)
MESH_RENDERER_ID :: ecs.Component_Id(33)
DIRECTIONAL_LIGHT_ID :: ecs.Component_Id(34)
POINT_LIGHT_ID :: ecs.Component_Id(35)
SPOT_LIGHT_ID :: ecs.Component_Id(36)
VIEW_MODEL_ID :: ecs.Component_Id(37)
FOG_ID :: ecs.Component_Id(38)

// The view of a Camera that leaves a field at 0, as a component added in the editor does.
DEFAULT_VERTICAL_FOV :: math.PI / 3
DEFAULT_NEAR :: 0.05

// Camera makes its entity a camera: the frame can be drawn from its presented Transform. Game_State holds the active
// camera's entity (see docs/rendering.md#components). 0 in a field means its default.
Camera :: struct {
	// In radians.
	vertical_fov: f32 `editor:"range=0.1,3"`,
	// In meters. The far plane is at infinity.
	near:            f32 `editor:"range=0.001,10"`,
	// The view model's projection, in radians and meters (see View_Model). 0 means the camera's own.
	view_model_fov:  f32 `editor:"range=0,3"`,
	view_model_near: f32 `editor:"range=0,10"`,
}

// View_Model marks an entity of the first-person view model: it draws with the camera's view model projection, over
// the world, which never covers it, and it casts no shadows (see docs/rendering.md#view-model). Its pose is in the
// world, usually as a child of the camera.
View_Model :: struct {}

// Mesh_Renderer draws a mesh asset at its entity's Transform, each of its first submeshes with the material or
// instance in its slot, or the default material without one.
Mesh_Renderer :: struct {
	mesh:         format.Guid `asset:"mesh"`,
	materials:    [MAX_MATERIAL_SLOTS]format.Guid `asset:"material"`,
	cast_shadows: bool,
}

// The lights' defaults for a field left at 0, as a component added in the editor leaves them.
DEFAULT_LIGHT_RANGE :: 10
DEFAULT_SPOT_OUTER :: math.PI / 4

// Directional_Light lights the world from far away, along its entity's +z, as the sun does. Its light is color times
// intensity, in the same units as the sky's. A color of 0 means white. See docs/rendering.md#lights-and-clusters.
Directional_Light :: struct {
	color:        [3]f32,
	intensity:    f32,
	cast_shadows: bool,
}

// Point_Light lights every direction from its entity's position. Its light falls off with the square of the distance,
// and reaches 0 at its range in meters (0 means DEFAULT_LIGHT_RANGE).
Point_Light :: struct {
	color:        [3]f32,
	intensity:    f32,
	range:        f32 `editor:"range=0,1000"`,
	cast_shadows: bool,
}

// Spot_Light is a point light in a cone along its entity's +z: full inside inner_angle and none outside outer_angle,
// both half angles in radians (0 means DEFAULT_SPOT_OUTER for the outer angle, and the outer angle for the inner).
Spot_Light :: struct {
	color:        [3]f32,
	intensity:    f32,
	range:        f32 `editor:"range=0,1000"`,
	inner_angle:  f32 `editor:"range=0,1.5"`,
	outer_angle:  f32 `editor:"range=0,1.5"`,
	cast_shadows: bool,
}

// Fog fills the world with volumetric fog (see docs/rendering.md#volumetric-fog): the frame takes the first visible
// entity's. Its density is the share of light that a meter of fog takes away, at and below its entity's height, and
// falls off above it. A density of 0 is no fog.
Fog :: struct {
	density:        f32 `editor:"range=0,1"`,
	// The share of the light that the fog takes away that it scatters rather than absorbs, per channel. 0 means white.
	albedo:         [3]f32,
	// How fast the density falls with height above the entity, per meter. 0 keeps it the same everywhere.
	height_falloff: f32 `editor:"range=0,10"`,
	// Where the fog scatters light: above 0 forward, so it glows around a light that the camera looks toward, and below
	// 0 back toward the light.
	anisotropy:     f32 `editor:"range=-0.9,0.9"`,
}

// register_components registers the render components. Call it with the engine's components, in init and on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Camera, CAMERA_ID)
	ecs.register_component(r, Mesh_Renderer, MESH_RENDERER_ID)
	ecs.register_component(r, Directional_Light, DIRECTIONAL_LIGHT_ID)
	ecs.register_component(r, Point_Light, POINT_LIGHT_ID)
	ecs.register_component(r, Spot_Light, SPOT_LIGHT_ID)
	ecs.register_component(r, View_Model, VIEW_MODEL_ID)
	ecs.register_component(r, Fog, FOG_ID)
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
			view_model_fov = camera.view_model_fov,
			view_model_near = camera.view_model_near,
		},
		true
}

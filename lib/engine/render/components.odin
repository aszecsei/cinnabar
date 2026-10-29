package render

import "core:math"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The render components' stable IDs (see docs/world/README.md). Engine components take IDs below 1000.
CAMERA_ID :: ecs.Component_Id(32)
MESH_RENDERER_ID :: ecs.Component_Id(33)
DIRECTIONAL_LIGHT_ID :: ecs.Component_Id(34)
POINT_LIGHT_ID :: ecs.Component_Id(35)
SPOT_LIGHT_ID :: ecs.Component_Id(36)
VIEW_MODEL_ID :: ecs.Component_Id(37)
FOG_ID :: ecs.Component_Id(38)
QUAD_LIGHT_ID :: ecs.Component_Id(39)
DISK_LIGHT_ID :: ecs.Component_Id(40)
LINE_LIGHT_ID :: ecs.Component_Id(41)
// 42 is the Volume, and 43 to 50 the settings components (see settings.odin).
SURFACE_RENDERER_ID :: ecs.Component_Id(51)
// 52 is the Particle_System (see particles.odin).
INSTANCED_MESH_RENDERER_ID :: ecs.Component_Id(53)

// The view of a Camera that leaves a field at 0, as a component added in the editor does.
DEFAULT_VERTICAL_FOV :: math.PI / 3
DEFAULT_NEAR :: 0.05

// Camera makes its entity a camera: the frame can be drawn from its presented Transform. Game_State holds the active
// camera's entity (see docs/rendering/assets.md#components). 0 in a field means its default.
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
// the world, which never covers it, and it casts no shadows (see docs/rendering/layers-and-output.md#view-model). Its pose is in the
// world, usually as a child of the camera.
View_Model :: struct {}

// Mesh_Renderer draws a mesh asset at its entity's Transform, each of its first submeshes with the material or
// instance in its slot, or the default material without one.
Mesh_Renderer :: struct {
	mesh:         format.Guid `asset:"mesh"`,
	materials:    [MAX_MATERIAL_SLOTS]format.Guid `asset:"material"`,
	cast_shadows: bool,
}

// Instanced_Mesh_Renderer draws a mesh at each pose of an instance set (see docs/rendering/gpu-scene.md#instanced-meshes),
// relative to its entity's Transform, each of its first submeshes with the material or instance in its slot, as a
// Mesh_Renderer does. A USD stage's point instancers are instance sets (see docs/content/kinds/stages.md#point-instancers).
Instanced_Mesh_Renderer :: struct {
	mesh:         format.Guid `asset:"mesh"`,
	materials:    [MAX_MATERIAL_SLOTS]format.Guid `asset:"material"`,
	instances:    format.Guid `asset:"instance_set"`,
	cast_shadows: bool,
}

// Surface_Renderer draws a patch surface (see docs/rendering/surfaces.md#surfaces): a rectangle of size meters along its
// entity's x and z, about its position, as grid patches that the GPU picks by their distance from the camera, with
// its material, which must draw patches (geometry = patches), or the engine's default surface material without one.
// The surface has a hole where hole_mask, a mask texture over the rectangle, reads 0. cell is the finest quad's size
// in meters (0 means DEFAULT_SURFACE_CELL), and height_range how far below and above its plane the material's
// displacement reaches, which culling allows for.
Surface_Renderer :: struct {
	size:         [2]f32,
	material:     format.Guid `asset:"material"`,
	hole_mask:    format.Guid `asset:"texture"`,
	cell:         f32 `editor:"range=0,100"`,
	height_range: [2]f32,
	cast_shadows: bool,
}

// The lights' defaults for a field left at 0, as a component added in the editor leaves them.
DEFAULT_LIGHT_RANGE :: 10
DEFAULT_SPOT_OUTER :: math.PI / 4
// In meters, for an area light's width, height or length.
DEFAULT_AREA_SIZE :: 1

// Directional_Light lights the world from far away, along its entity's +z, as the sun does. Its light is color times
// intensity, in the same units as the sky's. A color of 0 means white. See docs/rendering/lighting-and-shadows.md#lights-and-clusters.
Directional_Light :: struct {
	color:        [3]f32 `editor:"color"`,
	intensity:    f32 `editor:"range=0,100"`,
	cast_shadows: bool,
}

// Point_Light lights every direction from its entity's position. Its light falls off with the square of the distance,
// and reaches 0 at its range in meters (0 means DEFAULT_LIGHT_RANGE).
Point_Light :: struct {
	color:        [3]f32 `editor:"color"`,
	intensity:    f32 `editor:"range=0,100"`,
	range:        f32 `editor:"range=0,1000"`,
	cast_shadows: bool,
}

// Spot_Light is a point light in a cone along its entity's +z: full inside inner_angle and none outside outer_angle,
// both half angles in radians (0 means DEFAULT_SPOT_OUTER for the outer angle, and the outer angle for the inner).
Spot_Light :: struct {
	color:        [3]f32 `editor:"color"`,
	intensity:    f32 `editor:"range=0,100"`,
	range:        f32 `editor:"range=0,1000"`,
	inner_angle:  f32 `editor:"range=0,1.5"`,
	outer_angle:  f32 `editor:"range=0,1.5"`,
	cast_shadows: bool,
}

// The area lights (see docs/rendering/lighting-and-shadows.md#area-lights) have a size in meters, and their intensity is as a point light's
// would be along their +z: a bigger light spreads the same light over more of its surface. Each reaches 0 at its range
// beyond its size (0 means DEFAULT_LIGHT_RANGE), and casts shadows from its center, as a point light does.

// Quad_Light is a rectangle of light, width by height along its entity's x and y (0 means DEFAULT_AREA_SIZE), that
// shines along its +z, or both ways when two_sided.
Quad_Light :: struct {
	color:        [3]f32 `editor:"color"`,
	intensity:    f32 `editor:"range=0,100"`,
	width:        f32 `editor:"range=0,100"`,
	height:       f32 `editor:"range=0,100"`,
	range:        f32 `editor:"range=0,1000"`,
	two_sided:    bool,
	cast_shadows: bool,
}

// Disk_Light is a disk of light, width and height across along its entity's x and y, so an ellipse when they differ (0
// means DEFAULT_AREA_SIZE), that shines along its +z, or both ways when two_sided.
Disk_Light :: struct {
	color:        [3]f32 `editor:"color"`,
	intensity:    f32 `editor:"range=0,100"`,
	width:        f32 `editor:"range=0,100"`,
	height:       f32 `editor:"range=0,100"`,
	range:        f32 `editor:"range=0,1000"`,
	two_sided:    bool,
	cast_shadows: bool,
}

// Line_Light is a tube of light along its entity's x, length long (0 means DEFAULT_AREA_SIZE), with round ends. A radius
// of 0 is an ideal line.
Line_Light :: struct {
	color:        [3]f32 `editor:"color"`,
	intensity:    f32 `editor:"range=0,100"`,
	length:       f32 `editor:"range=0,100"`,
	radius:       f32 `editor:"range=0,10"`,
	range:        f32 `editor:"range=0,1000"`,
	cast_shadows: bool,
}

// register_components registers the render components, with the settings components that volumes carry (see Fog and
// the others in settings.odin). Call it with the engine's components and volume.register_components, in init and
// on_reload.
register_components :: proc(r: ^ecs.Registry) {
	ecs.register_component(r, Camera, CAMERA_ID)
	ecs.register_component(r, Mesh_Renderer, MESH_RENDERER_ID)
	ecs.register_component(r, Directional_Light, DIRECTIONAL_LIGHT_ID)
	ecs.register_component(r, Point_Light, POINT_LIGHT_ID)
	ecs.register_component(r, Spot_Light, SPOT_LIGHT_ID)
	ecs.register_component(r, View_Model, VIEW_MODEL_ID)
	ecs.register_component(r, Quad_Light, QUAD_LIGHT_ID)
	ecs.register_component(r, Disk_Light, DISK_LIGHT_ID)
	ecs.register_component(r, Line_Light, LINE_LIGHT_ID)
	ecs.register_component(r, Surface_Renderer, SURFACE_RENDERER_ID)
	ecs.register_component(r, Particle_System, PARTICLE_SYSTEM_ID)
	ecs.register_component(r, Instanced_Mesh_Renderer, INSTANCED_MESH_RENDERER_ID)
	register_settings_components(r)
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

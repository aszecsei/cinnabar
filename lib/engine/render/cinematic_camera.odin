package render

import "core:math"
import "core:math/linalg"

import "cinnabar:engine/ecs"

// The cinematics' components take the stable IDs 160 to 175 (see docs/world/ecs.md#component-registry).
CINEMATIC_CAMERA_ID :: ecs.Component_Id(160)

// A lens's defaults, for a field of 0 (see docs/rendering/post-processing.md#depth-of-field): a 35 mm lens on a
// full-frame sensor, 36 × 24 mm, focused at 10 m.
DEFAULT_FOCAL_LENGTH :: 35
DEFAULT_SENSOR_WIDTH :: 36
DEFAULT_SENSOR_HEIGHT :: 24
DEFAULT_FOCUS_DISTANCE :: 10

// Cinematic_Camera gives the Camera beside it a lens in a camera's terms (see docs/rendering/assets.md#components).
// While it is there, the lens sets the field of view: 2 × atan(sensor_height / (2 × focal_length)), which the
// "cinematic lens" system writes into Camera.vertical_fov, the one writer of that field. The aperture and the focus
// set the depth of field. 0 in a field means its default.
Cinematic_Camera :: struct {
	// In millimeters.
	focal_length:   f32 `editor:"range=0,600"`,
	// In millimeters. The sensor's aspect is the shot's.
	sensor_width:   f32 `editor:"range=0,100"`,
	sensor_height:  f32 `editor:"range=0,100"`,
	// In meters, where the lens is sharp. With a live focus entity, its distance along the camera's axis sets the
	// focus each frame in its place.
	focus_distance: f32 `editor:"range=0,1000"`,
	// The f-number. 0 means no depth of field.
	aperture:       f32 `editor:"range=0,32"`,
	focus:          ecs.Entity,
}

DEFAULT_CINEMATIC_CAMERA :: Cinematic_Camera {
	focal_length   = DEFAULT_FOCAL_LENGTH,
	sensor_width   = DEFAULT_SENSOR_WIDTH,
	sensor_height  = DEFAULT_SENSOR_HEIGHT,
	focus_distance = DEFAULT_FOCUS_DISTANCE,
}

// cinematic_vertical_fov is a lens's vertical field of view in radians: 2 × atan(sensor_height / (2 × focal_length)),
// with the defaults for fields of 0 or less.
cinematic_vertical_fov :: proc(c: Cinematic_Camera) -> f32 {
	focal := c.focal_length > 0 ? c.focal_length : DEFAULT_FOCAL_LENGTH
	sensor := c.sensor_height > 0 ? c.sensor_height : DEFAULT_SENSOR_HEIGHT
	return 2 * math.atan(sensor / (2 * focal))
}

// cinematic_aspect is a lens's sensor's width over its height.
cinematic_aspect :: proc(c: Cinematic_Camera) -> f32 {
	width := c.sensor_width > 0 ? c.sensor_width : DEFAULT_SENSOR_WIDTH
	height := c.sensor_height > 0 ? c.sensor_height : DEFAULT_SENSOR_HEIGHT
	return width / height
}

// camera_aspect is the aspect of a camera entity's shot: its Cinematic_Camera's sensor's, else the given aspect.
camera_aspect :: proc(w: ^ecs.World, entity: ecs.Entity, otherwise: f32) -> f32 {
	if c := ecs.get(w, entity, Cinematic_Camera); c != nil {
		return cinematic_aspect(c^)
	}
	return otherwise
}

// set_cinematic_fov writes each Cinematic_Camera's field of view into the Camera beside it, where it differs. It is
// the one writer of vertical_fov on those cameras: the "cinematic lens" system runs it in each frame's Late stage,
// after the cutscenes' tracks and the scripts set the lenses (see camera.register).
set_cinematic_fov :: proc(w: ^ecs.World) {
	cameras := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	ecs.collect(w, {CAMERA_ID, CINEMATIC_CAMERA_ID}, &cameras)
	for entity in cameras {
		camera := ecs.get(w, entity, Camera)
		fov := cinematic_vertical_fov(ecs.get(w, entity, Cinematic_Camera)^)
		if camera.vertical_fov != fov {
			camera.vertical_fov = fov
			ecs.mark_changed(w, entity, CAMERA_ID)
		}
	}
}

// cinematic_lens is a lens with its defaults, at a pose: the focus is its focus entity's distance along the camera's
// axis while that entity is alive and presented, else focus_distance. A lens without an aperture is the zero lens.
@(private)
cinematic_lens :: proc(
	w: ^ecs.World,
	c: Cinematic_Camera,
	position: ecs.World_Position,
	rotation: quaternion128,
) -> Lens {
	if c.aperture <= 0 {
		return {}
	}
	focus := c.focus_distance > 0 ? c.focus_distance : DEFAULT_FOCUS_DISTANCE
	if c.focus != 0 && ecs.is_alive(w, c.focus) {
		if target, ok := ecs.presented(w, c.focus); ok {
			forward := linalg.quaternion128_mul_vector3(rotation, [3]f32{0, 0, 1})
			focus = linalg.dot(ecs.position_sub(target.position, position), forward)
		}
	}
	return {
		sensor_height = c.sensor_height > 0 ? c.sensor_height : DEFAULT_SENSOR_HEIGHT,
		aperture = c.aperture,
		focus_distance = focus,
	}
}

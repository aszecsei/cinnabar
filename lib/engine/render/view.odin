package render

import "core:math"
import "core:math/linalg"

import "cinnabar:engine/ecs"

// View is where a frame is drawn from: a camera's pose and its projection. The camera looks down its +z, with +y up
// and +x right. The game's camera gives one, and in the editor the editor's camera does (see docs/editor.md#viewport).
View :: struct {
	position:     ecs.World_Position,
	// Camera to world.
	rotation:     quaternion128,
	// Vertical, in radians.
	vertical_fov: f32,
	// The near plane's distance in meters. The far plane is at infinity.
	near:         f32,
}

// view_projection maps a position relative to the view's position, as extract and pose_rows give them, to clip
// space. Depth is reversed: near / z for a view-space z, so 1 at the near plane and 0 at infinity. A float depth
// buffer has most of its precision near 0, so reversing puts it in the distance, where it is needed. A depth test of
// Greater against a clear of 0 suits it.
view_projection :: proc(view: View, aspect: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(view.vertical_fov * 0.5)
	projection := matrix[4, 4]f32{
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, 0, view.near,
		0, 0, 1, 0,
	}
	return projection * linalg.matrix4_from_quaternion_f32(conj(view.rotation))
}

// view_depth is the view-space z, the distance along the view's axis, of a depth that view_projection wrote.
view_depth :: proc(depth, near: f32) -> f32 {
	return near / max(depth, 1e-7)
}

// view_axes are the view's right, up and forward directions in the world.
view_axes :: proc(view: View) -> (right, up, forward: [3]f32) {
	right = linalg.quaternion128_mul_vector3(view.rotation, [3]f32{1, 0, 0})
	up = linalg.quaternion128_mul_vector3(view.rotation, [3]f32{0, 1, 0})
	forward = linalg.quaternion128_mul_vector3(view.rotation, [3]f32{0, 0, 1})
	return
}

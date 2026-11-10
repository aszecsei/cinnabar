package render

import "core:math"
import "core:math/linalg"

import "cinnabar:engine/ecs"

// Perspective is a projection whose far plane is at infinity.
Perspective :: struct {
	// Vertical, in radians.
	vertical_fov: f32,
	// The near plane's distance in meters.
	near:         f32,
}

// Orthographic is a projection without perspective, which a 2D game and the editor's Top, Front and Side views use
// (see docs/rendering/frame.md#orthographic-views).
Orthographic :: struct {
	// What the view shows from its bottom to its top, in meters.
	height: f32,
	// The near and the far plane's distances in meters. Near may be 0 or less, and far is past near.
	near:   f32,
	far:    f32,
}

// Projection is how a view maps what is in front of it to the screen.
Projection :: union #no_nil {
	Perspective,
	Orthographic,
}

// View is where a frame is drawn from: a camera's pose and its projection. The camera looks down its +z, with +y up
// and +x right. The game's camera gives one, and in the editor the editor's camera does (see docs/editor/viewport.md#viewport).
View :: struct {
	position:        ecs.World_Position,
	// Camera to world.
	rotation:        quaternion128,
	projection:      Projection,
	// The view model's projection (see docs/rendering/layers-and-output.md#view-model): its vertical field of view and its near plane.
	// 0 in either means the view's own. An orthographic view draws its view model with its own projection.
	view_model_fov:  f32,
	view_model_near: f32,
}

// perspective_view is a view with a perspective projection, at the origin.
perspective_view :: proc(rotation: quaternion128, vertical_fov, near: f32) -> View {
	return {rotation = rotation, projection = Perspective{vertical_fov, near}}
}

// orthographic_view is a view with an orthographic projection, at the origin.
orthographic_view :: proc(rotation: quaternion128, height, near, far: f32) -> View {
	return {rotation = rotation, projection = Orthographic{height, near, far}}
}

// is_orthographic is whether a view's projection is orthographic.
is_orthographic :: proc(view: View) -> bool {
	_, orthographic := view.projection.(Orthographic)
	return orthographic
}

// view_near is the distance of a view's near plane.
view_near :: proc(view: View) -> f32 {
	switch p in view.projection {
	case Perspective:
		return p.near
	case Orthographic:
		return p.near
	}
	return 0
}

// view_model_view is the view that the view model draws with: the view's pose, with the view model's projection.
view_model_view :: proc(view: View) -> View {
	v := view
	if p, perspective := view.projection.(Perspective); perspective {
		v.projection = Perspective {
			vertical_fov = view.view_model_fov > 0 ? view.view_model_fov : p.vertical_fov,
			near         = view.view_model_near > 0 ? view.view_model_near : p.near,
		}
	}
	return v
}

// View_Projection is a view's projection as the shaders take it, in a float4 (see view_projection.hlsli): the scales
// of a view-space x and y, the near plane and the far plane. A far plane of 0 is a perspective projection, whose
// scales are over the view-space z.
View_Projection :: [4]f32

// projection_constants is a view's projection for the shaders.
projection_constants :: proc(view: View, aspect: f32) -> View_Projection {
	switch p in view.projection {
	case Perspective:
		f := 1 / math.tan(p.vertical_fov * 0.5)
		return {f / aspect, f, p.near, 0}
	case Orthographic:
		return {2 / (p.height * aspect), 2 / p.height, p.near, p.far}
	}
	return {}
}

// limit_quality is the quality that a view draws at: an orthographic view (see
// docs/rendering/frame.md#orthographic-views) has no upscaler, no virtual shadow map and no screen-space or ray-traced
// reflections, which all take a perspective projection, so it draws with temporal AA, the cascades' shadow maps and
// the reflection probes in their place.
limit_quality :: proc(view: View, quality: Quality) -> Quality {
	q := quality
	if !is_orthographic(view) {
		return q
	}
	if _, upscales := upscaler_kind(q.aa); upscales {
		q.aa = .Taa
	}
	q.shadows.virtual = false
	if q.reflections.technique == .Screen || q.reflections.technique == .Ray_Traced {
		q.reflections.technique = .Probes
	}
	return q
}

// apply_view_limits turns off the settings that a view cannot draw: an orthographic view has no clouds, whose march
// starts at the camera. Its sky is the background color (see sky_draws).
apply_view_limits :: proc(settings: ^Frame_Settings, view: View) {
	if is_orthographic(view) {
		settings.clouds.off = true
	}
}

// view_projection maps a position relative to the view's position, as extract and pose_rows give them, to clip
// space. Depth is reversed: 1 at the near plane, and 0 at infinity in perspective, where it is near / z for a
// view-space z, or at the far plane in orthographic, where it is (far - z) / (far - near). A float depth buffer has
// most of its precision near 0, so reversing puts it in the distance, where it is needed. A depth test of Greater
// against a clear of 0 suits it.
view_projection :: proc(view: View, aspect: f32) -> matrix[4, 4]f32 {
	c := projection_constants(view, aspect)
	projection: matrix[4, 4]f32
	if c.w == 0 {
		projection = {
			c.x, 0, 0, 0,
			0, c.y, 0, 0,
			0, 0, 0, c.z,
			0, 0, 1, 0,
		}
	} else {
		range := c.w - c.z
		projection = {
			c.x, 0, 0, 0,
			0, c.y, 0, 0,
			0, 0, -1 / range, c.w / range,
			0, 0, 0, 1,
		}
	}
	return projection * linalg.matrix4_from_quaternion_f32(conj(view.rotation))
}

// view_depth is the view-space z, the distance along the view's axis, of a depth that view_projection wrote.
view_depth :: proc(projection: Projection, depth: f32) -> f32 {
	switch p in projection {
	case Perspective:
		return p.near / max(depth, 1e-7)
	case Orthographic:
		return p.far - depth * (p.far - p.near)
	}
	return 0
}

// pixel_meters is the size of a pixel at a view-space z, for a view of a height in pixels.
pixel_meters :: proc(view: View, z: f32, height: u32) -> f32 {
	switch p in view.projection {
	case Perspective:
		return 2 * z * math.tan(p.vertical_fov * 0.5) / f32(max(height, 1))
	case Orthographic:
		return p.height / f32(max(height, 1))
	}
	return 0
}

// view_corner is the view-space point at a normalized device x and y and a view-space z.
view_corner :: proc(c: View_Projection, ndc: [2]f32, z: f32) -> [3]f32 {
	if c.w == 0 {
		return {ndc.x / c.x * z, ndc.y / c.y * z, z}
	}
	return {ndc.x / c.x, ndc.y / c.y, z}
}

// view_axes are the view's right, up and forward directions in the world.
view_axes :: proc(view: View) -> (right, up, forward: [3]f32) {
	right = linalg.quaternion128_mul_vector3(view.rotation, [3]f32{1, 0, 0})
	up = linalg.quaternion128_mul_vector3(view.rotation, [3]f32{0, 1, 0})
	forward = linalg.quaternion128_mul_vector3(view.rotation, [3]f32{0, 0, 1})
	return
}

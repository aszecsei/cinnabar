package render

import "core:math"
import "core:math/linalg"
import "core:testing"

import "cinnabar:engine/ecs"

@(private = "file")
inside :: proc(planes: [5][4]f32, p: [3]f32, radius: f32) -> bool {
	for plane in planes {
		if linalg.dot(plane.xyz, p) + plane.w < -radius {
			return false
		}
	}
	return true
}

@(test)
frustum_planes_keep_what_the_view_sees :: proc(t: ^testing.T) {
	view := View {
		rotation     = 1,
		vertical_fov = math.PI / 2,
		near         = 0.1,
	}
	planes := frustum_planes(view_projection(view, 1))
	// Ahead, however far, is inside: the far plane is at infinity.
	testing.expect(t, inside(planes, {0, 0, 5}, 0))
	testing.expect(t, inside(planes, {0, 0, 1e6}, 0))
	// Behind the camera, nearer than the near plane, and beyond a side are outside.
	testing.expect(t, !inside(planes, {0, 0, -1}, 0.5))
	testing.expect(t, !inside(planes, {0, 0, 0.05}, 0))
	testing.expect(t, !inside(planes, {10, 0, 5}, 1))
	testing.expect(t, !inside(planes, {0, -10, 5}, 1))
	// A sphere that reaches into the view across a side is inside.
	testing.expect(t, inside(planes, {6, 0, 5}, 1))
}

@(test)
the_render_origin_snaps_to_cells :: proc(t: ^testing.T) {
	cell := i64(1) << ORIGIN_CELL_BITS
	p := ecs.World_Position{raw = {cell * 3 + 5, -5, cell * 2 - 1}}
	// Negative positions snap down to their cell's corner, as positive ones do.
	testing.expect_value(t, snap_origin(p).raw, [3]i64{cell * 3, -cell, cell})
	testing.expect_value(t, ORIGIN_CELL, 1024)
}

package render

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
project :: proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
	clip := m * [4]f32{p.x, p.y, p.z, 1}
	return clip.xyz / clip.w
}

@(test)
views_project_ahead_to_the_center :: proc(t: ^testing.T) {
	view := View {
		rotation     = 1,
		vertical_fov = math.PI / 2,
		near         = 0.1,
	}
	m := view_projection(view, 2)
	center := project(m, {0, 0, 5})
	testing.expect(t, abs(center.x) < 1e-6 && abs(center.y) < 1e-6)
	testing.expect(t, abs(project(m, {0, 0, 0.1}).z - 1) < 1e-6)
	testing.expect(t, abs(project(m, {0, 0, 0.2}).z - 0.5) < 1e-6)
	testing.expect(t, project(m, {0, 0, 1e12}).z < 1e-12)
	testing.expect(t, abs(view_depth(project(m, {0, 0, 3}).z, 0.1) - 3) < 1e-3)
	// A 90° field of view reaches the top edge at 45°, and the aspect ratio halves the horizontal.
	testing.expect(t, abs(project(m, {0, 5, 5}).y - 1) < 1e-6)
	testing.expect(t, abs(project(m, {5, 0, 5}).x - 0.5) < 1e-6)
}

@(test)
views_turn_with_their_rotation :: proc(t: ^testing.T) {
	// Turned to face +x, the view sees +x straight ahead, and +z to its left.
	view := View {
		rotation     = linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0}),
		vertical_fov = math.PI / 2,
		near         = 0.1,
	}
	_, _, forward := view_axes(view)
	testing.expect(t, linalg.length(forward - {1, 0, 0}) < 1e-6)
	m := view_projection(view, 1)
	ahead := project(m, {4, 0, 0})
	testing.expect(t, abs(ahead.x) < 1e-6 && ahead.z > 0)
	testing.expect(t, project(m, {4, 0, 2}).x < 0)
}

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
		rotation   = 1,
		projection = Perspective{math.PI / 2, 0.1},
	}
	m := view_projection(view, 2)
	center := project(m, {0, 0, 5})
	testing.expect(t, abs(center.x) < 1e-6 && abs(center.y) < 1e-6)
	testing.expect(t, abs(project(m, {0, 0, 0.1}).z - 1) < 1e-6)
	testing.expect(t, abs(project(m, {0, 0, 0.2}).z - 0.5) < 1e-6)
	testing.expect(t, project(m, {0, 0, 1e12}).z < 1e-12)
	testing.expect(t, abs(view_depth(view.projection, project(m, {0, 0, 3}).z) - 3) < 1e-3)
	// A 90° field of view reaches the top edge at 45°, and the aspect ratio halves the horizontal.
	testing.expect(t, abs(project(m, {0, 5, 5}).y - 1) < 1e-6)
	testing.expect(t, abs(project(m, {5, 0, 5}).x - 0.5) < 1e-6)
}

@(test)
views_turn_with_their_rotation :: proc(t: ^testing.T) {
	// Turned to face +x, the view sees +x straight ahead, and +z to its left.
	view := View {
		rotation   = linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0}),
		projection = Perspective{math.PI / 2, 0.1},
	}
	_, _, forward := view_axes(view)
	testing.expect(t, linalg.length(forward - {1, 0, 0}) < 1e-6)
	m := view_projection(view, 1)
	ahead := project(m, {4, 0, 0})
	testing.expect(t, abs(ahead.x) < 1e-6 && ahead.z > 0)
	testing.expect(t, project(m, {4, 0, 2}).x < 0)
}

@(test)
the_view_model_takes_the_views_projection_unless_it_has_its_own :: proc(t: ^testing.T) {
	view := View{rotation = 1, projection = Perspective{1.2, 0.05}}
	testing.expect_value(t, view_model_view(view), view)
	view.view_model_fov, view.view_model_near = 0.9, 0.01
	own := view_model_view(view)
	testing.expect_value(t, own.projection, Perspective{0.9, 0.01})
	testing.expect_value(t, own.rotation, view.rotation)
	// An orthographic view draws its view model with its own projection.
	flat := orthographic_view(1, 10, 0.1, 100)
	flat.view_model_fov, flat.view_model_near = 0.9, 0.01
	testing.expect_value(t, view_model_view(flat), flat)
}

@(test)
an_orthographic_view_maps_its_near_plane_to_one_and_its_far_plane_to_zero :: proc(t: ^testing.T) {
	view := orthographic_view(1, 10, 0.5, 100)
	testing.expect(t, is_orthographic(view))
	testing.expect_value(t, view_near(view), 0.5)
	m := view_projection(view, 2)
	testing.expect(t, abs(project(m, {0, 0, 0.5}).z - 1) < 1e-6)
	testing.expect(t, abs(project(m, {0, 0, 100}).z) < 1e-6)
	// A point is at the same place on the screen at every distance: 10 m show from bottom to top, and 20 m across.
	for z in ([]f32{1, 40, 99}) {
		p := project(m, {5, 2.5, z})
		testing.expect(t, abs(p.x - 0.5) < 1e-6 && abs(p.y - 0.5) < 1e-6)
		testing.expect(t, abs(view_depth(view.projection, p.z) - z) < 1e-3)
	}
	// The far plane clips.
	planes := frustum_planes_6(m)
	inside := proc(planes: [6][4]f32, p: [3]f32) -> bool {
		for plane in planes {
			if linalg.dot(plane.xyz, p) + plane.w < 0 {
				return false
			}
		}
		return true
	}
	testing.expect(t, inside(planes, {0, 0, 50}))
	testing.expect(t, !inside(planes, {0, 0, 101}))
	testing.expect(t, !inside(planes, {0, 0, 0.4}))
	testing.expect(t, !inside(planes, {11, 0, 50}))
}

@(test)
the_shaders_projection_gives_back_what_the_matrix_placed :: proc(t: ^testing.T) {
	for view in ([]View{perspective_view(1, 1.1, 0.05), orthographic_view(1, 8, 0.25, 60)}) {
		aspect: f32 = 1.5
		m := view_projection(view, aspect)
		c := projection_constants(view, aspect)
		testing.expect_value(t, c.w != 0, is_orthographic(view))
		p := [3]f32{1.5, -0.75, 12}
		ndc := project(m, p)
		testing.expect(t, linalg.length(view_corner(c, ndc.xy, p.z) - p) < 1e-4)
		// A pixel's size: a meter up moves a point by its inverse.
		above := project(m, p + {0, 1, 0})
		pixels := (above.y - ndc.y) * 0.5 * 720
		testing.expect(t, abs(pixel_meters(view, p.z, 720) * pixels - 1) < 1e-4)
	}
}

@(test)
an_orthographic_view_draws_without_what_takes_a_perspective :: proc(t: ^testing.T) {
	quality := Quality {
		aa          = .Fsr,
		shadows     = {virtual = true},
		reflections = {technique = .Screen},
	}
	testing.expect_value(t, limit_quality(perspective_view(1, 1, 0.05), quality), quality)
	flat := orthographic_view(1, 10, 0.1, 100)
	q := limit_quality(flat, quality)
	testing.expect_value(t, q.aa, Aa_Technique.Taa)
	testing.expect(t, !q.shadows.virtual)
	testing.expect_value(t, q.reflections.technique, Reflection_Technique.Probes)
	quality.reflections.technique, quality.aa = .Ray_Traced, .Smaa
	q = limit_quality(flat, quality)
	testing.expect_value(t, q.reflections.technique, Reflection_Technique.Probes)
	testing.expect_value(t, q.aa, Aa_Technique.Smaa)
	settings: Frame_Settings
	apply_view_limits(&settings, perspective_view(1, 1, 0.05))
	testing.expect(t, !settings.clouds.off)
	apply_view_limits(&settings, flat)
	testing.expect(t, settings.clouds.off)
}

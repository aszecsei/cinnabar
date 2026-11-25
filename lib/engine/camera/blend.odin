package camera

import "core:math/linalg"

import core_math "cinnabar:core/math"
import "cinnabar:engine/ecs"
import "cinnabar:engine/render"

// Curve is the shape of a blend's progress.
Curve :: enum u8 {
	Linear,
	Smooth,
	Ease_In,
	Ease_Out,
}

// Clock is the time that a blend runs on. Game time is 0 while the game is paused or in the editor's Edit, so a game
// blend stops there; real time goes on, for cameras that ignore pause.
Clock :: enum u8 {
	Game,
	Real,
}

// Blend is how a view moves from one camera to the next.
Blend :: struct {
	// In seconds. 0 or less is a cut.
	duration: f32,
	curve:    Curve,
	clock:    Clock,
}

// CUT is the change with no blend.
CUT :: Blend{}

// CURVE_EASE is the easing of each blend curve. Curve is a stored subset of core_math.Ease, with its own numbers.
@(rodata)
CURVE_EASE := [Curve]core_math.Ease {
	.Linear   = .Linear,
	.Smooth   = .Smoothstep,
	.Ease_In  = .In_Quad,
	.Ease_Out = .Out_Quad,
}

// ease maps a blend's progress, 0 to 1, along the curve. It is 0 at 0 and 1 at 1.
ease :: proc "contextless" (curve: Curve, t: f32) -> f32 {
	return core_math.ease(CURVE_EASE[curve], t)
}

// blend_views is the view a fraction t of the way from a to b. The position goes straight, and the rotation takes the
// shortest arc. A perspective lens blends its field of view and its near plane, and an orthographic lens its height and
// its planes. Views of different kinds cannot blend their lenses, so the lens snaps to b's. Two perspective views blend
// their physical lens too (see blend_physical_lens).
blend_views :: proc(a, b: render.View, t: f32) -> render.View {
	if t <= 0 {
		return a
	}
	if t >= 1 {
		return b
	}
	view := b
	view.position = ecs.position_lerp(a.position, b.position, t)
	view.rotation = linalg.quaternion_slerp(a.rotation, b.rotation, t)
	switch from in a.projection {
	case render.Perspective:
		if to, same := b.projection.(render.Perspective); same {
			view.projection = render.Perspective {
				vertical_fov = linalg.lerp(from.vertical_fov, to.vertical_fov, t),
				near         = linalg.lerp(from.near, to.near, t),
			}
			view.view_model_fov = blend_lens(
				a.view_model_fov,
				from.vertical_fov,
				b.view_model_fov,
				to.vertical_fov,
				t,
			)
			view.view_model_near = blend_lens(
				a.view_model_near,
				from.near,
				b.view_model_near,
				to.near,
				t,
			)
			view.lens = blend_physical_lens(a.lens, b.lens, t)
		}
	case render.Orthographic:
		if to, same := b.projection.(render.Orthographic); same {
			view.projection = render.Orthographic {
				height = linalg.lerp(from.height, to.height, t),
				near   = linalg.lerp(from.near, to.near, t),
				far    = linalg.lerp(from.far, to.far, t),
			}
		}
	}
	return view
}

// blend_lens blends a view model's field of view or near plane, where 0 means the view's own. A view that has its own
// on both sides keeps following it, and a side with a value blends from or to the other side's own, not through 0.
@(private)
blend_lens :: proc(a, a_own, b, b_own, t: f32) -> f32 {
	if a == 0 && b == 0 {
		return 0
	}
	return linalg.lerp(a if a > 0 else a_own, b if b > 0 else b_own, t)
}

// blend_physical_lens blends the lenses that give the depth of field (see docs/rendering/post-processing.md#depth-of-field).
// The aperture blends as 1 / f-number, which is 0 without depth of field, so the blur eases in and out as the lens's
// opening does rather than through f/0.1. A side without depth of field takes the other's sensor and focus, so only
// the opening changes.
@(private)
blend_physical_lens :: proc(a, b: render.Lens, t: f32) -> render.Lens {
	if a.aperture <= 0 && b.aperture <= 0 {
		return {}
	}
	from, to := a, b
	if from.aperture <= 0 {
		from = {
			sensor_height  = to.sensor_height,
			focus_distance = to.focus_distance,
		}
	}
	if to.aperture <= 0 {
		to = {
			sensor_height  = from.sensor_height,
			focus_distance = from.focus_distance,
		}
	}
	opening := linalg.lerp(
		from.aperture > 0 ? 1 / from.aperture : 0,
		to.aperture > 0 ? 1 / to.aperture : 0,
		t,
	)
	if opening <= 0 {
		return {}
	}
	return {
		sensor_height = linalg.lerp(from.sensor_height, to.sensor_height, t),
		aperture = 1 / opening,
		focus_distance = linalg.lerp(from.focus_distance, to.focus_distance, t),
	}
}

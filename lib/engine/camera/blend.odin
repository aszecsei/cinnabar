package camera

import "core:math/linalg"

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

// ease maps a blend's progress, 0 to 1, along the curve. It is 0 at 0 and 1 at 1.
ease :: proc(curve: Curve, t: f32) -> f32 {
	x := clamp(t, 0, 1)
	switch curve {
	case .Linear:
		return x
	case .Smooth:
		return x * x * (3 - 2 * x)
	case .Ease_In:
		return x * x
	case .Ease_Out:
		return 1 - (1 - x) * (1 - x)
	}
	return x
}

// blend_views is the view a fraction t of the way from a to b. The position goes straight, and the rotation takes the
// shortest arc. A perspective lens blends its field of view and its near plane, and an orthographic lens its height and
// its planes. Views of different kinds cannot blend their lenses, so the lens snaps to b's.
//
// The lens fields that #532 adds to a view are blended here, in the same way.
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

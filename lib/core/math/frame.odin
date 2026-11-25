package core_math

import "core:math"
import "core:math/linalg"

// Frame is an orientation on a 3D path: where it is, which way it goes, and which ways are up and to the side. binormal,
// normal and tangent are the frame's x, y and z axes, right-handed (binormal is normal × tangent), so a profile drawn
// in x and y sweeps along the path's z (see docs/core/math.md#frames).
Frame :: struct($F: typeid) {
	position: [3]F,
	tangent:  [3]F,
	normal:   [3]F,
	binormal: [3]F,
}

// frames_rotation_minimizing fills out with a frame at each of params, a spline's parameters in rising order, that
// turns about the tangent as little as the path lets it: the frame for a tube, a cable or a ribbon, which does not
// twist. The first frame's normal is up, made square to the tangent. Each next frame is the last one reflected twice,
// to the next point and then to its tangent (Wang, Jüttler, Zheng and Liu, "Computation of rotation minimizing frames",
// 2008), so close params, as arc_length_spaced gives, make close frames. A closed spline also spreads, over its length,
// the turn that the frames take once around, so the last joins the first.
frames_rotation_minimizing :: proc "contextless" (
	s: Spline([3]$F),
	params: []F,
	up: [3]F,
	out: []Frame(F),
) {
	n := len(params)
	if n == 0 {
		return
	}
	out[0] = frame_up(s, params[0], up)
	for i in 1 ..< n {
		out[i] = frame_transport(
			out[i - 1],
			spline_point(s, params[i]),
			spline_tangent(s, params[i]),
		)
	}
	count := F(spline_segment_count(s))
	if !s.closed || count <= 0 {
		return
	}
	// Once more around to the start: the angle that the transported normal is off from the first normal there.
	around := frame_transport(out[n - 1], out[0].position, out[0].tangent)
	t0 := out[0].tangent
	off := math.atan2(
		linalg.dot(linalg.cross(around.normal, out[0].normal), t0),
		linalg.dot(around.normal, out[0].normal),
	)
	for i in 1 ..< n {
		part := (params[i] - params[0]) / count
		out[i] = frame_turn(out[i], off * part)
	}
}

// frame_up is the frame at a spline's parameter t whose normal is as close to up as the tangent lets it: the frame for
// a road or a rail, which keeps upright, turned about the tangent by bank radians. Where the path goes straight along
// up, it takes another normal.
frame_up :: proc "contextless" (s: Spline([3]$F), t: F, up: [3]F, bank: F = 0) -> Frame(F) {
	f: Frame(F)
	f.position = spline_point(s, t)
	f.tangent = frame_unit(spline_tangent(s, t), {0, 0, 1})
	f.normal = frame_square(up, f.tangent)
	f.binormal = linalg.cross(f.normal, f.tangent)
	return frame_turn(f, bank)
}

// frame_frenet is the Frenet frame at a spline's parameter t: the normal points to the centre of the path's turn,
// which flips where the path bends the other way, so it suits measuring a curve, not sweeping one. ok is false where
// the path is straight and has no such normal.
frame_frenet :: proc "contextless" (s: Spline([3]$F), t: F) -> (f: Frame(F), ok: bool) {
	i, u := spline_locate(s, t)
	c := spline_segment(s, i)
	f.position = bezier_point(c, u)
	f.tangent = frame_unit(bezier_tangent(c, u), {0, 0, 1})
	bend := bezier_second(c, u)
	bend -= linalg.dot(bend, f.tangent) * f.tangent
	length := linalg.length(bend)
	if length < 1e-6 {
		return f, false
	}
	f.normal = bend / length
	f.binormal = linalg.cross(f.normal, f.tangent)
	return f, true
}

// frame_point is a point given in a frame's axes: x along the binormal, y along the normal and z along the tangent.
frame_point :: proc "contextless" (f: Frame($F), local: [3]F) -> [3]F {
	return f.position + local.x * f.binormal + local.y * f.normal + local.z * f.tangent
}

// frame_matrix is a frame as a transform from its axes to the spline's space.
frame_matrix :: proc "contextless" (f: Frame(f32)) -> matrix[4, 4]f32 {
	b, n, t, p := f.binormal, f.normal, f.tangent, f.position
	return matrix[4, 4]f32{
		b.x, n.x, t.x, p.x,
		b.y, n.y, t.y, p.y,
		b.z, n.z, t.z, p.z,
		0, 0, 0, 1,
	}
}

// frame_rotation is a frame's orientation, which turns z to the tangent and y to the normal: a prop's rotation along a
// path.
frame_rotation :: proc "contextless" (f: Frame(f32)) -> quaternion128 {
	b, n, t := f.binormal, f.normal, f.tangent
	return linalg.normalize(linalg.quaternion_from_matrix3_f32(matrix[3, 3]f32{
			b.x, n.x, t.x,
			b.y, n.y, t.y,
			b.z, n.z, t.z,
		}))
}

// sweep_points fills out with a profile, points in a frame's x and y, placed at each frame in turn: ring r's point k is
// out[r * len(profile) + k]. The caller makes the triangles between rings, and their normals.
sweep_points :: proc "contextless" (frames: []Frame($F), profile: [][2]F, out: [][3]F) {
	for f, r in frames {
		for p, k in profile {
			out[r * len(profile) + k] = frame_point(f, {p.x, p.y, 0})
		}
	}
}

// frame_transport is a frame carried to a point with a tangent by the double reflection.
@(private)
frame_transport :: proc "contextless" (f: Frame($F), position, velocity: [3]F) -> Frame(F) {
	next := Frame(F) {
		position = position,
		tangent  = frame_unit(velocity, f.tangent),
	}
	v1 := position - f.position
	c1 := linalg.dot(v1, v1)
	normal := f.normal
	if c1 > 0 {
		r := f.normal - (2 / c1) * linalg.dot(v1, f.normal) * v1
		t := f.tangent - (2 / c1) * linalg.dot(v1, f.tangent) * v1
		v2 := next.tangent - t
		c2 := linalg.dot(v2, v2)
		normal = r - (2 / c2) * linalg.dot(v2, r) * v2 if c2 > 0 else r
	}
	next.normal = frame_square(normal, next.tangent)
	next.binormal = linalg.cross(next.normal, next.tangent)
	return next
}

// frame_turn is a frame turned about its tangent by angle radians.
@(private)
frame_turn :: proc "contextless" (f: Frame($F), angle: F) -> Frame(F) {
	if angle == 0 {
		return f
	}
	c, s := math.cos(angle), math.sin(angle)
	g := f
	g.normal = f.normal * c + linalg.cross(f.tangent, f.normal) * s
	g.binormal = linalg.cross(g.normal, g.tangent)
	return g
}

// frame_unit is v at a length of 1, or otherwise where v has none.
@(private)
frame_unit :: proc "contextless" (v, otherwise: [3]$F) -> [3]F {
	length := linalg.length(v)
	return v / length if length > 1e-9 else otherwise
}

// frame_square is v made square to a unit tangent and of a length of 1: the up of a frame. Where v is along the
// tangent, it is another axis square to it.
@(private)
frame_square :: proc "contextless" (v, tangent: [3]$F) -> [3]F {
	square := v - linalg.dot(v, tangent) * tangent
	if linalg.length(square) > 1e-6 {
		return linalg.normalize(square)
	}
	axis := [3]F{1, 0, 0} if abs(tangent.x) < 0.9 else [3]F{0, 1, 0}
	return linalg.normalize(axis - linalg.dot(axis, tangent) * tangent)
}

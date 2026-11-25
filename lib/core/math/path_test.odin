package core_math

import "core:math"
import "core:math/linalg"
import "core:testing"

@(private = "file")
close3 :: proc(a, b: [3]f32, tolerance: f32) -> bool {
	return linalg.length(a - b) <= tolerance
}

@(test)
a_split_segment_is_the_same_curve :: proc(t: ^testing.T) {
	c := [4][3]f32{{0, 0, 0}, {1, 2, 0}, {3, 2, 1}, {4, 0, 0}}
	left, right := bezier_split(c, f32(0.3))
	for i in 0 ..= 10 {
		u := f32(i) / 10
		testing.expect(t, close3(bezier_point(left, u), bezier_point(c, u * 0.3), 1e-5))
		testing.expect(t, close3(bezier_point(right, u), bezier_point(c, 0.3 + u * 0.7), 1e-5))
	}
	part := bezier_sub(c, f32(0.2), f32(0.6))
	testing.expect(t, close3(bezier_point(part, 0), bezier_point(c, f32(0.2)), 1e-5))
	testing.expect(t, close3(bezier_point(part, 1), bezier_point(c, f32(0.6)), 1e-5))
	testing.expect(t, close3(bezier_point(part, 0.5), bezier_point(c, f32(0.4)), 1e-5))
}

@(test)
the_derivatives_are_the_curve_s_rates :: proc(t: ^testing.T) {
	c := [4][2]f64{{0, 0}, {1, 3}, {2, -1}, {4, 1}}
	H :: 1e-5
	for i in 1 ..< 10 {
		u := f64(i) / 10
		fd := (bezier_point(c, u + H) - bezier_point(c, u - H)) / (2 * H)
		testing.expect(t, linalg.length(fd - bezier_tangent(c, u)) < 1e-6)
		sd := (bezier_tangent(c, u + H) - bezier_tangent(c, u - H)) / (2 * H)
		testing.expect(t, linalg.length(sd - bezier_second(c, u)) < 1e-5)
	}
	// A scalar segment is the exact kernel's cubic.
	s := [4]f64{0.25, 1, -2, 3}
	testing.expect(t, abs(bezier_point(s, 0.4) - cubic(0.25, 1, -2, 3, 0.4)) < 1e-12)
}

@(test)
the_bounds_hold_every_point :: proc(t: ^testing.T) {
	c := [4][3]f32{{0, 0, 0}, {-2, 5, 1}, {6, -4, 1}, {4, 0, 0}}
	lo, hi := bezier_bounds(c)
	seen_lo, seen_hi := c[0], c[0]
	for i in 0 ..= 1000 {
		p := bezier_point(c, f32(i) / 1000)
		for k in 0 ..< 3 {
			testing.expect(t, p[k] >= lo[k] - 1e-5 && p[k] <= hi[k] + 1e-5)
		}
		seen_lo, seen_hi = linalg.min(seen_lo, p), linalg.max(seen_hi, p)
	}
	testing.expect(t, close3(seen_lo, lo, 1e-3) && close3(seen_hi, hi, 1e-3), "and they are tight")
}

@(test)
a_straight_segment_is_as_long_as_its_ends_are_apart :: proc(t: ^testing.T) {
	line := line_to_bezier([3]f32{1, 2, 3}, [3]f32{4, 6, 3})
	testing.expect(t, abs(bezier_length(line) - 5) < 1e-5)
	testing.expect(t, abs(bezier_length(line, f32(0.2), f32(0.6)) - 2) < 1e-5)
	u, d := bezier_closest(line, [3]f32{2.5, 4, 10})
	testing.expect(t, abs(u - 0.5) < 1e-4 && abs(d - 49) < 1e-3)
}

@(test)
each_kind_converts_to_the_curve_it_names :: proc(t: ^testing.T) {
	// Hermite: the ends and their tangents.
	h := hermite_to_bezier([2]f32{0, 0}, [2]f32{3, 0}, [2]f32{1, 1}, [2]f32{0, 3})
	testing.expect(
		t,
		bezier_tangent(h, f32(0)) == [2]f32{3, 0} && bezier_tangent(h, f32(1)) == [2]f32{0, 3},
	)
	// Catmull-Rom passes through its middle points, with a tangent of half the change across its neighbours.
	p := [4][2]f32{{0, 0}, {1, 1}, {3, 1}, {4, 0}}
	for alpha in ([?]f32{0, 0.5, 1}) {
		c := catmull_rom_to_bezier(p[0], p[1], p[2], p[3], alpha)
		testing.expect(t, bezier_point(c, f32(0)) == p[1] && bezier_point(c, f32(1)) == p[2])
	}
	uniform := catmull_rom_to_bezier(p[0], p[1], p[2], p[3], f32(0))
	testing.expect(t, linalg.length(bezier_tangent(uniform, f32(0)) - (p[2] - p[0]) / 2) < 1e-5)
	// A B-spline of points on a line is on the line, and of equal points is that point.
	b := bspline_to_bezier(f32(0), 1, 2, 3)
	testing.expect(
		t,
		abs(bezier_point(b, f32(0)) - 1) < 1e-6 && abs(bezier_point(b, f32(1)) - 2) < 1e-6,
	)
	same := bspline_to_bezier([3]f32{2, 2, 2}, {2, 2, 2}, {2, 2, 2}, {2, 2, 2})
	testing.expect(t, close3(bezier_point(same, f32(0.37)), {2, 2, 2}, 1e-6))
}

@(test)
centripetal_catmull_rom_makes_no_loop :: proc(t: ^testing.T) {
	// Close middle points between far neighbours: the uniform curve loops past its end, and the centripetal one does
	// not, so it never goes beyond p2 along x.
	p := [4][2]f32{{0, 0}, {10, 0}, {10.5, 0.5}, {10, 10}}
	centripetal := catmull_rom_to_bezier(p[0], p[1], p[2], p[3], f32(0.5))
	uniform := catmull_rom_to_bezier(p[0], p[1], p[2], p[3], f32(0))
	_, hi := bezier_bounds(centripetal)
	_, uniform_hi := bezier_bounds(uniform)
	testing.expectf(t, hi.x <= 10.6, "centripetal reaches %v", hi.x)
	testing.expect(t, uniform_hi.x > hi.x)
}

@(test)
a_spline_counts_and_finds_its_segments :: proc(t: ^testing.T) {
	five := [][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {4, 0, 0}}
	seven := [][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {4, 0, 0}, {5, 0, 0}, {6, 0, 0}}
	Case :: struct {
		kind:         Spline_Kind,
		points:       [][3]f32,
		open, closed: int,
	}
	cases := []Case {
		{.Linear, five, 4, 5},
		{.Catmull_Rom, five, 4, 5},
		{.B_Spline, five, 2, 5},
		{.Bezier, seven, 2, 2},
		{.Hermite, five[:4], 1, 2},
	}
	for c in cases {
		testing.expectf(
			t,
			spline_segment_count(Spline([3]f32){points = c.points, kind = c.kind}) == c.open,
			"%v",
			c.kind,
		)
		testing.expectf(
			t,
			spline_segment_count(
				Spline([3]f32){points = c.points, kind = c.kind, closed = true},
			) ==
			c.closed,
			"%v closed",
			c.kind,
		)
	}
	testing.expect_value(
		t,
		spline_segment_count(Spline([3]f32){points = five[:1], kind = .Catmull_Rom}),
		0,
	)

	open := Spline([3]f32) {
		points = five,
		kind   = .Linear,
	}
	i, u := spline_locate(open, f32(2.25))
	testing.expect(t, i == 2 && u == 0.25)
	i, u = spline_locate(open, f32(9))
	testing.expect(t, i == 3 && u == 1)
	testing.expect(t, close3(spline_point(open, f32(2.5)), {2.5, 0, 0}, 1e-6))
	loop := open
	loop.closed = true
	i, u = spline_locate(loop, f32(-0.5))
	testing.expect(t, i == 4 && u == 0.5)
	// An open Catmull-Rom spline starts and ends at its end points.
	cr := Spline([3]f32) {
		points = five,
		kind   = .Catmull_Rom,
		alpha  = 0.5,
	}
	testing.expect(
		t,
		close3(spline_point(cr, f32(0)), five[0], 1e-6) &&
		close3(spline_point(cr, f32(4)), five[4], 1e-6),
	)
	at, d := spline_closest(cr, [3]f32{2.5, 1, 0})
	testing.expect(t, abs(at - 2.5) < 1e-3 && abs(d - 1) < 1e-3)
}

// circle is a closed Catmull-Rom spline through n points on a circle of radius r about the origin, in the x-z plane.
@(private = "file")
circle :: proc(points: [][3]f32, r: f32) -> Spline([3]f32) {
	for &p, i in points {
		a := 2 * math.PI * f32(i) / f32(len(points))
		p = {r * math.cos(a), 0, r * math.sin(a)}
	}
	return {points = points, kind = .Catmull_Rom, closed = true, alpha = 0.5}
}

@(test)
the_arc_length_maps_distance_and_parameter :: proc(t: ^testing.T) {
	points: [16][3]f32
	s := circle(points[:], 3)
	table: [16 * 8 + 1]f32
	a := arc_length_build(s, 8, table[:])
	testing.expect_value(t, len(a.cumulative), arc_length_count(s, 8))
	total := arc_length_total(a)
	testing.expectf(t, abs(total - 6 * math.PI) < 0.01, "%v around", total)
	for i in 0 ..< 40 {
		distance := total * f32(i) / 40
		param := arc_length_param(a, s, distance)
		back := arc_length_distance(a, s, param)
		testing.expectf(t, abs(back - distance) < 1e-3, "%v: %v back", distance, back)
	}
	// A closed spline wraps a distance past its length or before its start.
	testing.expect(t, abs(arc_length_param(a, s, total + 1) - arc_length_param(a, s, 1)) < 1e-4)
	// Evenly spaced parameters are an even distance apart along the path.
	params: [12]f32
	arc_length_spaced(a, s, params[:])
	for i in 1 ..< len(params) {
		step := arc_length_distance(a, s, params[i]) - arc_length_distance(a, s, params[i - 1])
		testing.expectf(t, abs(step - total / 12) < 1e-3, "step %d: %v", i, step)
	}
	// An open spline's even spacing includes both ends.
	line := Spline([3]f32) {
		points = points[:4],
		kind   = .Linear,
	}
	ltable: [3 * 4 + 1]f32
	la := arc_length_build(line, 4, ltable[:])
	ends: [5]f32
	arc_length_spaced(la, line, ends[:])
	testing.expect(t, ends[0] == 0 && abs(ends[4] - 3) < 1e-4)
}

@(test)
rotation_minimizing_frames_do_not_twist :: proc(t: ^testing.T) {
	// A helix about y: its rotation-minimizing frames stay square, and close frames turn little about their tangent.
	knots: [24][3]f32
	for &k, i in knots {
		a := f32(i) * 0.5
		k = {2 * math.cos(a), f32(i) * 0.3, 2 * math.sin(a)}
	}
	helix := Spline([3]f32) {
		points = knots[:],
		kind   = .Catmull_Rom,
		alpha  = 0.5,
	}
	table: [23 * 8 + 1]f32
	a := arc_length_build(helix, 8, table[:])
	params: [64]f32
	arc_length_spaced(a, helix, params[:])
	frames: [64]Frame(f32)
	frames_rotation_minimizing(helix, params[:], {0, 1, 0}, frames[:])
	for f, i in frames {
		testing.expectf(
			t,
			abs(linalg.length(f.normal) - 1) < 1e-4 && abs(linalg.dot(f.normal, f.tangent)) < 1e-4,
			"frame %d",
			i,
		)
		testing.expect(
			t,
			close3(linalg.cross(f.binormal, f.normal), f.tangent, 1e-4),
			"right-handed",
		)
		if i > 0 {
			// The normal's change has no part about the tangent, to first order: it turns only with the tangent.
			prev := frames[i - 1]
			twist := linalg.dot(f.normal - prev.normal, f.binormal)
			testing.expectf(t, abs(twist) < 0.01, "frame %d twists %v", i, twist)
		}
	}
	m := frame_matrix(frames[10])
	testing.expect(t, close3((m * [4]f32{0, 0, 0, 1}).xyz, frames[10].position, 1e-5))
	q := frame_rotation(frames[10])
	testing.expect(
		t,
		close3(linalg.quaternion_mul_vector3(q, [3]f32{0, 0, 1}), frames[10].tangent, 1e-4),
	)
	testing.expect(
		t,
		close3(linalg.quaternion_mul_vector3(q, [3]f32{0, 1, 0}), frames[10].normal, 1e-4),
	)
}

@(test)
a_closed_loop_s_frames_join :: proc(t: ^testing.T) {
	// A trefoil knot, whose frames, carried once around, come back turned about the tangent: the correction spreads
	// that turn over the loop, so the last frame, carried on to the start, meets the first.
	points: [24][3]f32
	for &p, i in points {
		a := 2 * math.PI * f32(i) / 24
		p = {
			math.sin(a) + 2 * math.sin(2 * a),
			math.cos(a) - 2 * math.cos(2 * a),
			-math.sin(3 * a),
		}
	}
	loop := Spline([3]f32) {
		points = points[:],
		kind   = .Catmull_Rom,
		closed = true,
		alpha  = 0.5,
	}
	table: [24 * 8 + 1]f32
	a := arc_length_build(loop, 8, table[:])
	params: [192]f32
	arc_length_spaced(a, loop, params[:])
	// Without the correction, the turn once around is well away from 0.
	carried: [192]Frame(f32)
	carried[0] = frame_up(loop, params[0], {0, 1, 0})
	for i in 1 ..< len(params) {
		carried[i] = frame_transport(
			carried[i - 1],
			spline_point(loop, params[i]),
			spline_tangent(loop, params[i]),
		)
	}
	open_end := frame_transport(carried[len(params) - 1], carried[0].position, carried[0].tangent)
	turn := math.acos(clamp(linalg.dot(open_end.normal, carried[0].normal), -1, 1))
	testing.expectf(t, turn > 0.3, "the knot turns its frames by %v once around", turn)
	frames: [192]Frame(f32)
	frames_rotation_minimizing(loop, params[:], {0, 1, 0}, frames[:])
	around := frame_transport(frames[len(params) - 1], frames[0].position, frames[0].tangent)
	testing.expectf(
		t,
		close3(around.normal, frames[0].normal, 0.02),
		"%v and %v",
		around.normal,
		frames[0].normal,
	)
	// An up frame keeps its normal near up, and a bank turns it about the tangent.
	road := frame_up(loop, f32(1), {0, 1, 0})
	testing.expect(t, road.normal.y > 0.9)
	banked := frame_up(loop, f32(1), {0, 1, 0}, math.PI / 2)
	testing.expect(t, abs(linalg.dot(banked.normal, road.normal)) < 1e-4)
	_, straight := frame_frenet(Spline([3]f32){points = points[:2], kind = .Linear}, f32(0.5))
	testing.expect(t, !straight, "a line has no Frenet normal")
	// A sweep places each ring's profile in its frame.
	profile := [][2]f32{{1, 0}, {0, 1}}
	out: [2 * 2][3]f32
	sweep_points(frames[:2], profile, out[:])
	testing.expect(t, close3(out[0], frames[0].position + frames[0].binormal, 1e-5))
	testing.expect(t, close3(out[3], frames[1].position + frames[1].normal, 1e-5))
}

@(test)
linear_keys_hold_and_bake :: proc(t: ^testing.T) {
	keys := []Linear_Key([4]f32){{0.25, {1, 1, 1, 0}}, {0.5, {0, 0, 0, 1}}, {1, {1, 0, 0, 1}}}
	testing.expect_value(t, linear_value(keys, 0), [4]f32{1, 1, 1, 0})
	testing.expect_value(t, linear_value(keys, 0.5), [4]f32{0, 0, 0, 1})
	testing.expect_value(t, linear_value(keys, 0.375), [4]f32{0.5, 0.5, 0.5, 0.5})
	testing.expect_value(t, linear_value(keys, 0.75), [4]f32{0.5, 0, 0, 1})
	row: [5][4]f32
	linear_bake(keys, row[:], {9, 9, 9, 9})
	testing.expect(
		t,
		row[0] == keys[0].value && row[2] == keys[1].value && row[4] == keys[2].value,
	)
	linear_bake([]Linear_Key([4]f32){}, row[:], {9, 9, 9, 9})
	testing.expect_value(t, row[3], [4]f32{9, 9, 9, 9})
}

@(test)
untyped_parameters_take_the_points_float :: proc(t: ^testing.T) {
	c := [4][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}}
	testing.expect(t, close3(bezier_point(c, 0.5), {1.5, 0, 0}, 1e-6))
	left, _ := bezier_split(c, 0.5)
	testing.expect(t, close3(left[3], {1.5, 0, 0}, 1e-6))
	testing.expect(t, abs(bezier_length(c) - 3) < 1e-5)
	s := Spline([3]f32) {
		points = c[:],
		kind   = .Linear,
	}
	testing.expect(t, close3(spline_point(s, 1.5), {1.5, 0, 0}, 1e-6))
	wide := [4]f64{0, 1, 2, 3}
	testing.expect(t, bezier_point(wide, 0.5) == 1.5)
}

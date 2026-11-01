package anim_graph

import "core:math"
import "core:math/linalg"

// root_motion is how far the root joint moved in the tick, over the samples that played, by their weights: along x
// and z, in the model's space turned to the root's heading at the tick's start, and its turn about y. A frozen sample
// and one that is gone move nothing. The graph only reports it; what moves the entity is gameplay's (see
// docs/animation/design.md#root-motion).
@(private)
root_motion :: proc(g: ^Graph, inst: ^Instance, out: ^Tick_Output) {
	if g.root < 0 {
		return
	}
	total: f32
	for s in inst.samples[:inst.sample_count] {
		total += s.weight
	}
	if total <= 0 {
		return
	}
	for s in inst.samples[:inst.sample_count] {
		if s.weight <= 0 || s.step <= 0 || .Frozen in s.flags || int(s.clip) >= len(g.clips) || g.clips[s.clip].blob == nil {
			continue
		}
		c := g.clips[s.clip]
		d := c.blob.duration
		t1 := s.time
		t0 := t1 - min(s.step, d)
		delta: [3]f32
		turn: f32
		if t0 < 0 && .Loop in s.flags {
			// Across the wrap: to the clip's end, then from its start, turned by what the first part turned.
			first, first_turn := root_segment(g, c, t0 + d, d)
			second, second_turn := root_segment(g, c, 0, t1)
			delta = first + rotate_y(second, first_turn)
			turn = first_turn + second_turn
		} else {
			delta, turn = root_segment(g, c, max(t0, 0), t1)
		}
		w := s.weight / total
		out.translation += delta * w
		out.yaw += turn * w
	}
	out.translation.y = 0
}

// root_segment is the root's move from one time of a clip to a later one, turned to its heading at the first, and
// its turn about y.
@(private = "file")
root_segment :: proc(g: ^Graph, c: Clip, from, to: f32) -> (delta: [3]f32, turn: f32) {
	from_position, from_yaw := root_at(g, c, from)
	to_position, to_yaw := root_at(g, c, to)
	return rotate_y(to_position - from_position, -from_yaw), angle_between_yaws(to_yaw - from_yaw)
}

// root_at is the root joint's position in the model's space at a time of a clip, and its heading, its turn about y.
@(private = "file")
root_at :: proc(g: ^Graph, c: Clip, t: f32) -> (position: [3]f32, yaw: f32) {
	l := g.root_rest
	sample_joint(c.data, c.blob, g.root, t, &l)
	p := g.root_parent * [4]f32{l.translation.x, l.translation.y, l.translation.z, 1}
	return p.xyz, twist_yaw(g.root_parent_rotation * l.rotation)
}

// remove_root_motion takes the root's motion out of a pose, so the entity moves by it instead of the mesh: the root
// keeps its rest place along x and z in the model's space and its rest heading, and keeps its height and its tilt.
remove_root_motion :: proc(g: ^Graph, locals: []Joint_Pose) {
	if g.root < 0 || g.root >= len(locals) {
		return
	}
	l := &locals[g.root]
	position := (g.root_parent * [4]f32{l.translation.x, l.translation.y, l.translation.z, 1}).xyz
	rest := (g.root_parent * [4]f32{g.root_rest.translation.x, g.root_rest.translation.y, g.root_rest.translation.z, 1}).xyz
	position.x, position.z = rest.x, rest.z
	l.translation = (linalg.inverse(g.root_parent) * [4]f32{position.x, position.y, position.z, 1}).xyz
	model := g.root_parent_rotation * l.rotation
	rest_yaw := twist_yaw(g.root_parent_rotation * g.root_rest.rotation)
	model = linalg.quaternion_angle_axis_f32(angle_between_yaws(rest_yaw - twist_yaw(model)), {0, 1, 0}) * model
	l.rotation = linalg.normalize(conj(g.root_parent_rotation) * model)
}

// twist_yaw is a rotation's turn about y, from its twist about y.
@(private)
twist_yaw :: proc "contextless" (q: quaternion128) -> f32 {
	return 2 * math.atan2(jmag(q), real(q))
}

// angle_between_yaws is a turn from -π to π.
@(private)
angle_between_yaws :: proc "contextless" (a: f32) -> f32 {
	turn := math.mod(a + math.PI, 2 * math.PI)
	if turn < 0 {
		turn += 2 * math.PI
	}
	return turn - math.PI
}

// rotate_y turns a vector about y by an angle, as a rotation of that angle about +y does.
@(private)
rotate_y :: proc "contextless" (v: [3]f32, angle: f32) -> [3]f32 {
	s, c := math.sin(angle), math.cos(angle)
	return {c * v.x + s * v.z, v.y, -s * v.x + c * v.z}
}

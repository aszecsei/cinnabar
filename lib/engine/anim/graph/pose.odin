// Package anim_graph poses skeletons from animation clips. It reads blobs and the poses that it is given and writes
// only the poses and palettes that it is given: it imports nothing from the world, scripts or the renderer, so what it
// computes depends on its inputs alone. lib/engine/anim calls it for each entity. See
// docs/content/kinds/skins-and-animations.md#playback.
package anim_graph

import "core:math"
import "core:math/linalg"

import format "cinnabar:engine/asset/format"

// Joint_Pose is a joint's pose relative to its parent.
Joint_Pose :: struct {
	translation: [3]f32,
	rotation:    quaternion128,
	scale:       [3]f32,
}

// rest_pose writes each joint's rest pose, relative to its parent, into locals.
rest_pose :: proc(joints: []format.Skin_Joint, locals: []Joint_Pose) {
	for j, i in joints {
		locals[i] = {j.translation, quaternion(real = j.rotation.w, imag = j.rotation.x, jmag = j.rotation.y, kmag = j.rotation.z), j.scale}
	}
}

// sample replaces the parts of the joints' poses that the clip's channels animate with their values at a time. Before
// a channel's first key the first holds, and after its last the last.
sample :: proc(clip_bytes: []byte, clip: ^format.Animation_Blob, time: f32, locals: []Joint_Pose) {
	times := format.animation_times(clip_bytes, clip)
	values := format.animation_values(clip_bytes, clip)
	for c in format.animation_channels(clip_bytes, clip) {
		if int(c.joint) < len(locals) {
			sample_channel(c, times, values, time, &locals[c.joint])
		}
	}
}

// sample_joint is sample for one joint, whose pose it replaces the animated parts of.
sample_joint :: proc(clip_bytes: []byte, clip: ^format.Animation_Blob, joint: int, time: f32, pose: ^Joint_Pose) {
	times := format.animation_times(clip_bytes, clip)
	values := format.animation_values(clip_bytes, clip)
	for c in format.animation_channels(clip_bytes, clip) {
		if int(c.joint) == joint {
			sample_channel(c, times, values, time, pose)
		}
	}
}

@(private = "file")
sample_channel :: proc(c: format.Animation_Channel, times, values: []f32, time: f32, l: ^Joint_Pose) {
	keys := times[c.first_key:][:c.key_count]
	width := int(format.animation_path_width(c.path))
	k, u := find_key(keys, time)
	if c.interpolation == .Step {
		u = 0
	}
	next := min(k + 1, len(keys) - 1)
	a := values[int(c.first_value) + k * width:][:width]
	b := values[int(c.first_value) + next * width:][:width]
	switch c.path {
	case .Translation:
		l.translation = linalg.lerp([3]f32{a[0], a[1], a[2]}, [3]f32{b[0], b[1], b[2]}, u)
	case .Scale:
		l.scale = linalg.lerp([3]f32{a[0], a[1], a[2]}, [3]f32{b[0], b[1], b[2]}, u)
	case .Rotation:
		qa := quaternion(real = a[3], imag = a[0], jmag = a[1], kmag = a[2])
		qb := quaternion(real = b[3], imag = b[0], jmag = b[1], kmag = b[2])
		l.rotation = linalg.normalize(linalg.quaternion_slerp_f32(qa, qb, u))
	}
}

// find_key is the key at or before a time and how far the time is toward the next, from 0 to 1.
find_key :: proc "contextless" (keys: []f32, time: f32) -> (key: int, u: f32) {
	if len(keys) < 2 || time <= keys[0] {
		return 0, 0
	}
	if time >= keys[len(keys) - 1] {
		return len(keys) - 1, 0
	}
	low, high := 0, len(keys) - 1
	for high - low > 1 {
		mid := (low + high) / 2
		if keys[mid] <= time {
			low = mid
		} else {
			high = mid
		}
	}
	span := keys[high] - keys[low]
	return low, span > 0 ? (time - keys[low]) / span : 0
}

// accumulate adds a pose, times a weight, into a sum of poses, which starts zeroed. A rotation and its negation are
// the same rotation, so each rotation joins the sum on the sum's side, and two of them never cancel. resolve turns the
// sum into a pose.
accumulate :: proc(sum: []Joint_Pose, pose: []Joint_Pose, weight: f32) {
	for &s, i in sum {
		p := pose[i]
		q := p.rotation
		if linalg.dot(s.rotation, q) < 0 {
			q = -q
		}
		s.translation += p.translation * weight
		s.rotation += q * quaternion(real = weight, imag = 0, jmag = 0, kmag = 0)
		s.scale += p.scale * weight
	}
}

// resolve turns a sum of poses, whose weights add up to total, into their weighted average, with its rotations
// normalized, so weights that do not add up to 1 still blend. With no weight, or where the rotations still cancel, the
// rest pose holds.
resolve :: proc(sum: []Joint_Pose, total: f32, rest: []Joint_Pose) {
	if total <= 0 {
		copy(sum, rest)
		return
	}
	for &s, i in sum {
		s.translation /= total
		s.scale /= total
		length := math.sqrt(linalg.dot(s.rotation, s.rotation))
		s.rotation = length > 1e-6 ? s.rotation * quaternion(real = 1 / length, imag = 0, jmag = 0, kmag = 0) : rest[i].rotation
	}
}

// compose writes each joint's matrix, from the mesh's bind pose to its posed place, into palette, from the joints'
// poses relative to their parents, parents first. models is scratch, one matrix a joint. It returns a sphere about the
// posed mesh: the union of the joints' bind spheres, each posed by its joint.
compose :: proc(joints: []format.Skin_Joint, locals: []Joint_Pose, models: []matrix[4, 4]f32, palette: [][3][4]f32) -> (sphere: [4]f32) {
	sphere.w = -1
	for j, i in joints {
		local := linalg.matrix4_from_trs_f32(locals[i].translation, locals[i].rotation, locals[i].scale)
		models[i] = j.parent < 0 ? local : models[j.parent] * local
		m := models[i] * rows_matrix(j.inverse_bind)
		palette[i] = {{m[0, 0], m[0, 1], m[0, 2], m[0, 3]}, {m[1, 0], m[1, 1], m[1, 2], m[1, 3]}, {m[2, 0], m[2, 1], m[2, 2], m[2, 3]}}
		if j.sphere.w >= 0 {
			center := (models[i] * [4]f32{j.sphere.x, j.sphere.y, j.sphere.z, 1}).xyz
			scale := max(linalg.length(models[i][0].xyz), linalg.length(models[i][1].xyz), linalg.length(models[i][2].xyz))
			sphere = merge_spheres(sphere, {center.x, center.y, center.z, j.sphere.w * scale})
		}
	}
	if sphere.w < 0 {
		sphere = {}
	}
	return
}

// merge_spheres is a sphere about two spheres; one with a negative radius is none.
merge_spheres :: proc "contextless" (a, b: [4]f32) -> [4]f32 {
	if a.w < 0 {
		return b
	}
	if b.w < 0 {
		return a
	}
	d := linalg.length(b.xyz - a.xyz)
	if d + b.w <= a.w {
		return a
	}
	if d + a.w <= b.w {
		return b
	}
	radius := (d + a.w + b.w) / 2
	center := a.xyz + (b.xyz - a.xyz) * ((radius - a.w) / d)
	return {center.x, center.y, center.z, radius}
}

@(private = "file")
rows_matrix :: proc "contextless" (rows: [3][4]f32) -> matrix[4, 4]f32 {
	return {
		rows[0][0], rows[0][1], rows[0][2], rows[0][3],
		rows[1][0], rows[1][1], rows[1][2], rows[1][3],
		rows[2][0], rows[2][1], rows[2][2], rows[2][3],
		0, 0, 0, 1,
	}
}

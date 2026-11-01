package anim_graph

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
near :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1e-4
}

// aligned copies a blob into memory at the runtime's alignment, as the asset runtime loads it.
@(private = "file")
aligned :: proc(data: []byte) -> []byte {
	copied, _ := mem.alloc_bytes(len(data), format.BLOB_ALIGN, context.temp_allocator)
	copy(copied, data)
	return copied
}

@(private = "file")
test_clip :: proc(interpolation: format.Animation_Interpolation) -> ([]byte, ^format.Animation_Blob) {
	turn := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1})
	data := aligned(format.animation_write({
		joint_count = 2,
		duration = 1,
		channels = {
			{joint = 0, path = .Rotation, interpolation = interpolation, first_key = 0, key_count = 2, first_value = 0},
			{joint = 1, path = .Scale, interpolation = interpolation, first_key = 2, key_count = 2, first_value = 8},
		},
		times = {0, 1, 0, 1},
		values = {0, 0, 0, 1, imag(turn), jmag(turn), kmag(turn), real(turn), 1, 1, 1, 3, 3, 3},
	}, context.temp_allocator))
	blob, ok := format.animation_view(data)
	assert(ok)
	return data, blob
}

@(private = "file")
test_joints :: proc() -> []format.Skin_Joint {
	identity := [3][4]f32{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}}
	down := [3][4]f32{{1, 0, 0, 0}, {0, 1, 0, -1}, {0, 0, 1, 0}}
	data := aligned(format.skin_write({
		joints = {
			{name = "Root", parent = -1, inverse_bind = identity, rotation = {0, 0, 0, 1}, scale = 1, sphere = {0, 0, 0, -1}},
			{name = "Tip", parent = 0, inverse_bind = down, translation = {0, 1, 0}, rotation = {0, 0, 0, 1}, scale = 1, sphere = {0, 0.5, 0, 0.5}},
		},
	}, context.temp_allocator))
	blob, ok := format.skin_view(data)
	assert(ok)
	return format.skin_joints(data, blob)
}

// pose_at is a clip's palette and sphere at a time, from its skin's rest pose.
@(private = "file")
pose_at :: proc(joints: []format.Skin_Joint, data: []byte, clip: ^format.Animation_Blob, time: f32, palette: [][3][4]f32) -> [4]f32 {
	locals := make([]Joint_Pose, len(joints), context.temp_allocator)
	models := make([]matrix[4, 4]f32, len(joints), context.temp_allocator)
	rest_pose(joints, locals)
	sample(data, clip, time, locals)
	return compose(joints, locals, models, palette)
}

// angle_between is the angle that turns one rotation into the other, either way about.
@(private = "file")
angle_between :: proc(a, b: quaternion128) -> f32 {
	return 2 * math.acos(min(abs(linalg.dot(a, b)), 1))
}

@(test)
channels_sample_by_their_interpolation :: proc(t: ^testing.T) {
	locals := []Joint_Pose{{rotation = 1, scale = 1}, {rotation = 1, scale = 1}}
	data, clip := test_clip(.Linear)
	sample(data, clip, 0.5, locals)
	testing.expect(t, near(locals[1].scale.x, 2), "linear keys lerp")
	angle := 2 * math.acos(real(locals[0].rotation))
	testing.expect(t, near(angle, math.PI / 4), "rotations slerp")

	step_data, step_clip := test_clip(.Step)
	sample(step_data, step_clip, 0.9, locals)
	testing.expect(t, near(locals[1].scale.x, 1), "step keys hold until the next")
	sample(step_data, step_clip, 2, locals)
	testing.expect(t, near(locals[1].scale.x, 3), "past the last key, the last holds")

	key, u := find_key({0, 1, 3}, 2)
	testing.expect(t, key == 1 && near(u, 0.5))
}

@(test)
the_palette_poses_the_bind_pose :: proc(t: ^testing.T) {
	joints := test_joints()
	data, clip := test_clip(.Linear)
	palette := make([][3][4]f32, len(joints), context.temp_allocator)

	// At the start, every joint is at its bind pose, so the palette is identity.
	pose_at(joints, data, clip, 0, palette)
	for row, r in palette[1] {
		for v, c in row {
			testing.expect(t, near(v, r == c ? 1 : 0))
		}
	}

	// At the end, Root has turned 90° about z, which turns Tip and every vertex it holds, and Tip is 3 times as large.
	sphere := pose_at(joints, data, clip, 1, palette)
	m := palette[1]
	vertex := [4]f32{0, 2, 0, 1}
	posed := [3]f32{linalg.dot(m[0], vertex), linalg.dot(m[1], vertex), linalg.dot(m[2], vertex)}
	testing.expect(t, near(posed.x, -4) && near(posed.y, 0) && near(posed.z, 0), "Tip turns with Root and grows")

	// The posed sphere holds Tip's posed vertices, from its joint out to the vertex.
	for y in ([]f32{1, 1.5, 2}) {
		v := [4]f32{0, y, 0, 1}
		p := [3]f32{linalg.dot(m[0], v), linalg.dot(m[1], v), linalg.dot(m[2], v)}
		testing.expect(t, linalg.length(p - sphere.xyz) <= sphere.w + 1e-4)
	}
}

@(test)
spheres_merge_about_both :: proc(t: ^testing.T) {
	merged := merge_spheres({0, 0, 0, 1}, {4, 0, 0, 1})
	testing.expect(t, near(merged.x, 2) && near(merged.w, 3))
	testing.expect_value(t, merge_spheres({0, 0, 0, -1}, {1, 2, 3, 4}), [4]f32{1, 2, 3, 4})
	testing.expect_value(t, merge_spheres({0, 0, 0, 5}, {1, 0, 0, 1}), [4]f32{0, 0, 0, 5})
}

@(test)
poses_blend_by_their_weights :: proc(t: ^testing.T) {
	quarter := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0})
	rest := []Joint_Pose{{rotation = 1, scale = 1}}
	a := []Joint_Pose{{rotation = 1, scale = 1}}
	b := []Joint_Pose{{translation = {2, 4, 0}, rotation = quarter, scale = 3}}

	sum := make([]Joint_Pose, 1, context.temp_allocator)
	accumulate(sum, a, 0.5)
	accumulate(sum, b, 0.5)
	resolve(sum, 1, rest)
	testing.expect(t, near(sum[0].translation.x, 1) && near(sum[0].translation.y, 2), "translations average")
	testing.expect(t, near(sum[0].scale.x, 2), "scales average")
	testing.expect(t, near(linalg.dot(sum[0].rotation, sum[0].rotation), 1), "the rotation is normalized")
	testing.expect(t, near(angle_between(sum[0].rotation, 1), math.PI / 4), "the rotation is halfway")

	// Weights that do not add up to 1 blend as their shares of the total.
	uneven := make([]Joint_Pose, 1, context.temp_allocator)
	accumulate(uneven, a, 1)
	accumulate(uneven, b, 3)
	resolve(uneven, 4, rest)
	testing.expect(t, near(uneven[0].translation.x, 1.5) && near(uneven[0].scale.x, 2.5))
}

@(test)
a_rotation_and_its_negation_blend_as_one :: proc(t: ^testing.T) {
	quarter := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 1, 0})
	rest := []Joint_Pose{{rotation = 1, scale = 1}}
	sum := make([]Joint_Pose, 1, context.temp_allocator)
	accumulate(sum, []Joint_Pose{{rotation = quarter, scale = 1}}, 0.5)
	accumulate(sum, []Joint_Pose{{rotation = -quarter, scale = 1}}, 0.5)
	resolve(sum, 1, rest)
	testing.expect(t, near(angle_between(sum[0].rotation, quarter), 0), "q and -q do not cancel")
}

@(test)
joints_that_no_clip_moves_blend_at_rest :: proc(t: ^testing.T) {
	joints := test_joints()
	rest := make([]Joint_Pose, len(joints), context.temp_allocator)
	rest_pose(joints, rest)
	data, clip := test_clip(.Linear)

	// The clip moves only Root's rotation and Tip's scale, so Tip's translation stays at rest in each sample and in
	// their blend.
	sum := make([]Joint_Pose, len(joints), context.temp_allocator)
	for time in ([]f32{0, 1}) {
		locals := make([]Joint_Pose, len(joints), context.temp_allocator)
		copy(locals, rest)
		sample(data, clip, time, locals)
		accumulate(sum, locals, 0.5)
	}
	resolve(sum, 1, rest)
	testing.expect_value(t, sum[1].translation, rest[1].translation)
	testing.expect(t, near(sum[1].scale.x, 2), "Tip's scale blends between its keys")

	// With no weight, the blend is the rest pose.
	empty := make([]Joint_Pose, len(joints), context.temp_allocator)
	resolve(empty, 0, rest)
	testing.expect_value(t, empty[1], rest[1])
}

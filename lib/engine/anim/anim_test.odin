package anim

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

@(test)
the_clock_advances_by_ticks_and_wraps :: proc(t: ^testing.T) {
	a := DEFAULT_ANIMATOR
	a.duration = 1
	for _ in 0 ..< 3 {
		advance(&a, 0.25)
	}
	testing.expect(t, near(a.time, 0.75) && near(a.step, 0.25))
	advance(&a, 0.5)
	testing.expect(t, near(a.time, 0.25), "a looping clock wraps")
	testing.expect(t, near(a.step, 0.5), "the step is the distance before the wrap")

	a.speed = 2
	advance(&a, 0.25)
	testing.expect(t, near(a.time, 0.75))

	held := Animator{speed = 1, playing = true, duration = 1, time = 0.9}
	advance(&held, 0.25)
	testing.expect(t, near(held.time, 1) && near(held.step, 0.1), "without loop it holds at the end")
	advance(&held, 0.25)
	testing.expect(t, near(held.time, 1) && near(held.step, 0))

	stopped := DEFAULT_ANIMATOR
	stopped.duration, stopped.playing, stopped.time = 1, false, 0.5
	advance(&stopped, 0.25)
	testing.expect(t, near(stopped.time, 0.5) && near(stopped.step, 0))

	// Without its clip, an Animator stays at the start.
	unloaded := DEFAULT_ANIMATOR
	advance(&unloaded, 0.25)
	testing.expect_value(t, unloaded.time, 0)
}

@(test)
presentation_interpolates_between_ticks :: proc(t: ^testing.T) {
	a := Animator{loop = true, duration = 1, time = 0.5, step = 0.1}
	testing.expect(t, near(presented_time(a, 1), 0.5))
	testing.expect(t, near(presented_time(a, 0), 0.4))
	testing.expect(t, near(presented_time(a, 0.5), 0.45))
	// Across the wrap, it goes back to the end of the clip.
	wrapped := Animator{loop = true, duration = 1, time = 0.05, step = 0.1}
	testing.expect(t, near(presented_time(wrapped, 0.25), 0.975))
	held := Animator{duration = 1, time = 0.05, step = 0.1}
	testing.expect(t, near(presented_time(held, 0.25), 0))
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
	pose(joints, data, clip, 0, palette)
	for row, r in palette[1] {
		for v, c in row {
			testing.expect(t, near(v, r == c ? 1 : 0))
		}
	}

	// At the end, Root has turned 90° about z, which turns Tip and every vertex it holds, and Tip is 3 times as large.
	sphere := pose(joints, data, clip, 1, palette)
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

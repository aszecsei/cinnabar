package asset_format

import "core:testing"

@(test)
instance_text_round_trips :: proc(t: ^testing.T) {
	poses := []Instance_Pose {
		{
			position = {1.5, 0, -2},
			rotation = quaternion(x = 0, y = 0.3826834, z = 0, w = 0.9238795),
			scale = {1, 1, 1},
		},
		{
			position = {0.1, 1e-7, 12345.678},
			rotation = quaternion(x = 0, y = 0, z = 0, w = 1),
			scale = {0.5, 2, 0.25},
		},
	}
	text := instances_text_write(poses, context.temp_allocator)
	back, problems := instances_text_parse(text, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(back), 2)
	for p, i in poses {
		testing.expectf(t, back[i] == p, "pose %d: %v, not %v", i, back[i], p)
	}
	empty, empty_problems := instances_text_parse(
		instances_text_write(nil, context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect(t, len(empty) == 0 && len(empty_problems) == 0)
}

@(test)
instance_text_normalizes_rotations_and_skips_comments :: proc(t: ^testing.T) {
	poses, problems := instances_text_parse(
		"# first\n\ninstances 1 # header\ni 1 2 3 0 0 0 2 1 1 1 # one\n",
		context.temp_allocator,
	)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(poses), 1)
	testing.expect_value(t, real(poses[0].rotation), 1)
	testing.expect_value(t, poses[0].position, [3]f32{1, 2, 3})
}

@(test)
instance_text_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	HEAD :: "instances 1\n"
	cases := []struct {
		text: string,
		line: int,
	} {
		{"i 0 0 0 0 0 0 1 1 1 1\n", 1},
		{"instances 2\n", 1},
		{"", 1},
		{HEAD + "\ni 0 0 0 0 0 0 1 1 1\n", 3},
		{HEAD + "i 0 0 0 0 0 0 1 1 1 1 1\n", 2},
		{HEAD + "instance 0 0 0 0 0 0 1 1 1 1\n", 2},
		{HEAD + "i 0 0 x 0 0 0 1 1 1 1\n", 2},
		{HEAD + "i 0 0 nan 0 0 0 1 1 1 1\n", 2},
		{HEAD + "i 0 0 inf 0 0 0 1 1 1 1\n", 2},
		{HEAD + "i 0 0 0 0 0 0 0 1 1 1\n", 2},
		{HEAD + "i 0 0 0 0 0 0 1 1 1 1\n# fine\ni 0 0 0 0 0 0 1 1 1 q\n", 4},
	}
	for c in cases {
		_, problems := instances_text_parse(c.text, context.temp_allocator)
		testing.expectf(
			t,
			len(problems) > 0 && problems[0].line == c.line,
			"%q: %v",
			c.text,
			problems,
		)
	}
}

@(test)
instance_pack_keeps_w_positive_and_rounds_scale :: proc(t: ^testing.T) {
	flipped := instance_pack(
		{
			position = {1, 2, 3},
			rotation = quaternion(x = 0, y = 0.6, z = 0, w = -0.8),
			scale = {1, 0.5, 2},
		},
		7,
	)
	testing.expect_value(t, flipped.rotation, [4]i16{0, -19660, 0, 26214})
	testing.expect_value(t, flipped.scale, [3]f16{1, 0.5, 2})
	testing.expect_value(t, flipped.position, [3]f32{1, 2, 3})
	testing.expect_value(t, flipped.point, 7)
	back := instance_pack(
		{rotation = quaternion(x = 0, y = 0, z = 0, w = -1), scale = {1, 1, 1}},
		0,
	)
	testing.expect_value(t, back.rotation, [4]i16{0, 0, 0, 32767})
}

@(test)
instance_cells_split_at_the_cell_size :: proc(t: ^testing.T) {
	count :: 2 * INSTANCE_CELL_SIZE + 5
	instances := make([]Instance, count, context.temp_allocator)
	for &i, k in instances {
		i = instance_pack(
			{
				position = {f32(k % 17) * 3, f32(k / 17), f32(k % 5)},
				rotation = quaternion(x = 0, y = 0, z = 0, w = 1),
				scale = {1, 1 + f32(k % 3), 1},
			},
			u32(k),
		)
	}
	contents := instance_cells(instances, context.temp_allocator)
	testing.expect_value(t, len(contents.instances), count)
	testing.expect_value(t, len(contents.cells), 3)
	testing.expect_value(t, contents.cells[2].count, 5)
	testing.expect_value(t, contents.max_scale, 3)
	seen := make([]bool, count, context.temp_allocator)
	for i in contents.instances {
		seen[i.point] = true
	}
	for s, k in seen {
		testing.expectf(t, s, "instance %d is missing", k)
	}
	next: u32
	for c in contents.cells {
		testing.expect_value(t, c.first, next)
		next += c.count
		for i in contents.instances[c.first:][:c.count] {
			d := i.position - c.center
			testing.expect(
				t,
				d.x * d.x + d.y * d.y + d.z * d.z <= c.radius * c.radius * 1.0001 + 1e-6,
			)
		}
	}
	none := instance_cells(nil, context.temp_allocator)
	testing.expect(t, len(none.cells) == 0 && len(none.instances) == 0)
}

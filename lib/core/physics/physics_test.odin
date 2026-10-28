package physics

import "core:testing"

// Commands come back in order, with their payloads, across chunks.
@(test)
commands_round_trip :: proc(t: ^testing.T) {
	list := command_list(context.allocator)
	defer for chunk := list.first; chunk != nil; {
		next := chunk.next
		free(chunk)
		chunk = next
	}
	// Enough to fill several chunks.
	COUNT :: 3000
	for i in 0 ..< COUNT {
		cmd_set_pose(&list, {u32(i), 1}, {f64(i), 0, 0}, {0, 0, 0, 1}, activate = i % 2 == 0)
		cmd_add_impulse(&list, {u32(i), 1}, {0, f32(i), 0})
	}
	testing.expect(t, list.first != list.last, "the list spans chunks")

	seen := 0
	for chunk := list.first; chunk != nil; chunk = chunk.next {
		data := chunk_data(chunk)[:chunk.used]
		offset := 0
		for command in next_command(data, &offset) {
			i := seen / 2
			if seen % 2 == 0 {
				testing.expect_value(t, command.kind, Command_Kind.Set_Pose)
				pose := payload(command, Set_Pose)
				testing.expect_value(t, pose.body, Body{u32(i), 1})
				testing.expect_value(t, pose.position.x, f64(i))
				testing.expect_value(t, bool(pose.activate), i % 2 == 0)
			} else {
				testing.expect_value(t, command.kind, Command_Kind.Add_Impulse)
				testing.expect_value(t, payload(command, Add_Vector).vector.y, f32(i))
			}
			testing.expect(t, uintptr(raw_data(command.data)) % COMMAND_ALIGN == 0, "payloads are aligned")
			seen += 1
		}
		testing.expect_value(t, offset, chunk.used)
	}
	testing.expect_value(t, seen, 2 * COUNT)
}

// A truncated command ends the read instead of running past the bytes.
@(test)
truncated_command :: proc(t: ^testing.T) {
	list := command_list(context.temp_allocator)
	cmd_destroy_body(&list, {1, 1})
	data := chunk_data(list.first)[:list.first.used - 1]
	offset := 0
	_, ok := next_command(data, &offset)
	testing.expect(t, !ok)
	testing.expect_value(t, offset, 0)
}

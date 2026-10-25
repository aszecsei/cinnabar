package debug

import "base:runtime"
import "core:testing"

import "cinnabar:engine/ecs"

@(test)
lines_last_a_frame_or_their_duration :: proc(t: ^testing.T) {
	d: Draw
	init(&d, runtime.heap_allocator())
	defer destroy(&d)
	origin: ecs.World_Position
	up := ecs.position_offset(origin, {0, 1, 0})
	line(&d, origin, up, {1, 0, 0, 1})
	line(&d, origin, up, {0, 1, 0, 1}, duration = 60, mode = .Overlay)
	testing.expect_value(t, len(frame_lines(&d)), 2)

	end_frame(&d)
	lines := frame_lines(&d)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		testing.expect_value(t, lines[0].mode, Mode.Overlay)
		testing.expect_value(t, lines[0].color, [4]f32{0, 1, 0, 1})
	}
}

@(test)
shapes_are_lines_and_extra_lines_drop :: proc(t: ^testing.T) {
	d: Draw
	init(&d, runtime.heap_allocator())
	defer destroy(&d)
	box(&d, {}, {1, 1, 1}, 1, {1, 1, 1, 1})
	testing.expect_value(t, len(frame_lines(&d)), 12)
	end_frame(&d)
	sphere(&d, {}, 1, {1, 1, 1, 1})
	testing.expect_value(t, len(frame_lines(&d)), 3 * CIRCLE_SEGMENTS)
	end_frame(&d)
	axes(&d, ecs.TRANSFORM_IDENTITY, 1)
	arrow(&d, {}, ecs.position_offset({}, {0, 0, 1}), {1, 1, 1, 1})
	testing.expect_value(t, len(frame_lines(&d)), 3 + 5)
	end_frame(&d)

	for _ in 0 ..< MAX_LINES + 10 {
		line(&d, {}, {}, {1, 1, 1, 1})
	}
	testing.expect_value(t, len(frame_lines(&d)), MAX_LINES)
	end_frame(&d)
	testing.expect_value(t, len(frame_lines(&d)), 0)
}

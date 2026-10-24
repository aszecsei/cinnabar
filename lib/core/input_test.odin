package core

import "core:testing"

@(test)
input_edges_last_one_frame :: proc(t: ^testing.T) {
	input: Input
	input_key_down(&input, .Space)
	// A repeat while held is not a new press.
	input_key_down(&input, .Space)
	testing.expect_value(t, input.down, Keys{.Space})
	testing.expect_value(t, input.pressed, Keys{.Space})

	input_begin_frame(&input)
	testing.expect_value(t, input.down, Keys{.Space})
	testing.expect_value(t, input.pressed, Keys{})

	input_key_up(&input, .Space)
	testing.expect_value(t, input.released, Keys{.Space})
	testing.expect_value(t, input.down, Keys{})
}

@(test)
a_tap_within_one_frame_is_pressed_and_released :: proc(t: ^testing.T) {
	input: Input
	input_key_down(&input, .A)
	input_key_up(&input, .A)
	testing.expect_value(t, input.pressed, Keys{.A})
	testing.expect_value(t, input.released, Keys{.A})
	testing.expect_value(t, input.down, Keys{})
}

@(test)
losing_focus_releases_every_key :: proc(t: ^testing.T) {
	input: Input
	input_key_down(&input, .W)
	input_key_down(&input, .Mouse_Left)
	input_begin_frame(&input)
	input_release_all(&input)
	testing.expect_value(t, input.down, Keys{})
	testing.expect_value(t, input.released, Keys{.W, .Mouse_Left})
	// The None key is never down.
	input_key_down(&input, .None)
	testing.expect_value(t, input.down, Keys{})
}

@(test)
input_events_from_elsewhere_act_as_the_window_does :: proc(t: ^testing.T) {
	input: Input
	input_apply(&input, {kind = .Mouse_Move, position = {10, 20}})
	input_apply(&input, {kind = .Mouse_Move, position = {13, 16}})
	input_apply(&input, {kind = .Key_Down, key = .Mouse_Left})
	input_apply(&input, {kind = .Scroll, scroll = 2})
	testing.expect_value(t, input.mouse_position, [2]f32{13, 16})
	testing.expect_value(t, input.mouse_delta, [2]f32{13, 16})
	testing.expect_value(t, input.down, Keys{.Mouse_Left})
	testing.expect_value(t, input.scroll, 2)

	input_apply(&input, {kind = .Release_All})
	testing.expect_value(t, input.down, Keys{})
	testing.expect_value(t, input.released, Keys{.Mouse_Left})
}

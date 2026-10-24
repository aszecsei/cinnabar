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

package core

// Key is a keyboard key or a mouse button. Letters and digits are the keys at those positions on a US layout.
Key :: enum u8 {
	None,
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Num_0, Num_1, Num_2, Num_3, Num_4, Num_5, Num_6, Num_7, Num_8, Num_9,
	Space, Enter, Escape, Tab, Backspace, Delete, Insert, Home, End, Page_Up, Page_Down,
	Left, Right, Up, Down,
	Left_Shift, Right_Shift, Left_Control, Right_Control, Left_Alt, Right_Alt,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Mouse_Left, Mouse_Right, Mouse_Middle, Mouse_4, Mouse_5,
}

Keys :: bit_set[Key;u128]

// Input is the state of the keyboard and mouse at the start of a frame.
Input :: struct {
	down:           Keys,
	// The keys that went down, or up, since the previous frame. A key that went down and up within one frame is
	// in both, and not in down.
	pressed:        Keys,
	released:       Keys,
	// In pixels from the client area's top-left corner.
	mouse_position: [2]f32,
	mouse_delta:    [2]f32,
	// Wheel notches, positive away from the user.
	scroll:         f32,
}

@(private)
input_key_down :: proc "contextless" (input: ^Input, key: Key) {
	if key != .None && key not_in input.down {
		input.down += {key}
		input.pressed += {key}
	}
}

@(private)
input_key_up :: proc "contextless" (input: ^Input, key: Key) {
	if key != .None && key in input.down {
		input.down -= {key}
		input.released += {key}
	}
}

// input_release_all releases every key, for example when the window loses focus and stops seeing key-up messages.
@(private)
input_release_all :: proc "contextless" (input: ^Input) {
	input.released += input.down
	input.down = {}
}

// input_begin_frame clears the edges and the deltas of the last frame, before this frame's events arrive.
@(private)
input_begin_frame :: proc "contextless" (input: ^Input) {
	input.pressed = {}
	input.released = {}
	input.mouse_delta = {}
	input.scroll = 0
}

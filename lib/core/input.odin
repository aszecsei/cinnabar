package core

import "core:math"
import "core:unicode/utf16"
import "core:unicode/utf8"

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

MAX_GAMEPADS :: 4

// Gamepad_Button is a button of a gamepad, by its position on an Xbox pad. The values are the bits of XInput's
// wButtons, so Gamepad_Buttons is that word. Nothing has the values 10 and 11.
Gamepad_Button :: enum u8 {
	Dpad_Up      = 0,
	Dpad_Down    = 1,
	Dpad_Left    = 2,
	Dpad_Right   = 3,
	Start        = 4,
	Back         = 5,
	Left_Stick   = 6,
	Right_Stick  = 7,
	Left_Bumper  = 8,
	Right_Bumper = 9,
	A            = 12,
	B            = 13,
	X            = 14,
	Y            = 15,
}

Gamepad_Buttons :: bit_set[Gamepad_Button;u16]

// GAMEPAD_BUTTONS is every button that exists.
GAMEPAD_BUTTONS :: Gamepad_Buttons {
	.Dpad_Up,
	.Dpad_Down,
	.Dpad_Left,
	.Dpad_Right,
	.Start,
	.Back,
	.Left_Stick,
	.Right_Stick,
	.Left_Bumper,
	.Right_Bumper,
	.A,
	.B,
	.X,
	.Y,
}

// Gamepad_Axis is an axis of a gamepad. A stick's axes run from -1 to 1, positive right and up, and a trigger's from
// 0 to 1.
Gamepad_Axis :: enum u8 {
	Left_X,
	Left_Y,
	Right_X,
	Right_Y,
	Left_Trigger,
	Right_Trigger,
}

// Gamepad_Reading is what a pad reports at one moment, before the dead zones.
Gamepad_Reading :: struct {
	connected: bool,
	buttons:   Gamepad_Buttons,
	axes:      [Gamepad_Axis]f32,
}

// Gamepad is the state of one slot. A slot that has no pad is not connected, and has no buttons down and every axis
// at 0.
Gamepad :: struct {
	connected: bool,
	down:      Gamepad_Buttons,
	// The buttons that went down, or up, since the previous frame.
	pressed:   Gamepad_Buttons,
	released:  Gamepad_Buttons,
	// After the dead zones.
	axes:      [Gamepad_Axis]f32,
}

INPUT_TEXT_CAPACITY :: 256

// Input_Text is UTF-8 text inside the value, since Input crosses the DLL boundary by value and stays in the script
// runtime. What does not fit is dropped, a whole code point at a time.
Input_Text :: struct {
	bytes:  [INPUT_TEXT_CAPACITY]u8,
	length: u16,
}

// input_text_string is the text. It points into text.
input_text_string :: proc "contextless" (text: ^Input_Text) -> string {
	return string(text.bytes[:text.length])
}

input_text_append :: proc "contextless" (text: ^Input_Text, s: string) {
	n := min(len(s), INPUT_TEXT_CAPACITY - int(text.length))
	if n < len(s) {
		for n > 0 && !utf8.rune_start(s[n]) {
			n -= 1
		}
	}
	copy(text.bytes[text.length:], s[:n])
	text.length += u16(n)
}

// Input is the state of the keyboard, the mouse, the gamepads and the typed text at the start of a frame.
Input :: struct {
	down:               Keys,
	// The keys that went down, or up, since the previous frame. A key that went down and up within one frame is
	// in both, and not in down.
	pressed:            Keys,
	released:           Keys,
	// In pixels from the client area's top-left corner.
	mouse_position:     [2]f32,
	mouse_delta:        [2]f32,
	// Wheel notches, positive away from the user.
	scroll:             f32,
	gamepads:           [MAX_GAMEPADS]Gamepad,
	// The characters typed since the previous frame, with what an IME committed. Control characters are not text:
	// Backspace and Enter are keys.
	text:               Input_Text,
	// What an IME is composing, which is not text yet, and the bytes of it before the cursor. It stays from frame to
	// frame until the IME commits it or gives it up.
	composition:        Input_Text,
	composition_cursor: i32,
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

// input_release_all releases every key and button, for example when the window loses focus and stops seeing key-up
// messages. It also ends a composition. The pads stay connected.
@(private)
input_release_all :: proc "contextless" (input: ^Input) {
	input.released += input.down
	input.down = {}
	for &pad in input.gamepads {
		pad.released += pad.down
		pad.down = {}
		pad.axes = {}
	}
	input_set_composition(input, {}, 0)
}

// input_begin_frame clears the edges and the deltas of the last frame, before this frame's events arrive.
@(private)
input_begin_frame :: proc "contextless" (input: ^Input) {
	input.pressed = {}
	input.released = {}
	input.mouse_delta = {}
	input.scroll = 0
	for &pad in input.gamepads {
		pad.pressed = {}
		pad.released = {}
	}
	input.text.length = 0
}

// XInput's documented dead zones, as parts of the range of a stick or a trigger.
@(private = "file")
LEFT_STICK_DEAD_ZONE: f32 = 7849.0 / 32767.0
@(private = "file")
RIGHT_STICK_DEAD_ZONE: f32 = 8689.0 / 32767.0
@(private = "file")
TRIGGER_DEAD_ZONE: f32 = 30.0 / 255.0

// stick_after_dead_zone keeps a stick's direction and rescales its length, so that the axes start from 0 at the edge
// of the dead zone and still reach 1.
@(private = "file")
stick_after_dead_zone :: proc "contextless" (x, y, dead_zone: f32) -> (f32, f32) {
	length := math.sqrt(x * x + y * y)
	if length <= dead_zone {
		return 0, 0
	}
	scale := min((length - dead_zone) / (1 - dead_zone), 1) / length
	return x * scale, y * scale
}

@(private = "file")
trigger_after_dead_zone :: proc "contextless" (value: f32) -> f32 {
	return(
		value <= TRIGGER_DEAD_ZONE ? 0 : min((value - TRIGGER_DEAD_ZONE) / (1 - TRIGGER_DEAD_ZONE), 1) \
	)
}

// input_gamepad_set gives a slot a new reading, from the window's poll or from the editor. The button edges come from
// the difference. A pad that is gone reads as a pad with nothing held.
@(private)
input_gamepad_set :: proc "contextless" (input: ^Input, slot: int, reading: Gamepad_Reading) {
	pad := &input.gamepads[slot]
	pad.connected = reading.connected
	buttons := reading.buttons & GAMEPAD_BUTTONS if reading.connected else {}
	pad.pressed += buttons - pad.down
	pad.released += pad.down - buttons
	pad.down = buttons
	pad.axes = {}
	if reading.connected {
		a := reading.axes
		pad.axes[.Left_X], pad.axes[.Left_Y] = stick_after_dead_zone(
			a[.Left_X],
			a[.Left_Y],
			LEFT_STICK_DEAD_ZONE,
		)
		pad.axes[.Right_X], pad.axes[.Right_Y] = stick_after_dead_zone(
			a[.Right_X],
			a[.Right_Y],
			RIGHT_STICK_DEAD_ZONE,
		)
		pad.axes[.Left_Trigger] = trigger_after_dead_zone(a[.Left_Trigger])
		pad.axes[.Right_Trigger] = trigger_after_dead_zone(a[.Right_Trigger])
	}
}

// input_char takes one UTF-16 unit of a WM_CHAR. high_surrogate keeps the first half of a pair between messages.
@(private)
input_char :: proc "contextless" (input: ^Input, high_surrogate: ^u16, unit: u16) {
	high := high_surrogate^
	high_surrogate^ = 0
	r := rune(unit)
	switch unit {
	case 0xd800 ..< 0xdc00:
		high_surrogate^ = unit
		return
	case 0xdc00 ..< 0xe000:
		if high == 0 {
			return
		}
		r = utf16.decode_surrogate_pair(rune(high), r)
	case 0 ..< 0x20, 0x7f ..< 0xa0:
		return
	}
	bytes, n := utf8.encode_rune(r)
	input_text_append(&input.text, string(bytes[:n]))
}

@(private)
input_set_composition :: proc "contextless" (input: ^Input, composition: Input_Text, cursor: i32) {
	input.composition = composition
	input.composition_cursor = clamp(cursor, 0, i32(composition.length))
}

// input_composition_utf16 sets the composition from an IME's UTF-16 string and its cursor in units.
@(private)
input_composition_utf16 :: proc "contextless" (input: ^Input, units: []u16, cursor: int) {
	// A UTF-16 unit is at most 3 bytes of UTF-8, and decode_to_utf8 could stop inside a code point at the end of its
	// buffer. This one always has room, so that input_text_append decides what fits.
	buffer: [INPUT_TEXT_CAPACITY * 3]u8
	kept := units[:min(len(units), INPUT_TEXT_CAPACITY)]
	composition: Input_Text
	input_text_append(&composition, string(buffer[:utf16.decode_to_utf8(buffer[:], kept)]))
	before := utf16.decode_to_utf8(buffer[:], kept[:clamp(cursor, 0, len(kept))])
	input_set_composition(input, composition, i32(before))
}

Input_Event_Kind :: enum u8 {
	Key_Down,
	Key_Up,
	// The mouse is at position. The move adds to the frame's mouse delta.
	Mouse_Move,
	Scroll,
	// Every key and button goes up and any composition ends, as when the window loses focus.
	Release_All,
	// The slot pad now reads as reading.
	Gamepad,
	// The characters of text were typed.
	Text,
	// An IME composes text, with cursor bytes of it before the cursor. Empty text ends the composition.
	Composition,
}

// Input_Event is a change of the input that does not come from the window: in shared mode, the editor's
// viewport sends them while the game plays (see docs/editor/document-and-scenes.md#modes). queue_input applies them at the start of the
// next frame, after the window's own messages.
Input_Event :: struct {
	kind:     Input_Event_Kind,
	key:      Key,
	// Mouse_Move: in pixels from the frame's top-left corner.
	position: [2]f32,
	// Scroll: wheel notches, positive away from the user.
	scroll:   f32,
	// Gamepad: the slot, below MAX_GAMEPADS. Another is ignored.
	pad:      u8,
	reading:  Gamepad_Reading,
	// Text and Composition.
	text:     Input_Text,
	// Composition: the bytes of text before the cursor.
	cursor:   i32,
}

@(private)
input_apply :: proc "contextless" (input: ^Input, event: Input_Event) {
	event := event
	switch event.kind {
	case .Key_Down:
		input_key_down(input, event.key)
	case .Key_Up:
		input_key_up(input, event.key)
	case .Mouse_Move:
		input.mouse_delta += event.position - input.mouse_position
		input.mouse_position = event.position
	case .Scroll:
		input.scroll += event.scroll
	case .Release_All:
		input_release_all(input)
	case .Gamepad:
		if int(event.pad) < MAX_GAMEPADS {
			input_gamepad_set(input, int(event.pad), event.reading)
		}
	case .Text:
		input_text_append(&input.text, input_text_string(&event.text))
	case .Composition:
		input_set_composition(input, event.text, event.cursor)
	}
}

package core

import "core:testing"
import "core:time"

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

@(test)
gamepad_edges_come_from_the_readings :: proc(t: ^testing.T) {
	input: Input
	input_gamepad_set(&input, 1, {connected = true, buttons = {.A, .Start}})
	testing.expect(t, input.gamepads[1].connected)
	testing.expect_value(t, input.gamepads[1].down, Gamepad_Buttons{.A, .Start})
	testing.expect_value(t, input.gamepads[1].pressed, Gamepad_Buttons{.A, .Start})
	testing.expect(t, !input.gamepads[0].connected)

	input_begin_frame(&input)
	input_gamepad_set(&input, 1, {connected = true, buttons = {.A, .Y}})
	testing.expect_value(t, input.gamepads[1].pressed, Gamepad_Buttons{.Y})
	testing.expect_value(t, input.gamepads[1].released, Gamepad_Buttons{.Start})
}

@(test)
gamepad_buttons_are_the_bits_of_xinput :: proc(t: ^testing.T) {
	testing.expect_value(t, transmute(u16)Gamepad_Buttons{.A}, 0x1000)
	testing.expect_value(t, transmute(u16)Gamepad_Buttons{.Right_Bumper}, 0x0200)
	testing.expect_value(t, transmute(u16)Gamepad_Buttons{.Dpad_Up}, 0x0001)
	// The bits that no button has are not read.
	input: Input
	input_gamepad_set(
		&input,
		0,
		{connected = true, buttons = transmute(Gamepad_Buttons)u16(0x0c00)},
	)
	testing.expect_value(t, input.gamepads[0].down, Gamepad_Buttons{})
}

@(test)
gamepad_dead_zones_rescale_the_axes :: proc(t: ^testing.T) {
	input: Input
	reading := Gamepad_Reading {
		connected = true,
	}
	reading.axes[.Left_X] = 0.2
	reading.axes[.Right_Y] = 0.2
	reading.axes[.Left_Trigger] = 0.1
	input_gamepad_set(&input, 0, reading)
	pad := &input.gamepads[0]
	testing.expect_value(t, pad.axes[.Left_X], 0)
	testing.expect_value(t, pad.axes[.Right_Y], 0)
	testing.expect_value(t, pad.axes[.Left_Trigger], 0)

	reading.axes[.Left_X] = 1
	reading.axes[.Right_Y] = -1
	reading.axes[.Left_Trigger] = 1
	input_gamepad_set(&input, 0, reading)
	testing.expect_value(t, pad.axes[.Left_X], 1)
	testing.expect_value(t, pad.axes[.Right_Y], -1)
	testing.expect_value(t, pad.axes[.Left_Trigger], 1)

	// A diagonal keeps its direction.
	reading.axes[.Left_X] = 0.6
	reading.axes[.Left_Y] = 0.6
	input_gamepad_set(&input, 0, reading)
	testing.expect_value(t, pad.axes[.Left_X], pad.axes[.Left_Y])
	testing.expect(t, pad.axes[.Left_X] > 0 && pad.axes[.Left_X] < 0.6)
}

@(test)
a_gamepad_that_goes_lets_go_of_everything :: proc(t: ^testing.T) {
	input: Input
	reading := Gamepad_Reading {
		connected = true,
		buttons   = {.B},
	}
	reading.axes[.Left_X] = 1
	input_gamepad_set(&input, 2, reading)
	input_begin_frame(&input)

	reading.connected = false
	input_gamepad_set(&input, 2, reading)
	pad := input.gamepads[2]
	testing.expect(t, !pad.connected)
	testing.expect_value(t, pad.down, Gamepad_Buttons{})
	testing.expect_value(t, pad.released, Gamepad_Buttons{.B})
	testing.expect_value(t, pad.axes[.Left_X], 0)
}

@(test)
releasing_all_keeps_the_pads_connected :: proc(t: ^testing.T) {
	input: Input
	reading := Gamepad_Reading {
		connected = true,
		buttons   = {.X},
	}
	reading.axes[.Right_Trigger] = 1
	input_apply(&input, {kind = .Gamepad, pad = 3, reading = reading})
	input_composition_utf16(&input, []u16{0x65e5}, 1)
	input_begin_frame(&input)

	input_apply(&input, {kind = .Release_All})
	pad := input.gamepads[3]
	testing.expect(t, pad.connected)
	testing.expect_value(t, pad.down, Gamepad_Buttons{})
	testing.expect_value(t, pad.released, Gamepad_Buttons{.X})
	testing.expect_value(t, pad.axes[.Right_Trigger], 0)
	testing.expect_value(t, input_text_string(&input.composition), "")
}

@(test)
a_gamepad_event_for_a_slot_that_does_not_exist_is_ignored :: proc(t: ^testing.T) {
	input: Input
	input_apply(&input, {kind = .Gamepad, pad = MAX_GAMEPADS, reading = {connected = true}})
	for pad in input.gamepads {
		testing.expect(t, !pad.connected)
	}
}

@(test)
characters_become_utf8_text_for_one_frame :: proc(t: ^testing.T) {
	input: Input
	high: u16
	for unit in ([]u16{'h', 0xe9, 0x65e5, 0xd83d, 0xde00}) {
		input_char(&input, &high, unit)
	}
	testing.expect_value(t, input_text_string(&input.text), "hé日😀")

	input_begin_frame(&input)
	testing.expect_value(t, input_text_string(&input.text), "")
}

@(test)
control_characters_and_lone_surrogates_are_not_text :: proc(t: ^testing.T) {
	input: Input
	high: u16
	for unit in ([]u16{0x08, '\r', '\t', 0x1b, 0x7f, 0x85, 0xde00, 0xd83d, 'a'}) {
		input_char(&input, &high, unit)
	}
	testing.expect_value(t, input_text_string(&input.text), "a")
}

@(test)
text_that_does_not_fit_is_cut_between_code_points :: proc(t: ^testing.T) {
	text: Input_Text
	for _ in 0 ..< INPUT_TEXT_CAPACITY - 2 {
		input_text_append(&text, "a")
	}
	input_text_append(&text, "日")
	testing.expect_value(t, int(text.length), INPUT_TEXT_CAPACITY - 2)
	input_text_append(&text, "éa")
	testing.expect_value(t, int(text.length), INPUT_TEXT_CAPACITY)
	testing.expect_value(t, input_text_string(&text)[INPUT_TEXT_CAPACITY - 2:], "é")
}

@(test)
text_events_add_and_composition_events_replace :: proc(t: ^testing.T) {
	input: Input
	first, second: Input_Text
	input_text_append(&first, "にほ")
	input_text_append(&second, "ん")
	input_apply(&input, {kind = .Text, text = first})
	input_apply(&input, {kind = .Text, text = second})
	testing.expect_value(t, input_text_string(&input.text), "にほん")

	input_apply(&input, {kind = .Composition, text = first, cursor = 3})
	input_apply(&input, {kind = .Composition, text = second, cursor = 3})
	testing.expect_value(t, input_text_string(&input.composition), "ん")
	testing.expect_value(t, input.composition_cursor, 3)
	// Composition is state, and stays while the frames go by.
	input_begin_frame(&input)
	testing.expect_value(t, input_text_string(&input.composition), "ん")

	// The cursor stays inside the text, whatever comes off the wire.
	input_apply(&input, {kind = .Composition, text = second, cursor = 100})
	testing.expect_value(t, input.composition_cursor, 3)
	input_apply(&input, {kind = .Composition, text = second, cursor = -1})
	testing.expect_value(t, input.composition_cursor, 0)
}

@(test)
an_imes_composition_has_its_cursor_in_bytes :: proc(t: ^testing.T) {
	input: Input
	// A kana, an emoji in two units, and a letter, with the cursor after the emoji.
	input_composition_utf16(&input, []u16{0x306b, 0xd83d, 0xde00, 'a'}, 3)
	testing.expect_value(t, input_text_string(&input.composition), "に😀a")
	testing.expect_value(t, input.composition_cursor, 7)

	input_composition_utf16(&input, nil, 0)
	testing.expect_value(t, input_text_string(&input.composition), "")
	testing.expect_value(t, input.composition_cursor, 0)
}

@(private = "file")
fake_pads: struct {
	readings: [MAX_GAMEPADS]Gamepad_Reading,
	reads:    [MAX_GAMEPADS]int,
}

@(private = "file")
fake_read :: proc(slot: int) -> Gamepad_Reading {
	fake_pads.reads[slot] += 1
	return fake_pads.readings[slot]
}

@(test)
a_pad_plugged_in_while_the_game_runs_is_found :: proc(t: ^testing.T) {
	fake_pads = {}
	input: Input
	poller: Gamepad_Poller
	now := time.tick_now()

	// A frame reads one empty slot at most, and the next frames read none until the interval has passed.
	gamepad_poll(&poller, &input, now, fake_read)
	gamepad_poll(&poller, &input, now, fake_read)
	testing.expect_value(
		t,
		fake_pads.reads[0] + fake_pads.reads[1] + fake_pads.reads[2] + fake_pads.reads[3],
		1,
	)

	fake_pads.readings[2] = {
		connected = true,
		buttons   = {.A},
	}
	for _ in 0 ..< MAX_GAMEPADS {
		now = time.tick_add(now, GAMEPAD_EMPTY_SLOT_INTERVAL)
		gamepad_poll(&poller, &input, now, fake_read)
	}
	testing.expect(t, input.gamepads[2].connected)
	testing.expect_value(t, input.gamepads[2].pressed, Gamepad_Buttons{.A})

	// A connected slot is read on every call.
	before := fake_pads.reads[2]
	gamepad_poll(&poller, &input, now, fake_read)
	testing.expect_value(t, fake_pads.reads[2], before + 1)

	// Pulled out with a button held, it lets go.
	input_begin_frame(&input)
	fake_pads.readings[2] = {}
	gamepad_poll(&poller, &input, now, fake_read)
	testing.expect(t, !input.gamepads[2].connected)
	testing.expect_value(t, input.gamepads[2].released, Gamepad_Buttons{.A})

	// Plugged in again, it is found again.
	input_begin_frame(&input)
	fake_pads.readings[2].connected = true
	for _ in 0 ..< MAX_GAMEPADS {
		now = time.tick_add(now, GAMEPAD_EMPTY_SLOT_INTERVAL)
		gamepad_poll(&poller, &input, now, fake_read)
	}
	testing.expect(t, input.gamepads[2].connected)
}

@(private = "file")
push :: proc(input: ^Input, slot: int, axes: [Gamepad_Axis]f32) {
	input_gamepad_set(input, slot, {connected = true, axes = axes})
}

@(test)
a_stick_direction_engages_and_lets_go_with_hysteresis :: proc(t: ^testing.T) {
	input: Input
	push(&input, 0, #partial{.Left_Y = 0.2})
	testing.expect_value(t, input.gamepads[0].direction_down, Gamepad_Directions{})
	push(&input, 0, #partial{.Left_Y = 0.8})
	testing.expect_value(t, input.gamepads[0].direction_down, Gamepad_Directions{.Left_Stick_Up})
	testing.expect_value(
		t,
		input.gamepads[0].direction_pressed,
		Gamepad_Directions{.Left_Stick_Up},
	)

	input_begin_frame(&input)
	// 0.56 of the raw range is 0.42 after the dead zone, between the two thresholds, so it stays held.
	axes: [Gamepad_Axis]f32
	axes[.Left_Y] = 0.56
	input_gamepad_set(&input, 0, {connected = true, axes = axes})
	testing.expect(t, .Left_Stick_Up in input.gamepads[0].direction_down)
	testing.expect_value(t, input.gamepads[0].direction_pressed, Gamepad_Directions{})

	push(&input, 0, #partial{.Left_Y = 0.2})
	testing.expect_value(t, input.gamepads[0].direction_down, Gamepad_Directions{})
	testing.expect_value(
		t,
		input.gamepads[0].direction_released,
		Gamepad_Directions{.Left_Stick_Up},
	)

	// Down and left are the other signs of the axes.
	push(&input, 0, #partial{.Left_X = -0.9, .Left_Y = -0.9})
	testing.expect_value(
		t,
		input.gamepads[0].direction_down,
		Gamepad_Directions{.Left_Stick_Down, .Left_Stick_Left},
	)
	push(&input, 0, #partial{.Right_X = 0.9})
	testing.expect_value(
		t,
		input.gamepads[0].direction_down,
		Gamepad_Directions{.Right_Stick_Right},
	)
}

@(test)
a_trigger_is_a_direction_past_half :: proc(t: ^testing.T) {
	input: Input
	push(&input, 1, #partial{.Right_Trigger = 0.5})
	testing.expect_value(t, input.gamepads[1].direction_down, Gamepad_Directions{})
	push(&input, 1, #partial{.Right_Trigger = 0.9, .Left_Trigger = 1})
	testing.expect_value(
		t,
		input.gamepads[1].direction_down,
		Gamepad_Directions{.Left_Trigger, .Right_Trigger},
	)
	// A pad that goes releases its directions.
	input_gamepad_set(&input, 1, {})
	testing.expect_value(t, input.gamepads[1].direction_down, Gamepad_Directions{})
	testing.expect_value(
		t,
		input.gamepads[1].direction_released,
		Gamepad_Directions{.Left_Trigger, .Right_Trigger},
	)
}

@(private = "file")
actions_with :: proc(actions: ^Input_Actions, name: string, bindings: ..string) -> (index: int) {
	parsed: [MAX_ACTION_BINDINGS]Binding
	for s, i in bindings {
		b, ok := binding_parse(s)
		assert(ok)
		parsed[i] = b
	}
	index, _ = input_actions_define(actions, name, parsed[:len(bindings)])
	return
}

@(test)
an_action_is_down_while_any_binding_is :: proc(t: ^testing.T) {
	actions: Input_Actions
	jump := actions_with(&actions, "jump", "key:Space", "pad:A", "pad:RightTrigger")
	input: Input
	testing.expect(t, !action_down(&actions, &input, jump))
	input_key_down(&input, .Space)
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, action_pressed(&actions, &input, jump))
	testing.expect_value(t, action_value(&actions, &input, jump), 1)
	input_begin_frame(&input)
	input_key_up(&input, .Space)
	testing.expect(t, !action_down(&actions, &input, jump))
	testing.expect(t, action_released(&actions, &input, jump))

	input_begin_frame(&input)
	input_gamepad_set(&input, 2, {connected = true, buttons = {.A}})
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect(t, action_pressed(&actions, &input, jump))

	input_begin_frame(&input)
	input_gamepad_set(&input, 2, {connected = true})
	push(&input, 3, #partial{.Right_Trigger = 1})
	testing.expect(t, action_down(&actions, &input, jump))
	testing.expect_value(t, action_value(&actions, &input, jump), 1)
	testing.expect(t, action_pressed(&actions, &input, jump))
}

@(test)
an_action_with_a_pad_reads_only_that_pad :: proc(t: ^testing.T) {
	actions: Input_Actions
	fire := actions_with(&actions, "fire", "key:F", "pad:B", "pad:LeftStickUp")
	input: Input
	input_key_down(&input, .F)
	input_gamepad_set(&input, 1, {connected = true, buttons = {.B}})
	push(&input, 0, #partial{.Left_Y = 1})
	testing.expect(t, action_down(&actions, &input, fire))
	testing.expect(t, action_down(&actions, &input, fire, 1))
	testing.expect(t, action_pressed(&actions, &input, fire, 0))
	testing.expect(t, !action_down(&actions, &input, fire, 2))
	testing.expect(t, !action_pressed(&actions, &input, fire, 3))
	testing.expect(t, !action_down(&actions, &input, fire, 4))
	// Keys are read only without a pad, so the held F does not count for pad 2.
	input_gamepad_set(&input, 1, {connected = true})
	push(&input, 0, {})
	testing.expect(t, !action_down(&actions, &input, fire, 1))
	testing.expect(t, action_down(&actions, &input, fire))
}

@(test)
a_binding_string_round_trips :: proc(t: ^testing.T) {
	buffer: [BINDING_FORMAT_CAPACITY]u8
	check :: proc(t: ^testing.T, b: Binding, buffer: []u8) {
		text := binding_format(b, buffer)
		testing.expect(t, text != "")
		parsed, ok := binding_parse(text)
		testing.expectf(t, ok && parsed == b, "%v became %q and then %v", b, text, parsed)
	}
	for key in Key {
		if key != .None {
			check(t, {.Key, u8(key)}, buffer[:])
		}
	}
	for button in Gamepad_Button {
		check(t, {.Button, u8(button)}, buffer[:])
	}
	for direction in Gamepad_Direction {
		check(t, {.Direction, u8(direction)}, buffer[:])
	}
	testing.expect_value(t, binding_format({.Key, u8(Key.W)}, buffer[:]), "key:W")
	testing.expect_value(t, binding_format({.Key, u8(Key.Page_Up)}, buffer[:]), "key:PageUp")
	testing.expect_value(
		t,
		binding_format({.Button, u8(Gamepad_Button.Dpad_Up)}, buffer[:]),
		"pad:DpadUp",
	)
	testing.expect_value(
		t,
		binding_format({.Direction, u8(Gamepad_Direction.Right_Trigger)}, buffer[:]),
		"pad:RightTrigger",
	)
	for bad in ([]string{"", "key:", "key:None", "key:w", "pad:Z", "pad:", "button:A", "W", "key:W "}) {
		_, ok := binding_parse(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
	}
}

@(test)
any_pressed_ignores_the_mouse :: proc(t: ^testing.T) {
	input: Input
	both := Input_Devices{.Keyboard, .Gamepad}
	input_key_down(&input, .Mouse_Left)
	_, ok := any_pressed(&input, both)
	testing.expect(t, !ok)

	input_key_down(&input, .Escape)
	b, found := any_pressed(&input, both)
	testing.expect(t, found && b == Binding{.Key, u8(Key.Escape)})
	_, found = any_pressed(&input, {.Gamepad})
	testing.expect(t, !found)

	input_begin_frame(&input)
	input_gamepad_set(&input, 0, {connected = true, buttons = {.Start}})
	b, found = any_pressed(&input, {.Gamepad})
	testing.expect(t, found && b == Binding{.Button, u8(Gamepad_Button.Start)})
	_, found = any_pressed(&input, {.Keyboard})
	testing.expect(t, !found)

	input_begin_frame(&input)
	push(&input, 0, #partial{.Left_X = 1})
	b, found = any_pressed(&input, {.Gamepad})
	testing.expect(t, found && b == Binding{.Direction, u8(Gamepad_Direction.Left_Stick_Right)})
}

@(test)
a_rumble_stops_when_its_time_is_up :: proc(t: ^testing.T) {
	rumbles: Rumbles
	now := time.tick_now()
	active := [MAX_GAMEPADS]bool{true, true, true, true}
	rumble_set(&rumbles, 1, 0.5, 1, 2, now)

	changes := rumble_update(&rumbles, now, active)
	testing.expect_value(t, changes[1], Motors{32768, 65535})
	// Still running just before its time.
	changes = rumble_update(
		&rumbles,
		time.tick_add(now, 2 * time.Second - time.Millisecond),
		active,
	)
	testing.expect_value(t, changes[1], nil)
	testing.expect(t, rumbles.slots[1] != nil)

	changes = rumble_update(&rumbles, time.tick_add(now, 2 * time.Second), active)
	testing.expect_value(t, changes[1], Motors{})
	testing.expect_value(t, rumbles.slots[1], nil)
}

@(test)
a_new_rumble_replaces_the_old :: proc(t: ^testing.T) {
	rumbles: Rumbles
	now := time.tick_now()
	active := [MAX_GAMEPADS]bool{true, true, true, true}
	rumble_set(&rumbles, 0, 1, 0, 5, now)
	rumble_update(&rumbles, now, active)

	rumble_set(&rumbles, 0, 0, 1, 1, now)
	changes := rumble_update(&rumbles, now, active)
	testing.expect_value(t, changes[0], Motors{0, 65535})

	// The new one's time is the one that counts, and a call of no time ends it.
	changes = rumble_update(&rumbles, time.tick_add(now, time.Second), active)
	testing.expect_value(t, changes[0], Motors{})
	rumble_set(&rumbles, 0, 1, 1, 5, now)
	rumble_set(&rumbles, 0, 1, 1, 0, now)
	testing.expect_value(t, rumbles.slots[0], nil)
}

@(test)
losing_focus_stops_every_motor :: proc(t: ^testing.T) {
	rumbles: Rumbles
	now := time.tick_now()
	active := [MAX_GAMEPADS]bool{true, true, true, true}
	rumble_set(&rumbles, 0, 1, 1, 5, now)
	rumble_set(&rumbles, 2, 0.5, 0, 5, now)
	rumble_update(&rumbles, now, active)

	// The window is not the foreground window: nothing is active.
	changes := rumble_update(&rumbles, now, {})
	testing.expect_value(t, changes[0], Motors{})
	testing.expect_value(t, changes[2], Motors{})
	testing.expect_value(t, changes[1], nil)
	for slot in rumbles.slots {
		testing.expect_value(t, slot, nil)
	}
	// The rumble is gone, not paused: the focus coming back does not bring it back.
	changes = rumble_update(&rumbles, now, active)
	for change in changes {
		testing.expect_value(t, change, nil)
	}

	// A pad that is pulled out loses its rumble the same way, and a stop at a restart stops what still runs.
	rumble_set(&rumbles, 3, 1, 1, 5, now)
	rumble_update(&rumbles, now, active)
	changes = rumble_update(&rumbles, now, {true, true, true, false})
	testing.expect_value(t, changes[3], Motors{})
	rumble_set(&rumbles, 1, 1, 1, 5, now)
	rumble_update(&rumbles, now, active)
	changes = rumble_stop_all(&rumbles)
	testing.expect_value(t, changes[1], Motors{})
}

@(test)
only_a_change_is_sent :: proc(t: ^testing.T) {
	rumbles: Rumbles
	now := time.tick_now()
	active := [MAX_GAMEPADS]bool{true, true, true, true}
	// A pad at rest is told nothing.
	changes := rumble_update(&rumbles, now, active)
	for change in changes {
		testing.expect_value(t, change, nil)
	}

	rumble_set(&rumbles, 0, 1, 0.5, 5, now)
	changes = rumble_update(&rumbles, now, active)
	testing.expect_value(t, changes[0], Motors{65535, 32768})
	// The same call again, and the next frames, change nothing.
	rumble_set(&rumbles, 0, 1, 0.5, 5, now)
	changes = rumble_update(&rumbles, time.tick_add(now, time.Second), active)
	testing.expect_value(t, changes[0], nil)
	// A value that rounds to the same speed is the same.
	rumble_set(&rumbles, 0, 1, 0.5 + 1e-7, 5, now)
	changes = rumble_update(&rumbles, time.tick_add(now, time.Second), active)
	testing.expect_value(t, changes[0], nil)
	rumble_set(&rumbles, 0, 1, 0.25, 5, now)
	changes = rumble_update(&rumbles, time.tick_add(now, time.Second), active)
	testing.expect_value(t, changes[0], Motors{65535, 16384})
}

package core

import "core:reflect"

MAX_INPUT_ACTIONS :: 32
MAX_ACTION_BINDINGS :: 8
INPUT_ACTION_NAME_CAPACITY :: 24

// Binding_Kind says which enum a Binding's code is a value of.
Binding_Kind :: enum u8 {
	None,
	Key,
	Button,
	Direction,
}

// Binding is one physical input: a key or mouse button, a gamepad button, or a stick direction or trigger.
Binding :: struct {
	kind: Binding_Kind,
	code: u8,
}

// Input_Action is a named action with the bindings that it starts with and the ones that it has now. It holds no
// strings or pointers, so it survives a code reload.
Input_Action :: struct {
	name:          [INPUT_ACTION_NAME_CAPACITY]u8,
	name_length:   u8,
	defaults:      [MAX_ACTION_BINDINGS]Binding,
	default_count: u8,
	current:       [MAX_ACTION_BINDINGS]Binding,
	current_count: u8,
}

// Input_Actions is the game's actions, which the scripts define and the player remaps.
Input_Actions :: struct {
	items: [MAX_INPUT_ACTIONS]Input_Action,
	count: int,
}

Input_Device :: enum u8 {
	Keyboard,
	Gamepad,
}

Input_Devices :: bit_set[Input_Device;u8]

// BINDING_FORMAT_CAPACITY is enough for any binding_format.
BINDING_FORMAT_CAPACITY :: 32

@(private = "file")
is_mouse :: proc "contextless" (key: Key) -> bool {
	return key >= .Mouse_Left && key <= .Mouse_5
}

// binding_valid is whether the code is a value that exists for the kind. A None binding is not valid.
binding_valid :: proc "contextless" (b: Binding) -> bool {
	switch b.kind {
	case .None:
		return false
	case .Key:
		return b.code > 0 && b.code <= u8(max(Key))
	case .Button:
		return b.code <= u8(max(Gamepad_Button)) && Gamepad_Button(b.code) in GAMEPAD_BUTTONS
	case .Direction:
		return b.code <= u8(max(Gamepad_Direction))
	}
	return false
}

// name_matches is whether an enum value's name, without its underscores, is s.
@(private = "file")
name_matches :: proc(name, s: string) -> bool {
	i := 0
	for c in transmute([]u8)name {
		if c == '_' {
			continue
		}
		if i >= len(s) || s[i] != c {
			return false
		}
		i += 1
	}
	return i == len(s)
}

@(private = "file")
find_enum :: proc(Enum: typeid, s: string) -> (u8, bool) {
	values := reflect.enum_field_values(Enum)
	for name, i in reflect.enum_field_names(Enum) {
		if name_matches(name, s) {
			return u8(values[i]), true
		}
	}
	return 0, false
}

@(private = "file")
enum_name :: proc(Enum: typeid, code: u8, buffer: []u8, prefix: string) -> string {
	n := copy(buffer, prefix)
	values := reflect.enum_field_values(Enum)
	for name, i in reflect.enum_field_names(Enum) {
		if u8(values[i]) == code {
			for c in transmute([]u8)name {
				if c != '_' && n < len(buffer) {
					buffer[n] = c
					n += 1
				}
			}
			break
		}
	}
	return string(buffer[:n])
}

// binding_format writes a binding as its script string: "key:W", "pad:DpadUp", "pad:LeftStickUp". The names are the
// enums' names without underscores, as scripts see them. The string is in buffer, which BINDING_FORMAT_CAPACITY bytes
// always fit. An invalid binding is "".
binding_format :: proc(b: Binding, buffer: []u8) -> string {
	if !binding_valid(b) {
		return ""
	}
	switch b.kind {
	case .Key:
		return enum_name(Key, b.code, buffer, "key:")
	case .Button:
		return enum_name(Gamepad_Button, b.code, buffer, "pad:")
	case .Direction:
		return enum_name(Gamepad_Direction, b.code, buffer, "pad:")
	case .None:
	}
	return ""
}

// binding_parse reads a binding's script string. Names are case sensitive. Mouse buttons are keys, so "key:MouseLeft"
// is a binding.
binding_parse :: proc(s: string) -> (Binding, bool) {
	if len(s) > 4 && s[:4] == "key:" {
		if code, ok := find_enum(Key, s[4:]); ok && Key(code) != .None {
			return {.Key, code}, true
		}
	} else if len(s) > 4 && s[:4] == "pad:" {
		if code, ok := find_enum(Gamepad_Button, s[4:]); ok {
			return {.Button, code}, true
		}
		if code, ok := find_enum(Gamepad_Direction, s[4:]); ok {
			return {.Direction, code}, true
		}
	}
	return {}, false
}

// input_actions_find is the index of the action with a name, or -1.
input_actions_find :: proc "contextless" (actions: ^Input_Actions, name: string) -> int {
	for &a, i in actions.items[:actions.count] {
		if string(a.name[:a.name_length]) == name {
			return i
		}
	}
	return -1
}

// input_action_name is an action's name. It points into the action.
input_action_name :: proc "contextless" (action: ^Input_Action) -> string {
	return string(action.name[:action.name_length])
}

// input_actions_define makes an action, or, when the name exists, gives it new defaults and keeps its current
// bindings. It fails for an empty or too long name, a full table, or more than MAX_ACTION_BINDINGS defaults.
input_actions_define :: proc "contextless" (
	actions: ^Input_Actions,
	name: string,
	defaults: []Binding,
) -> (
	index: int,
	ok: bool,
) {
	if len(name) == 0 ||
	   len(name) > INPUT_ACTION_NAME_CAPACITY ||
	   len(defaults) > MAX_ACTION_BINDINGS {
		return -1, false
	}
	index = input_actions_find(actions, name)
	fresh := index < 0
	if fresh {
		if actions.count >= MAX_INPUT_ACTIONS {
			return -1, false
		}
		index = actions.count
		actions.count += 1
		actions.items[index] = {}
		copy(actions.items[index].name[:], name)
		actions.items[index].name_length = u8(len(name))
	}
	a := &actions.items[index]
	a.defaults = {}
	copy(a.defaults[:], defaults)
	a.default_count = u8(len(defaults))
	if fresh {
		a.current = a.defaults
		a.current_count = a.default_count
	}
	return index, true
}

// input_actions_set gives an action its current bindings. It fails for more than MAX_ACTION_BINDINGS.
input_actions_set :: proc "contextless" (
	actions: ^Input_Actions,
	index: int,
	bindings: []Binding,
) -> bool {
	if len(bindings) > MAX_ACTION_BINDINGS {
		return false
	}
	a := &actions.items[index]
	a.current = {}
	copy(a.current[:], bindings)
	a.current_count = u8(len(bindings))
	return true
}

// input_actions_reset gives an action its defaults again.
input_actions_reset :: proc "contextless" (actions: ^Input_Actions, index: int) {
	a := &actions.items[index]
	a.current = a.defaults
	a.current_count = a.default_count
}

// pads_read is the slots that a query reads: the one slot of a pad, or all of them. A slot that is not connected
// has nothing down.
@(private = "file")
pads_read :: proc "contextless" (input: ^Input, pad: Maybe(int)) -> []Gamepad {
	if slot, ok := pad.?; ok {
		if slot < 0 || slot >= MAX_GAMEPADS {
			return nil
		}
		return input.gamepads[slot:slot + 1]
	}
	return input.gamepads[:]
}

@(private = "file")
Binding_State :: enum u8 {
	Down,
	Pressed,
	Released,
}

// binding_state reads one binding. With a pad, only that pad's slot is read, and keys are not. Without one, keys and
// every pad are.
@(private = "file")
binding_state :: proc "contextless" (
	input: ^Input,
	b: Binding,
	state: Binding_State,
	pad: Maybe(int),
) -> bool {
	if !binding_valid(b) {
		return false
	}
	switch b.kind {
	case .None:
	case .Key:
		if pad != nil {
			return false
		}
		keys := input.down
		switch state {
		case .Down:
		case .Pressed:
			keys = input.pressed
		case .Released:
			keys = input.released
		}
		return Key(b.code) in keys
	case .Button:
		for &p in pads_read(input, pad) {
			buttons := p.down
			switch state {
			case .Down:
			case .Pressed:
				buttons = p.pressed
			case .Released:
				buttons = p.released
			}
			if Gamepad_Button(b.code) in buttons {
				return true
			}
		}
	case .Direction:
		for &p in pads_read(input, pad) {
			directions := p.direction_down
			switch state {
			case .Down:
			case .Pressed:
				directions = p.direction_pressed
			case .Released:
				directions = p.direction_released
			}
			if Gamepad_Direction(b.code) in directions {
				return true
			}
		}
	}
	return false
}

@(private = "file")
action_state :: proc "contextless" (
	actions: ^Input_Actions,
	input: ^Input,
	index: int,
	state: Binding_State,
	pad: Maybe(int),
) -> bool {
	a := &actions.items[index]
	for b in a.current[:a.current_count] {
		if binding_state(input, b, state, pad) {
			return true
		}
	}
	return false
}

// action_down is whether any binding of an action is held. With a pad (a slot from 0), only that pad is read: its
// buttons and directions, not keys. Without one, the keys and every pad are.
action_down :: proc "contextless" (
	actions: ^Input_Actions,
	input: ^Input,
	index: int,
	pad: Maybe(int) = nil,
) -> bool {
	return action_state(actions, input, index, .Down, pad)
}

// action_pressed is whether any binding of an action went down since the previous frame.
action_pressed :: proc "contextless" (
	actions: ^Input_Actions,
	input: ^Input,
	index: int,
	pad: Maybe(int) = nil,
) -> bool {
	return action_state(actions, input, index, .Pressed, pad)
}

// action_released is whether any binding of an action went up since the previous frame.
action_released :: proc "contextless" (
	actions: ^Input_Actions,
	input: ^Input,
	index: int,
	pad: Maybe(int) = nil,
) -> bool {
	return action_state(actions, input, index, .Released, pad)
}

// action_value is 1 while a key or a button of the action is held, and otherwise the largest push of its stick
// directions and triggers, from 0 to 1.
action_value :: proc "contextless" (
	actions: ^Input_Actions,
	input: ^Input,
	index: int,
	pad: Maybe(int) = nil,
) -> f32 {
	a := &actions.items[index]
	value: f32
	for b in a.current[:a.current_count] {
		if b.kind == .Direction && binding_valid(b) {
			for &p in pads_read(input, pad) {
				value = max(value, gamepad_direction_value(&p, Gamepad_Direction(b.code)))
			}
		} else if binding_state(input, b, .Down, pad) {
			value = 1
		}
	}
	return value
}

// any_pressed is a key, button or direction that went down since the previous frame, on the devices. The mouse is
// not a device here, so a click is never an answer. Keys come first, then each pad's buttons and directions, in the
// order of their enums.
any_pressed :: proc "contextless" (input: ^Input, devices: Input_Devices) -> (Binding, bool) {
	if .Keyboard in devices {
		for key in Key {
			if key != .None && !is_mouse(key) && key in input.pressed {
				return {.Key, u8(key)}, true
			}
		}
	}
	if .Gamepad in devices {
		for &p in input.gamepads {
			for button in Gamepad_Button {
				if button in p.pressed {
					return {.Button, u8(button)}, true
				}
			}
			for direction in Gamepad_Direction {
				if direction in p.direction_pressed {
					return {.Direction, u8(direction)}, true
				}
			}
		}
	}
	return {}, false
}

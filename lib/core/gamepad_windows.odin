#+private
package core

import win "core:sys/windows"
import "core:time"

// XInputGetState can take milliseconds on a slot that has no pad, so a frame reads at most one of those, and a slot
// that has none finds a pad that is plugged in within four of these.
GAMEPAD_EMPTY_SLOT_INTERVAL :: 250 * time.Millisecond

Gamepad_Poller :: struct {
	last_empty_read: time.Tick,
	next_empty_slot: int,
}

// gamepad_poll reads the pads into input: each connected slot on every call, and one empty slot in turn every
// GAMEPAD_EMPTY_SLOT_INTERVAL. That is the whole of hot plugging: a slot that reads as gone becomes empty, and an empty
// slot that reads as connected has a pad.
gamepad_poll :: proc(poller: ^Gamepad_Poller, input: ^Input, now: time.Tick, read: proc(slot: int) -> Gamepad_Reading) {
	for pad, slot in input.gamepads {
		if pad.connected {
			input_gamepad_set(input, slot, read(slot))
		}
	}
	if time.tick_diff(poller.last_empty_read, now) < GAMEPAD_EMPTY_SLOT_INTERVAL {
		return
	}
	for i in 0 ..< MAX_GAMEPADS {
		slot := (poller.next_empty_slot + i) % MAX_GAMEPADS
		if !input.gamepads[slot].connected {
			input_gamepad_set(input, slot, read(slot))
			poller.next_empty_slot = (slot + 1) % MAX_GAMEPADS
			poller.last_empty_read = now
			return
		}
	}
}

// xinput_read reads a slot's pad.
xinput_read :: proc(slot: int) -> (reading: Gamepad_Reading) {
	state: win.XINPUT_STATE
	if win.XInputGetState(win.XUSER(slot), &state) != .SUCCESS {
		return
	}
	pad := state.Gamepad
	stick :: proc(value: i16) -> f32 {return max(f32(value) / 32767, -1)}
	reading.connected = true
	reading.buttons = transmute(Gamepad_Buttons)pad.wButtons
	reading.axes = {
		.Left_X        = stick(pad.sThumbLX),
		.Left_Y        = stick(pad.sThumbLY),
		.Right_X       = stick(pad.sThumbRX),
		.Right_Y       = stick(pad.sThumbRY),
		.Left_Trigger  = f32(pad.bLeftTrigger) / 255,
		.Right_Trigger = f32(pad.bRightTrigger) / 255,
	}
	return
}

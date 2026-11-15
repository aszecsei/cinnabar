package core

import "core:time"

// The longest that one gamepad_rumble call vibrates a pad, in seconds. A longer request is cut to it, so a game that
// stops calling, or a game that dies, leaves a pad that stops within this time.
MAX_RUMBLE_SECONDS :: 10

// Rumble is what a game asked one pad's motors to do: low is the low-frequency motor (the left one) and high is the
// high-frequency motor (the right one), each from 0 to 1, until a time.
Rumble :: struct {
	low, high: f32,
	until:     time.Tick,
}

// Motors is the speeds that a pad's motors run at: low, then high, in XInput's units (0 to 65535).
Motors :: [2]u16

// Rumbles is the host's state of the pads' motors. The host owns it, not the game, so the motors stop when the game's
// DLL is unloaded or fails. A slot with no rumble is nil. rumble_set is where a game's request enters, and
// rumble_update is where a rumble ends and where `sent` changes.
Rumbles :: struct {
	slots: [MAX_GAMEPADS]Maybe(Rumble),
	// What each pad's motors were last told. A pad starts at rest.
	sent:  [MAX_GAMEPADS]Motors,
}

// rumble_set makes a slot's rumble from the game's request, in place of the one it had. The values are clamped, and
// seconds is cut to MAX_RUMBLE_SECONDS. A request that lasts no time ends the slot's rumble. A slot that does not exist
// is ignored.
rumble_set :: proc(rumbles: ^Rumbles, slot: int, low, high: f32, seconds: f64, now: time.Tick) {
	if slot < 0 || slot >= MAX_GAMEPADS {
		return
	}
	// A comparison with NaN is false, so NaN is no rumble.
	if !(seconds > 0) || !(low > 0 || high > 0) {
		rumbles.slots[slot] = nil
		return
	}
	span := time.Duration(min(seconds, MAX_RUMBLE_SECONDS) * f64(time.Second))
	rumbles.slots[slot] = Rumble {
		low   = unit(low),
		high  = unit(high),
		until = time.tick_add(now, span),
	}
}

// rumble_update ends the rumbles that are over, and drops those of the slots that are not active: a pad that is
// gone, or every pad while the window has lost the focus. It returns the motors to tell each pad, for the slots whose
// motors differ from what they were last told, and records them as sent. Call it once a frame.
rumble_update :: proc(
	rumbles: ^Rumbles,
	now: time.Tick,
	active: [MAX_GAMEPADS]bool,
) -> (
	changes: [MAX_GAMEPADS]Maybe(Motors),
) {
	for slot in 0 ..< MAX_GAMEPADS {
		target: Motors
		if !active[slot] {
			rumbles.slots[slot] = nil
		} else if rumble, ok := rumbles.slots[slot].?; ok {
			if time.tick_diff(now, rumble.until) <= 0 {
				rumbles.slots[slot] = nil
			} else {
				target = {speed(rumble.low), speed(rumble.high)}
			}
		}
		if target != rumbles.sent[slot] {
			changes[slot] = target
			rumbles.sent[slot] = target
		}
	}
	return
}

// rumble_stop_all ends every rumble and returns the motors that must be told to stop: the pads that were not at rest.
// The host calls it when the game restarts or ends.
rumble_stop_all :: proc(rumbles: ^Rumbles) -> [MAX_GAMEPADS]Maybe(Motors) {
	return rumble_update(rumbles, {}, {})
}

@(private = "file")
unit :: proc(value: f32) -> f32 {
	// A comparison with NaN is false, so NaN is 0.
	if value >= 1 {
		return 1
	}
	return value if value > 0 else 0
}

@(private = "file")
speed :: proc(value: f32) -> u16 {
	return u16(value * 65535 + 0.5)
}

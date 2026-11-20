package cutscene

import "core:time"

import "cinnabar:core"
import "cinnabar:engine/ecs"

// SKIP_ACTION is the action that a player holds to skip a cutscene, when the project names no other.
SKIP_ACTION :: "skip"
// SKIP_HOLD is how long the skip action is held before it skips, when the project gives no other time.
SKIP_HOLD :: time.Second

// Skip_Input is the skip action and its hold (see docs/cinematics/skipping.md#input): the action's name, in bytes so it
// stays across a code reload, how long it is held before it skips, and the hold in progress.
Skip_Input :: struct {
	action:        [core.INPUT_ACTION_NAME_CAPACITY]u8,
	action_length: u8,
	hold:          time.Duration,
	state:         Skip_Hold,
}

// Skip_Hold is where a hold of the skip action is. nil is no hold: the action is up, or nothing can be skipped. Change
// it only in update_skip, set_skip_input and reset.
Skip_Hold :: union {
	Skip_Holding,
	Skip_Spent,
}

// Skip_Holding is a hold that began with a press while a playing cutscene could be skipped.
Skip_Holding :: struct {
	// How long the action has been down, in real time.
	held: time.Duration,
}

// Skip_Spent is a hold that skipped. It ends when the action is up, so one hold skips once.
Skip_Spent :: struct {}

// set_skip_input sets the skip action's name and its hold time: "" for SKIP_ACTION, and nil for SKIP_HOLD. A name
// longer than an action's name cannot name an action, so it is cut. A hold in progress ends.
set_skip_input :: proc(s: ^State, action: string, hold: Maybe(time.Duration)) {
	name := action if action != "" else SKIP_ACTION
	n := copy(s.skip.action[:], name)
	s.skip.action_length = u8(n)
	s.skip.hold = max(hold.? or_else SKIP_HOLD, 0)
	s.skip.state = nil
}

// update_skip reads the skip action once a frame, before update (see docs/cinematics/skipping.md#input). A press while
// a playing cutscene can be skipped begins a hold. The hold grows by the frame's real duration while the action is
// down and a playing cutscene can be skipped, and ends when either stops. When it reaches the hold time, it skips every
// playing cutscene that can be skipped, and then waits for the action to be up. The action reads through the input
// contexts, so the cutscene's context must allow it.
update_skip :: proc(s: ^State, w: ^ecs.World, input: ^core.Input, dt: time.Duration) {
	if s.actions == nil {
		return
	}
	index := core.input_actions_find(s.actions, string(s.skip.action[:s.skip.action_length]))
	down := index >= 0 && core.action_down(s.actions, input, index)
	if !down {
		s.skip.state = nil
		return
	}
	switch _ in s.skip.state {
	case nil:
		if !core.action_pressed(s.actions, input, index) || !any_skippable(s) {
			return
		}
		s.skip.state = Skip_Holding{}
	case Skip_Spent:
		return
	case Skip_Holding:
		if !any_skippable(s) {
			s.skip.state = nil
			return
		}
	}
	holding := &s.skip.state.(Skip_Holding)
	holding.held += max(dt, 0)
	if holding.held < s.skip.hold {
		return
	}
	for &p, slot in s.players {
		if status_of(p.state) == .Playing {
			skip(s, w, {u16(slot), p.generation})
		}
	}
	s.skip.state = Skip_Spent{}
}

// skip_progress is how far a hold of the skip action is, from 0 to 1, for the UI to show. It is 0 with no hold, and 1
// once the hold skipped, until the action is up.
skip_progress :: proc(s: ^State) -> f32 {
	switch hold in s.skip.state {
	case Skip_Holding:
		if s.skip.hold <= 0 {
			return 1
		}
		return f32(clamp(f64(hold.held) / f64(s.skip.hold), 0, 1))
	case Skip_Spent:
		return 1
	}
	return 0
}

// any_skippable is whether a playing cutscene can be skipped at its time.
@(private = "file")
any_skippable :: proc(s: ^State) -> bool {
	for &p, slot in s.players {
		if status_of(p.state) == .Playing && can_skip(s, {u16(slot), p.generation}) {
			return true
		}
	}
	return false
}

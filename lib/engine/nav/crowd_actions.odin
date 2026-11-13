package nav

import "core:log"

import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"

// The crowd's native actions (see docs/ai/agents.md#native-actions): move_to, which sends the agent to the position or
// the entity that a key of its blackboard holds, and runs until it arrives, and stop. The agent needs a Nav_Agent.

// Move_To_State is what move_to keeps between its ticks: its key's name's hash, the target that it last sent, and that
// move's ticket.
@(private = "file")
Move_To_State :: struct {
	key:    u32,
	ticket: u64,
	target: Crowd_Target,
}

#assert(size_of(Move_To_State) <= ai.MAX_ACTION_STATE)

// register_crowd_actions registers move_to and stop with the agents' AI. register calls it after ai.register, which
// clears the natives, so a code reload registers them again.
@(private)
register_crowd_actions :: proc(s: ^State, agents: ^ai.State) {
	move: ai.Native_Action = {
		name       = "move_to",
		params     = {{"key", .String}},
		state_size = size_of(Move_To_State),
		start      = move_to_start,
		tick       = move_to_tick,
		stop       = move_to_stop,
		data       = s,
	}
	ai.register_action(agents, move)
	ai.register_action(agents, {name = "stop", start = stop_start, data = s})
}

@(private = "file")
state_of_action :: proc(a: ^ai.Action_Context) -> ^Move_To_State {
	return (^Move_To_State)(raw_data(a.state))
}

@(private = "file")
move_to_start :: proc(a: ^ai.Action_Context) {
	m := state_of_action(a)
	if key, ok := ai.arg_text(a, "key"); ok {
		m.key = format.animation_graph_hash(key)
	}
}

// move_to_tick sends the agent to its key's target whenever the key holds another, and reads the status of its move:
// Succeeded when the agent arrives, Failed when no path reaches the target, the key holds neither a position nor an
// entity, or another move replaced it.
@(private = "file")
move_to_tick :: proc(a: ^ai.Action_Context) -> ai.Action_Status {
	s := (^State)(a.data)
	m := state_of_action(a)
	value, found := ai.get_hashed(a, m.key)
	target: Crowd_Target
	switch v in value {
	case ecs.World_Position:
		target = v
	case ecs.Entity:
		if v != 0 {
			target = v
		}
	case f32, i32, bool, ai.Enum_Index, [3]f32:
	}
	if !found || target == nil {
		log.warnf("nav: move_to's key of the agent %v holds no position or entity, so it fails", a.entity)
		return .Failed
	}
	if m.ticket == 0 || !same_target(target, m.target) {
		m.target = target
		m.ticket = move_to(job_crowd(s, a.system), a.entity, target)
		return .Running
	}
	move, ok := crowd_move(s, a.world, a.entity)
	if !ok {
		// An agent that the crowd has not given a slot yet waits for its next tick.
		return .Running if ecs.is_alive(a.world, a.entity) && ecs.has(a.world, a.entity, Nav_Agent) else .Failed
	}
	switch {
	case move.ticket < m.ticket:
		// The crowd applies the move in its next tick.
		return .Running
	case move.ticket > m.ticket || !same_target(move.target, m.target):
		return .Failed
	}
	#partial switch move.status {
	case .Arrived:
		return .Succeeded
	case .Failed, .Idle:
		return .Failed
	}
	return .Running
}

// move_to_stop stops the agent's move when the action is replaced before the move ends, if the move is still this
// action's. An agent that arrived stays Arrived, and one that failed, Failed.
@(private = "file")
move_to_stop :: proc(a: ^ai.Action_Context) {
	s := (^State)(a.data)
	m := state_of_action(a)
	if m.ticket == 0 {
		return
	}
	if move, ok := crowd_move(s, a.world, a.entity); ok && move.ticket == m.ticket && (move.status == .Arrived || move.status == .Failed) {
		return
	}
	stop(job_crowd(s, a.system), a.entity, m.ticket)
}

@(private = "file")
stop_start :: proc(a: ^ai.Action_Context) {
	stop(job_crowd((^State)(a.data), a.system), a.entity)
}

@(private = "file")
same_target :: proc(a, b: Crowd_Target) -> bool {
	switch x in a {
	case ecs.World_Position:
		y, ok := b.(ecs.World_Position)
		return ok && x == y
	case ecs.Entity:
		y, ok := b.(ecs.Entity)
		return ok && x == y
	}
	return b == nil
}

package ai

import "core:log"

import format "cinnabar:engine/asset/format"
import "cinnabar:engine/ecs"
import "cinnabar:engine/script"

// The agents' pool (see docs/ai/agents.md#agents). Each Agent gets a slot, which its Agent_State names: the
// blackboard's values, the decision module's state and the running action live in the slot, in the host's heap, so a
// code reload keeps them and the component stays small. A slot is freed when its entity goes, loses its Agent, or
// names another slot, and a copy of an entity gets a slot of its own.

// Agent_Waiting is an agent whose blackboard or decision has not loaded, or does not fit, so it does not think yet.
// warned is the reason that was last warned about, so each is warned about once.
Agent_Waiting :: struct {
	warned: Wait_Reason,
}

Wait_Reason :: enum u8 {
	None,
	Loading,
	Other_Blackboard,
	Unfitting,
	No_Module,
}

// Agent_Ready is an agent that thinks: its values, its module's state, its running action, and when it thinks.
// board_key and decision_key are the blobs' keys that it started with, so a recook starts it again.
Agent_Ready :: struct {
	board_key:    u64,
	decision_key: u64,
	values:       []byte,
	state:        []byte,
	// set_action is its only writer, besides the action systems, which stop the actions that they end.
	action:       Action_Phase,
	// The tick that it thinks in next, the tick that it last thought in, and how many times it thought.
	next_think:   u64,
	last_think:   u64,
	thinks:       u32,
	// What it perceives, which the ai perceive system makes when it first perceives, and nil before (see
	// docs/ai/perception.md#memory).
	perception:   ^Perception_Memory,
}

// Agent_Phase is where an agent is. nil is a free slot. set_phase is its only writer.
Agent_Phase :: union {
	Agent_Waiting,
	Agent_Ready,
}

Agent_Slot :: struct {
	entity:     ecs.Entity,
	// The GUIDs that its Agent named when it started, so a change starts it again.
	blackboard: format.Guid,
	decision:   format.Guid,
	phase:      Agent_Phase,
}

Agent_Pool :: struct {
	slots:       [dynamic]Agent_Slot,
	generations: [dynamic]u32,
	free:        [dynamic]u32,
}

// The phases of an agent's action. An action starts in the system of its kind: a native one in the next tick's ai
// actions, a script one in this tick's script step. Done is an action that succeeded or failed, which its decision
// sees until it starts another. nil is no action.
Native_Starting :: struct {
	ref: u32,
}
Script_Starting :: struct {
	ref: u32,
}
Native_Running :: struct {
	ref:    u32,
	hash:   u32,
	memory: [MAX_ACTION_STATE]byte,
}
Script_Running :: struct {
	ref:    u32,
	handle: script.Action_Handle,
}
Action_Done :: struct {
	ref:    u32,
	status: Action_Status,
}

Action_Phase :: union {
	Native_Starting,
	Script_Starting,
	Native_Running,
	Script_Running,
	Action_Done,
}

// Running is an action whose start was called, so its stop must be.
Running :: union {
	Native_Running,
	Script_Running,
}

// Ending is a running action whose agent replaced it or went, which its system stops.
Ending :: struct {
	entity: ecs.Entity,
	run:    Running,
}

@(private)
slot_of :: proc(s: ^State, h: Agent_Handle) -> ^Agent_Slot {
	if h.generation == 0 || int(h.index) >= len(s.agents.slots) || s.agents.generations[h.index] != h.generation {
		return nil
	}
	slot := &s.agents.slots[h.index]
	return slot if slot.phase != nil else nil
}

// agent_slot is an entity's slot, if its Agent_State names one that is its own.
@(private)
agent_slot :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (^Agent_Slot, Agent_Handle) {
	if !ecs.is_alive(w, e) {
		return nil, {}
	}
	state := ecs.get(w, e, Agent_State)
	if state == nil {
		return nil, {}
	}
	slot := slot_of(s, state.agent)
	if slot == nil || slot.entity != e {
		return nil, {}
	}
	return slot, state.agent
}

// ready_of is an entity's slot and its Ready phase, if it thinks.
@(private)
ready_of :: proc(s: ^State, w: ^ecs.World, e: ecs.Entity) -> (^Agent_Slot, ^Agent_Ready) {
	slot, _ := agent_slot(s, w, e)
	if slot == nil {
		return nil, nil
	}
	ready, _ := &slot.phase.(Agent_Ready)
	return slot, ready
}

@(private)
alloc_slot :: proc(s: ^State) -> Agent_Handle {
	p := &s.agents
	if n := len(p.free); n > 0 {
		index := p.free[n - 1]
		pop(&p.free)
		return {index, p.generations[index]}
	}
	append(&p.slots, Agent_Slot{})
	append(&p.generations, 1)
	return {u32(len(p.slots) - 1), 1}
}

// release_slot frees the memory of a slot's phase, without stopping its action.
@(private)
release_slot :: proc(s: ^State, slot: ^Agent_Slot) {
	if ready, ok := slot.phase.(Agent_Ready); ok {
		delete(ready.values, s.platform.heap_allocator)
		delete(ready.state, s.platform.heap_allocator)
		free(ready.perception, s.platform.heap_allocator)
	}
}

// set_phase is the only writer of an agent's phase. It hands a running action of the old phase to its system to stop,
// and frees what the old phase held.
@(private)
set_phase :: proc(s: ^State, slot: ^Agent_Slot, phase: Agent_Phase) {
	if ready, ok := &slot.phase.(Agent_Ready); ok {
		set_action(s, slot.entity, ready, nil)
	}
	release_slot(s, slot)
	slot.phase = phase
}

// set_action is the only writer of an agent's action, in serial code. It hands the action that ran to its system to
// stop.
@(private)
set_action :: proc(s: ^State, e: ecs.Entity, ready: ^Agent_Ready, next: Action_Phase) {
	switch a in ready.action {
	case Native_Running:
		append(&s.ending_native, Ending{e, a})
	case Script_Running:
		append(&s.ending_script, Ending{e, a})
	case Native_Starting, Script_Starting, Action_Done:
	}
	ready.action = next
}

@(private)
free_slot :: proc(s: ^State, index: u32) {
	slot := &s.agents.slots[index]
	set_phase(s, slot, nil)
	slot^ = {}
	g := &s.agents.generations[index]
	g^ += 1
	if g^ == 0 {
		g^ = 1
	}
	append(&s.agents.free, index)
}

// check_agents frees the slots of entities that went, lost their Agent, or whose Agent_State names another slot, starts
// again those whose Agent names other assets, and gives a slot to each Agent that has none, or whose Agent_State names
// a slot that is not its own, as a copy of an entity's does. The new Agent_States are added by command, after the tick.
@(private)
check_agents :: proc(s: ^State, w: ^ecs.World, commands: ^ecs.Commands) {
	for i in 0 ..< u32(len(s.agents.slots)) {
		slot := &s.agents.slots[i]
		if slot.phase == nil {
			continue
		}
		alive := ecs.is_alive(w, slot.entity)
		state := ecs.get(w, slot.entity, Agent_State) if alive else nil
		agent := ecs.get(w, slot.entity, Agent) if alive else nil
		if state == nil || agent == nil || state.agent != {i, s.agents.generations[i]} {
			free_slot(s, i)
			continue
		}
		if agent.blackboard != slot.blackboard || agent.decision != slot.decision {
			slot.blackboard, slot.decision = agent.blackboard, agent.decision
			set_phase(s, slot, Agent_Waiting{})
		}
	}
	add :: proc(s: ^State, w: ^ecs.World, commands: ^ecs.Commands, e: ecs.Entity) {
		agent := ecs.get(w, e, Agent)
		h := alloc_slot(s)
		slot := &s.agents.slots[h.index]
		slot^ = {
			entity     = e,
			blackboard = agent.blackboard,
			decision   = agent.decision,
		}
		set_phase(s, slot, Agent_Waiting{})
		ecs.command_add(commands, w, e, Agent_State{h})
	}
	fresh := make([dynamic]ecs.Entity, w.platform.frame_allocator)
	it := ecs.query_iter(w, s.new_agents)
	for view in ecs.query_next(&it) {
		append(&fresh, ..ecs.entities(view))
	}
	it = ecs.query_iter(w, s.states)
	for view in ecs.query_next(&it) {
		for state, row in ecs.column(view, 0, Agent_State) {
			e := ecs.entities(view)[row]
			if slot := slot_of(s, state.agent); (slot == nil || slot.entity != e) && ecs.has(w, e, Agent) {
				append(&fresh, e)
			}
		}
	}
	for e in fresh {
		add(s, w, commands, e)
	}
	// Writes that wait for an agent that went never apply.
	for i := 0; i < len(s.early); {
		if e := s.early[i].entity; !ecs.is_alive(w, e) || !ecs.has(w, e, Agent) {
			ordered_remove(&s.early, i)
		} else {
			i += 1
		}
	}
}

// ready_agents makes ready the waiting agents whose blobs are loaded and fit, from the blackboard's defaults, and starts
// again those whose blobs were recooked.
@(private)
ready_agents :: proc(s: ^State, w: ^ecs.World) {
	for &slot, index in s.agents.slots {
		switch p in slot.phase {
		case Agent_Waiting:
			reason, board, decision := fits(s, &slot)
			if reason != .None {
				if reason != p.warned && reason != .Loading {
					warn_waiting(&slot, reason)
				}
				set_phase(s, &slot, Agent_Waiting{reason})
				continue
			}
			start_agent(s, w, &slot, index, board, decision)
		case Agent_Ready:
			board, board_ok := board_of(s, slot.blackboard)
			decision, decision_ok := decision_of(s, slot.decision)
			if board_ok && decision_ok && (board.blob.header.key != p.board_key || decision.blob.header.key != p.decision_key) {
				set_phase(s, &slot, Agent_Waiting{})
				if reason, new_board, new_decision := fits(s, &slot); reason == .None {
					start_agent(s, w, &slot, index, new_board, new_decision)
				}
			}
		}
	}
}

// fits is why an agent cannot think yet, or None with its blobs.
@(private)
fits :: proc(s: ^State, slot: ^Agent_Slot) -> (reason: Wait_Reason, board: Board, decision: Decision) {
	board_ok, decision_ok: bool
	board, board_ok = board_of(s, slot.blackboard)
	decision, decision_ok = decision_of(s, slot.decision)
	switch {
	case !board_ok || !decision_ok:
		reason = .Loading
	case decision.blob.blackboard != slot.blackboard:
		reason = .Other_Blackboard
	case !format.decision_check(decision.data, decision.blob, board.data, board.blob):
		reason = .Unfitting
	case s.modules[decision.blob.technique].think == nil:
		reason = .No_Module
	}
	return
}

@(private)
warn_waiting :: proc(slot: ^Agent_Slot, reason: Wait_Reason) {
	switch reason {
	case .None, .Loading:
	case .Other_Blackboard:
		log.warnf("ai: entity %v's decision %s is for another blackboard than its Agent's", slot.entity, guid_text(slot.decision))
	case .Unfitting:
		log.warnf("ai: entity %v's decision %s was cooked against another version of its blackboard. Cook the content.", slot.entity, guid_text(slot.decision))
	case .No_Module:
		log.warnf("ai: entity %v's decision %s is of a technique that no module runs", slot.entity, guid_text(slot.decision))
	}
}

// start_agent starts an agent from its blackboard's defaults, with its module's state zero, and the writes that scripts
// made to it before it was ready. Its first think is placed by its slot, so agents that start together do not all think
// in the same tick.
@(private)
start_agent :: proc(s: ^State, w: ^ecs.World, slot: ^Agent_Slot, index: int, board: Board, decision: Decision) {
	heap := s.platform.heap_allocator
	ready := Agent_Ready {
		board_key    = board.blob.header.key,
		decision_key = decision.blob.header.key,
		values       = make([]byte, board.blob.values_size, heap),
		state        = make([]byte, decision.blob.state_size, heap),
	}
	copy(ready.values, format.blob_bytes(board.data, board.blob.defaults))
	now := w.clock.tick
	ready.next_think = now + stagger(index, interval_ticks(w, slot.entity))
	ready.last_think = now
	set_phase(s, slot, ready)
	ready_p := &slot.phase.(Agent_Ready)
	for i := 0; i < len(s.early); {
		c := s.early[i]
		if c.entity == slot.entity {
			apply_write(s, slot, ready_p, board, c)
			ordered_remove(&s.early, i)
		} else {
			i += 1
		}
	}
}

// interval_ticks is an agent's think interval in ticks, at least 1.
@(private)
interval_ticks :: proc(w: ^ecs.World, e: ecs.Entity) -> u64 {
	agent := ecs.get(w, e, Agent)
	if agent == nil || agent.interval <= 0 {
		return 1
	}
	return max(u64(f64(agent.interval) * f64(w.clock.tick_rate) + 0.5), 1)
}

// stagger is the ticks before a slot's first think: the slot's place on the golden ratio's sequence, in the interval,
// so that slots in a row spread over it evenly.
@(private)
stagger :: proc(index: int, interval: u64) -> u64 {
	GOLDEN :: 0.6180339887498949
	fraction := f64(index) * GOLDEN
	fraction -= f64(u64(fraction))
	return u64(fraction * f64(interval))
}

// value_bytes is a key's bytes in an agent's values.
@(private)
value_bytes :: proc(values: []byte, key: format.Blackboard_Key) -> []byte {
	return values[key.offset:][:format.blackboard_type_size(key.type)]
}

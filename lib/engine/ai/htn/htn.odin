// Package htn is the decision module of the HTN technique (see docs/ai/htn.md): on each think the agent decomposes its
// root task into a plan of actions by the methods of its compound tasks, in their order, and runs the plan with the
// plan runner that the planning techniques share (see ai.plan_think). While a plan runs, the module decomposes again
// on each think, as far as it takes to find a method traversal record better than the running plan's, and a better
// plan replaces the running one. A decomposition takes at most the agent's share of the plan budget in each think, and
// goes on in the next tick. The phase, the plan, its record and the decomposition are in the agent's module state, so a
// code reload keeps them, and the module holds no state of its own.
package htn

import "base:runtime"

import "cinnabar:engine/ai"
import format "cinnabar:engine/asset/format"

// register registers the module with the agents' AI. Call it in register_world, after ai.register, which clears the
// modules, so a code reload registers it again.
register :: proc(s: ^ai.State) {
	ai.register_module(s, .Htn, {think = think, check = check, searching = searching, plan = plan})
}

// check checks a decision's tasks, methods and actions against the decision and its blackboard, once, before an agent
// starts with it.
check :: proc(decision: ai.Decision, board: ai.Board) -> bool {
	data := format.decision_technique_data(decision.data, decision.blob)
	return format.htn_check(data, decision.data, decision.blob, board.data, board.blob)
}

// searching is whether the agent decomposes, for a plan or for a better one, so its next think goes on with it.
searching :: proc(state: []byte) -> bool {
	if len(state) < size_of(format.Htn_Agent) {
		return false
	}
	phase := (^format.Htn_Agent)(raw_data(state)).phase
	return phase == .Planning || phase == .Checking
}

// View is the parts of an agent's module state and its decision's data.
@(private)
View :: struct {
	h:      format.Htn_Data,
	layout: format.Htn_State,
	shared: []format.Decision_Node,
	domain: ai.Plan_Domain,
	agent:  ^format.Htn_Agent,
	plan:   ai.Plan,
	// The running plan's record, of MAX_HTN_RECORD choices, of which the agent's record_length are the record.
	record: []format.Htn_Choice,
}

@(private)
view_of :: proc(decision: ai.Decision, state: []byte) -> (v: View) {
	v.h = format.htn_data(format.decision_technique_data(decision.data, decision.blob))
	v.layout = format.htn_state_of(v.h)
	v.shared = format.decision_nodes(decision.data, decision.blob)
	v.domain = {
		keys    = v.h.keys,
		actions = v.h.actions,
		tests   = v.h.tests,
		effects = v.h.effects,
	}
	v.agent = (^format.Htn_Agent)(raw_data(state))
	v.plan = {
		run      = (^format.Plan_Run)(&state[format.HTN_RUN]),
		steps    = ([^]u16)(&state[v.layout.steps])[:v.h.header.max_plan],
		expected = ([^]i32)(&state[v.layout.expected])[:v.h.header.key_count],
	}
	v.record = ([^]format.Htn_Choice)(&state[v.layout.record])[:format.MAX_HTN_RECORD]
	return
}

// think runs the plan, and decomposes: for a plan when the agent has none, and for a better one while a plan runs. A
// plan ends when it is done or the runner asks to plan again, and the agent then decomposes its root again.
think :: proc(t: ^ai.Think_Context) {
	v := view_of(t.decision, t.state)
	world := ai.plan_world(t, v.h.keys)
	if v.agent.phase == .Running || v.agent.phase == .Checking {
		// The runner applies the effects that it writes to world, so a new decomposition begins on the world as they
		// leave it.
		if ai.plan_think(t, v.domain, v.plan, nil, &world) != .Running {
			v.agent.phase = .Idle
		}
	}
	switch v.agent.phase {
	case .Idle:
		begin(t, &v, world[:v.h.header.key_count], false)
	case .Running:
		begin(t, &v, world[:v.h.header.key_count], true)
	case .Planning, .Checking:
		decompose(t, &v)
	}
}

// begin begins a decomposition from a world state, with the methods and actions whose guards hold now: for a plan, or,
// bounded by the running plan's record, for a better one. It takes no step until the next think, which has a share of
// the plan budget.
@(private)
begin :: proc(t: ^ai.Think_Context, v: ^View, world: []i32, bounded: bool) {
	d := decomposition_of(v.h, v.layout, t.state)
	copy(d.begin, world)
	for &bits in d.usable_methods {
		bits = 0
	}
	for &bits in d.usable_actions {
		bits = 0
	}
	for m, i in v.h.methods {
		if ai.condition_holds(t, v.shared[m.node].condition) {
			d.usable_methods[i / 32] |= 1 << u32(i % 32)
		}
	}
	for a, i in v.h.actions {
		if ai.condition_holds(t, v.shared[a.node].condition) {
			d.usable_actions[i / 32] |= 1 << u32(i % 32)
		}
	}
	decompose_begin(&d, bounded)
	v.agent.phase = .Checking if bounded else .Planning
}

// decompose goes on with the agent's decomposition, within its share of the plan budget. A plan that it finds starts if
// it still holds in the world state now. Otherwise a decomposition for a plan begins again from the world state now,
// and the running plan goes on after a decomposition for a better one. A decomposition that fails leaves the agent
// without a plan until its next think, and one that is not better leaves the running plan.
@(private)
decompose :: proc(t: ^ai.Think_Context, v: ^View) {
	d := decomposition_of(v.h, v.layout, t.state)
	checking := v.agent.phase == .Checking
	switch decompose_step(&d, v.h, v.record[:v.agent.record_length], t.plan_budget) {
	case .Decomposing:
		return
	case .Found:
		v.agent.steps = d.header.steps
		switch {
		case adopt(t, v, &d):
			v.agent.phase = .Running
		case checking:
			v.agent.phase = .Running
		case:
			world := ai.plan_world(t, v.h.keys)
			begin(t, v, world[:v.h.header.key_count], false)
		}
	case .Failed:
		v.agent.steps = d.header.steps
		v.agent.phase = .Idle
	case .Not_Better:
		v.agent.steps = d.header.steps
		v.agent.phase = .Running
	}
}

// adopt starts the plan that a decomposition found, with its record, if it holds from the world state now and its first
// action's guard holds. Its first action replaces the one that runs, unless it is the same action reference, which
// goes on running. It is false, and changes nothing, when the plan does not hold.
@(private)
adopt :: proc(t: ^ai.Think_Context, v: ^View, d: ^Decomposition) -> bool {
	length := d.header.plan_length
	if length == 0 {
		return false
	}
	steps := d.plan[:length]
	world := ai.plan_world(t, v.h.keys)
	if !ai.plan_holds(v.domain, steps, world, nil) || !ai.condition_holds(t, v.shared[v.h.actions[steps[0]].node].condition) {
		return false
	}
	copy(v.plan.steps, steps)
	copy(v.record, d.choices[:d.header.choice_count])
	v.agent.record_length = d.header.choice_count
	return ai.plan_start(t, v.domain, v.plan, length, nil)
}

// plan gives the agent's plan, the methods that its decomposition chose and its step while it runs one, and the steps
// of its last decomposition, for debuggers and scripts (see ai.plan). An HTN plan has no goal.
plan :: proc(decision: ai.Decision, board: ai.Board, state: []byte, allocator: runtime.Allocator) -> ai.Plan_View {
	v := view_of(decision, state)
	actions := format.decision_actions(decision.data, decision.blob)
	result := ai.Plan_View {
		nodes     = int(v.agent.steps),
		searching = searching(state),
	}
	if v.agent.phase != .Running && v.agent.phase != .Checking {
		return result
	}
	run := v.plan.run
	result.steps = make([]ai.Plan_Step, run.length, allocator)
	for step, i in v.plan.steps[:run.length] {
		node := v.shared[v.h.actions[step].node]
		result.steps[i] = {node.id, format.blob_string(decision.data, actions[node.action].name)}
	}
	result.methods = make([]ai.Plan_Method, v.agent.record_length, allocator)
	for choice, i in v.record[:v.agent.record_length] {
		task := v.h.tasks[choice.task]
		method := v.h.methods[task.first_method + u32(choice.method)]
		result.methods[i] = {v.shared[task.node].id, v.shared[method.node].id}
	}
	result.step = int(run.step)
	return result
}

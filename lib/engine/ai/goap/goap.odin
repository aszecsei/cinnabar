// Package goap is the decision module of the GOAP technique (see docs/ai/goap.md): on each think the agent picks the
// goal of the highest priority whose desired state is not yet true, searches for the cheapest plan of actions whose
// effects reach it, by a regressive A* over the planning keys, and runs the plan with the plan runner that the planning
// techniques share (see ai.plan_think). The search expands at most the agent's share of the plan budget in each think,
// and goes on in the next tick. The phase, the plan, the search and the goals that failed are in the agent's module
// state, so a code reload keeps them, and the module holds no state of its own.
package goap

import "base:runtime"
import "core:slice"

import "cinnabar:engine/ai"
import "cinnabar:engine/ai/goap/search"
import "cinnabar:engine/ai/utility"
import format "cinnabar:engine/asset/format"

// The least cost of an action (see search.MIN_COST).
MIN_COST :: search.MIN_COST

// register registers the module with the agents' AI. Call it in register_world, after ai.register, which clears the
// modules, so a code reload registers it again.
register :: proc(s: ^ai.State) {
	ai.register_module(s, .Goap, {think = think, check = check, searching = searching, plan = plan})
}

// check checks a decision's goals and actions against the decision and its blackboard, once, before an agent starts
// with it.
check :: proc(decision: ai.Decision, board: ai.Board) -> bool {
	data := format.decision_technique_data(decision.data, decision.blob)
	return format.goap_check(data, decision.data, decision.blob, board.data, board.blob)
}

// searching is whether the agent searches for a plan, so its next think goes on with the search.
searching :: proc(state: []byte) -> bool {
	return len(state) >= size_of(format.Goap_Agent) && (^format.Goap_Agent)(raw_data(state)).phase == .Searching
}

// View is the parts of an agent's module state and its decision's data.
@(private)
View :: struct {
	g:          format.Goap_Data,
	layout:     format.Goap_State,
	shared:     []format.Decision_Node,
	domain:     ai.Plan_Domain,
	agent:      ^format.Goap_Agent,
	plan:       ai.Plan,
	priorities: []f32,
	failed_at:  []i32,
}

@(private)
view_of :: proc(decision: ai.Decision, state: []byte) -> (v: View) {
	v.g = format.goap_data(format.decision_technique_data(decision.data, decision.blob))
	v.layout = format.goap_state_of(v.g)
	v.shared = format.decision_nodes(decision.data, decision.blob)
	v.domain = {
		keys    = v.g.keys,
		actions = v.g.actions,
		tests   = v.g.tests,
		effects = v.g.effects,
	}
	k := int(v.g.header.key_count)
	v.agent = (^format.Goap_Agent)(raw_data(state))
	v.plan = {
		run      = (^format.Plan_Run)(&state[format.GOAP_RUN]),
		steps    = ([^]u16)(&state[v.layout.steps])[:v.g.header.max_plan],
		expected = ([^]i32)(&state[v.layout.expected])[:k],
	}
	v.priorities = ([^]f32)(&state[v.layout.priorities])[:v.g.header.goal_count]
	v.failed_at = ([^]i32)(&state[v.layout.failed_at])[:k]
	return
}

// goal_tests is a goal's desired state.
@(private)
goal_tests :: proc(v: ^View, goal: u32) -> []format.Plan_Test {
	g := v.g.goals[goal]
	return v.g.tests[g.first_test:][:g.test_count]
}

// think runs the plan, picks the current goal, and searches for a plan when the agent has none for it. A plan ends when
// it is done or the runner asks to plan again, and also when another goal becomes current, which stops its action.
think :: proc(t: ^ai.Think_Context) {
	v := view_of(t.decision, t.state)
	k := int(v.g.header.key_count)
	world := ai.plan_world(t, v.g.keys)
	if v.agent.failed != 0 && !slice.equal(world[:k], v.failed_at) {
		v.agent.failed = 0
	}
	if v.agent.phase == .Running {
		// The runner applies the effects that it writes to world, so the goals are picked on the world as they leave it.
		if ai.plan_think(t, v.domain, v.plan, goal_tests(&v, v.agent.goal - 1), &world) != .Running {
			v.agent.phase = .Idle
		}
	}
	goal := current_goal(t, &v, world[:k])
	switch v.agent.phase {
	case .Running:
		if goal + 1 != int(v.agent.goal) {
			ai.stop_action(t)
			v.agent.phase = .Idle
		}
	case .Searching:
		if goal + 1 != int(v.agent.goal) {
			v.agent.phase = .Idle
		} else {
			go_on(t, &v)
			if v.agent.phase == .Idle {
				goal = current_goal(t, &v, world[:k])
			}
		}
	case .Idle:
	}
	if v.agent.phase != .Idle {
		return
	}
	v.agent.goal = 0
	if goal >= 0 {
		begin(t, &v, u32(goal), world[:k])
	}
}

// current_goal scores each goal's priority, which it keeps in the state, and is the goal of the highest priority above
// 0 whose desired state is not true in the world state and which did not fail, the first of equal ones, or -1. A goal
// whose guard does not hold has priority 0. Otherwise its priority is its weight times its considerations' scores, each
// made up for their count, as a utility option's score is (see docs/ai/utility.md#scoring).
@(private)
current_goal :: proc(t: ^ai.Think_Context, v: ^View, world: []i32) -> int {
	best, best_priority := -1, 0.0
	for goal, i in v.g.goals {
		priority := 0.0
		if ai.condition_holds(t, v.shared[goal.node].condition) {
			priority = f64(goal.priority)
			count := int(goal.link_count)
			for link in v.g.links[goal.first_link:][:goal.link_count] {
				_, y := utility.consider(t, v.g.considerations[link], v.g.points)
				priority *= utility.compensate(y, count)
			}
		}
		v.priorities[i] = f32(priority)
		if priority > best_priority && v.agent.failed & (1 << u32(i)) == 0 && !ai.plan_tests_hold(goal_tests(v, u32(i)), world) {
			best, best_priority = i, priority
		}
	}
	return best
}

// begin begins a search for a goal from a world state, with the actions whose guards hold now and their costs now. It
// expands no node until the next think, which has a share of the plan budget.
@(private)
begin :: proc(t: ^ai.Think_Context, v: ^View, goal: u32, world: []i32) {
	s := search.of(v.g, v.layout, t.state)
	copy(s.world, world)
	for &bits in s.usable {
		bits = 0
	}
	for a, i in v.g.actions {
		if ai.condition_holds(t, v.shared[a.node].condition) {
			s.usable[i / 32] |= 1 << u32(i % 32)
		}
		s.costs[i] = f32(max(ai.plan_number(t, a.cost), MIN_COST))
	}
	search.begin(&s, v.g, v.g.goals[goal])
	v.agent.phase = .Searching
	v.agent.goal = goal + 1
}

// go_on goes on with the search for the agent's goal, within its share of the plan budget. A plan that it finds
// starts if it still holds in the world state now, or else the search begins again from that state. A search that
// fails marks its goal failed, until a planning key changes from the world state that it failed in.
@(private)
go_on :: proc(t: ^ai.Think_Context, v: ^View) {
	s := search.of(v.g, v.layout, t.state)
	goal := v.agent.goal - 1
	result, found := search.step(&s, v.g, t.plan_budget)
	switch result {
	case .Searching:
	case .Found:
		v.agent.nodes = s.header.node_count
		length := search.plan(&s, found, v.plan.steps)
		if ai.plan_start(t, v.domain, v.plan, length, goal_tests(v, goal)) {
			v.agent.phase = .Running
		} else {
			world := ai.plan_world(t, v.g.keys)
			begin(t, v, goal, world[:v.g.header.key_count])
		}
	case .Failed:
		v.agent.nodes = s.header.node_count
		v.agent.failed |= 1 << goal
		copy(v.failed_at, s.world)
		v.agent.phase = .Idle
	}
}

// plan gives the agent's goal, the goals' priorities in its last think, and its plan and step while it runs one, for
// debuggers and scripts (see ai.plan).
plan :: proc(decision: ai.Decision, board: ai.Board, state: []byte, allocator: runtime.Allocator) -> ai.Plan_View {
	v := view_of(decision, state)
	actions := format.decision_actions(decision.data, decision.blob)
	result := ai.Plan_View {
		goals     = make([]ai.Goal_Priority, len(v.g.goals), allocator),
		nodes     = int(v.agent.nodes),
		searching = v.agent.phase == .Searching,
	}
	for goal, i in v.g.goals {
		result.goals[i] = {v.shared[goal.node].id, v.priorities[i]}
	}
	if v.agent.goal != 0 {
		result.goal = v.shared[v.g.goals[v.agent.goal - 1].node].id
	}
	if v.agent.phase == .Running {
		run := v.plan.run
		result.steps = make([]ai.Plan_Step, run.length, allocator)
		for step, i in v.plan.steps[:run.length] {
			node := v.shared[v.g.actions[step].node]
			result.steps[i] = {node.id, format.blob_string(decision.data, actions[node.action].name)}
		}
		result.step = int(run.step)
	}
	return result
}

package ai

import "core:math"

import format "cinnabar:engine/asset/format"

// The plan runner (see docs/ai/goap.md#the-plan-runner), which the planning techniques share: a plan is a list of
// actions in the agent's module state, however it was made. The runner starts each action, and when one succeeds, it
// writes the action's effects to the blackboard and starts the next, after it checks the next action's guard and
// preconditions. It tells its module to plan again when an action fails or is replaced, when the next action's guard or
// preconditions do not hold, or when a planning key that the rest of the plan depends on is not the value that the plan
// expects. The planner's world state is the planning keys' values (see format.Plan_Test).

// Plan_View is an agent's goal or methods and its plan, for debuggers and scripts (see plan).
Plan_View :: struct {
	// The goal's decision node ID, or 0 for none.
	goal:      u32,
	// Each goal's priority in the last think.
	goals:     []Goal_Priority,
	steps:     []Plan_Step,
	// The methods that the plan's decomposition chose, in its order, for an HTN plan.
	methods:   []Plan_Method,
	// The step that runs, from 0. It is len(steps) when the plan is done or there is none.
	step:      int,
	// The nodes of the last search that ended.
	nodes:     int,
	// Whether the agent searches for a plan now.
	searching: bool,
}

// Goal_Priority is a goal's decision node ID and its priority in the last think.
Goal_Priority :: struct {
	id:       u32,
	priority: f32,
}

// Plan_Step is an action of a plan: its decision node's ID and its action's name.
Plan_Step :: struct {
	id:     u32,
	action: string,
}

// Plan_Method is a choice of a decomposition: the compound task's decision node ID, and the ID of the method that it
// chose.
Plan_Method :: struct {
	task:   u32,
	method: u32,
}

// Plan_World is a world state: each planning key's value, by its index among the planning keys.
Plan_World :: [format.MAX_PLAN_KEYS]i32

// Plan_Domain is what the runner reads of a technique's data: the planning keys' slots, and the actions with their
// tests and effects.
Plan_Domain :: struct {
	keys:    []u32,
	actions: []format.Plan_Action,
	tests:   []format.Plan_Test,
	effects: []format.Plan_Effect,
}

// Plan is a plan in the agent's module state: the runner's state, the plan's actions by index, at least its length of
// them, and the world state that the plan expects now, one value for each planning key.
Plan :: struct {
	run:      ^format.Plan_Run,
	steps:    []u16,
	expected: []i32,
}

// Plan_Result is how a plan is after the runner's think: still running, done after its last action succeeded, or to be
// made again.
Plan_Result :: enum u8 {
	Running,
	Done,
	Replan,
}

// plan_world is the world state of the agent's values: a bool is 0 or 1, an int is itself, and an enum is its index.
plan_world :: proc(t: ^Think_Context, keys: []u32) -> (w: Plan_World) {
	board_keys := format.blackboard_keys(t.board.data, t.board.blob)
	for slot, i in keys {
		key := board_keys[slot]
		bytes := value_bytes(t.values, key)
		#partial switch key.type {
		case .Bool:
			w[i] = 1 if bytes[0] != 0 else 0
		case .Int:
			w[i] = (^i32)(raw_data(bytes))^
		case .Enum:
			w[i] = i32((^u32)(raw_data(bytes))^)
		}
	}
	return
}

// plan_tests_hold is whether each test holds in a world state.
plan_tests_hold :: proc "contextless" (tests: []format.Plan_Test, world: []i32) -> bool {
	for test in tests {
		if v := world[test.key]; v < test.lo || v > test.hi {
			return false
		}
	}
	return true
}

// plan_apply applies effects to a world state, in their order. An add saturates at an i32's limits.
plan_apply :: proc "contextless" (effects: []format.Plan_Effect, world: []i32) {
	for e in effects {
		switch e.op {
		case .Set:
			world[e.key] = e.value
		case .Add:
			world[e.key] = i32(clamp(i64(world[e.key]) + i64(e.value), i64(min(i32)), i64(max(i32))))
		}
	}
}

// plan_action_tests is an action's preconditions.
plan_action_tests :: proc "contextless" (d: Plan_Domain, a: format.Plan_Action) -> []format.Plan_Test {
	return d.tests[a.first_test:][:a.test_count]
}

// plan_action_effects is an action's effects.
plan_action_effects :: proc "contextless" (d: Plan_Domain, a: format.Plan_Action) -> []format.Plan_Effect {
	return d.effects[a.first_effect:][:a.effect_count]
}

// plan_number is a number's value: its constant, or its key's as the blackboard is now. A number that is not finite is
// 0.
plan_number :: proc(t: ^Think_Context, n: format.Plan_Number) -> f64 {
	value := f64(n.value)
	if n.source == .Key {
		value = key_number(t, n.key)
	}
	if math.is_nan(value) || math.is_inf(value) {
		return 0
	}
	return value
}

// plan_holds is whether a plan reaches its goal from a world state: each action's preconditions hold in its turn, with
// the effects of the actions before it, and the goal's tests hold after the last. A plan without a goal, as an HTN plan,
// passes no goal tests.
plan_holds :: proc "contextless" (d: Plan_Domain, steps: []u16, world: Plan_World, goal: []format.Plan_Test) -> bool {
	world := world
	for step in steps {
		a := d.actions[step]
		if !plan_tests_hold(plan_action_tests(d, a), world[:]) {
			return false
		}
		plan_apply(plan_action_effects(d, a), world[:])
	}
	return plan_tests_hold(goal, world[:])
}

// plan_depends is the planning keys that the rest of a plan depends on, as a set of their indices: those that the
// preconditions of its actions from the step that runs test, and those that its goal tests.
plan_depends :: proc "contextless" (d: Plan_Domain, p: Plan, goal: []format.Plan_Test) -> (keys: u32) {
	for step in p.steps[p.run.step:p.run.length] {
		for test in plan_action_tests(d, d.actions[step]) {
			keys |= 1 << test.key
		}
	}
	for test in goal {
		keys |= 1 << test.key
	}
	return
}

// plan_start starts a plan whose actions are in its steps, of a length, if it reaches its goal from the world state now
// and its first action's guard holds: it expects the world state as it is now, and starts the first action. It is
// false, and starts nothing, when the plan does not hold.
plan_start :: proc(t: ^Think_Context, d: Plan_Domain, p: Plan, length: u32, goal: []format.Plan_Test) -> bool {
	world := plan_world(t, d.keys)
	shared := format.decision_nodes(t.decision.data, t.decision.blob)
	if length == 0 || !plan_holds(d, p.steps[:length], world, goal) || !condition_holds(t, shared[d.actions[p.steps[0]].node].condition) {
		return false
	}
	p.run^ = {
		step   = 0,
		length = length,
	}
	copy(p.expected, world[:len(p.expected)])
	p.run.depends = plan_depends(d, p, goal)
	start_step(t, d.actions[p.steps[0]])
	return true
}

// plan_think runs a plan for a think. While its action runs, it checks the keys that the rest of the plan depends on
// against the world state that it expects, and stops the action and asks to plan again when one differs. When the
// action succeeds, it writes the action's effects, which the world state that it expects gains, and starts the next
// action if the keys that the rest depends on are as expected and the next action's guard and preconditions hold, in
// the world state as the effects leave it. It asks to plan again when the action failed or another replaced it. world is
// the world state now, as plan_world reads it, and it gains the effects that the runner writes, which apply only after
// the tick, so the module can pick its goal on the world as they leave it.
plan_think :: proc(t: ^Think_Context, d: Plan_Domain, p: Plan, goal: []format.Plan_Test, world: ^Plan_World) -> Plan_Result {
	shared := format.decision_nodes(t.decision.data, t.decision.blob)
	run := p.run
	if run.step >= run.length {
		return .Done
	}
	a := d.actions[p.steps[run.step]]
	if t.action.ref != shared[a.node].action || t.action.status == .Failed {
		return .Replan
	}
	if t.action.status == .Running {
		if !as_expected(world[:], p.expected, run.depends) {
			stop_action(t)
			return .Replan
		}
		return .Running
	}
	effects := plan_action_effects(d, a)
	plan_apply(effects, world[:])
	plan_apply(effects, p.expected)
	write_effects(t, d, effects, world[:])
	run.step += 1
	if run.step >= run.length {
		return .Done
	}
	run.depends = plan_depends(d, p, goal)
	next := d.actions[p.steps[run.step]]
	if !as_expected(world[:], p.expected, run.depends) || !condition_holds(t, shared[next.node].condition) ||
	   !plan_tests_hold(plan_action_tests(d, next), world[:]) {
		return .Replan
	}
	start_step(t, next)
	return .Running
}

// as_expected is whether the keys of a set have the values that a plan expects.
@(private = "file")
as_expected :: proc "contextless" (world, expected: []i32, keys: u32) -> bool {
	for k in 0 ..< len(expected) {
		if keys & (1 << u32(k)) != 0 && world[k] != expected[k] {
			return false
		}
	}
	return true
}

// start_step makes an action's writes and starts its action.
@(private = "file")
start_step :: proc(t: ^Think_Context, a: format.Plan_Action) {
	node := format.decision_nodes(t.decision.data, t.decision.blob)[a.node]
	node_writes(t, node)
	start_action(t, node.action)
}

// write_effects asks to write the keys of effects with their values in a world state, in the effects' order.
@(private = "file")
write_effects :: proc(t: ^Think_Context, d: Plan_Domain, effects: []format.Plan_Effect, world: []i32) {
	board_keys := format.blackboard_keys(t.board.data, t.board.blob)
	for e in effects {
		slot := d.keys[e.key]
		key := board_keys[slot]
		c := Command {
			entity = t.entity,
			agent  = t.agent,
			kind   = .Write,
			key    = slot,
			type   = key.type,
		}
		#partial switch key.type {
		case .Bool:
			c.value[0] = 1 if world[e.key] != 0 else 0
		case .Int:
			(^i32)(&c.value)^ = world[e.key]
		case .Enum:
			(^u32)(&c.value)^ = u32(world[e.key])
		}
		append(t.out, c)
	}
}

package asset_format

import "core:mem"

import "cinnabar:core/layout"

// GOAP is the technique data of a decision whose technique is Goap (see docs/content/kinds/decisions.md#goap): a
// Goap_Header, then the planning keys' slots, the actions, the goals, the tests, the effects, and the goals'
// considerations, links and points, which are utility's records. The agent's module state, which goap_state lays out
// from the header's counts, holds the agent's phase, the plan runner's state, each goal's last priority, the goals that
// failed and the world state that they failed in, the plan's steps and expected world state, and the search: its world
// state, the actions that it may use and their costs, and its nodes.

// A decision has at most this many goals, so a set of them is a u32, and at most this many actions.
MAX_GOAP_GOALS :: 32
MAX_GOAP_ACTIONS :: 256
// A search has at most this many nodes, so a node's parent is a u16.
MAX_GOAP_NODES :: 1024

// Goap_Phase is where an agent's GOAP is: without a plan, searching for one, or running one.
Goap_Phase :: enum u32 {
	Idle,
	Searching,
	Running,
}

// Goap_Agent is at the start of the agent's module state: its phase; the goal that it searches or runs a plan for, plus
// 1, so a zero state has none; the node count of its last search that ended; and the goals that failed, by index.
Goap_Agent :: struct {
	phase:  Goap_Phase,
	goal:   u32,
	nodes:  u32,
	failed: u32,
}
#assert(size_of(Goap_Agent) == 16)

// Goap_Search is the start of a search's state: its node count, and the least cost of an effect, by which the
// heuristic counts the keys that are not yet satisfied.
Goap_Search :: struct {
	node_count: u32,
	min_unit:   f32,
}
#assert(size_of(Goap_Search) == 8)

// Goap_Node is a node of a search, followed by a Plan_Interval for each planning key: the state that the search
// regressed to. g is the cost from the goal, and f is g and the heuristic. parent is the node that it regressed from,
// and action the action that it regressed through. The root has neither.
Goap_Node :: struct {
	g:       f32,
	f:       f32,
	parent:  u16,
	action:  u16,
	depth:   u8,
	open:    u8,
	padding: u16,
}
#assert(size_of(Goap_Node) == 16)

// Goap_Goal is a goal: its decision node, whose guard is the goal's, its priority, which its considerations multiply, a
// range of the links, and its desired state, a range of the tests.
Goap_Goal :: struct {
	node:       u32,
	priority:   f32,
	first_link: u32,
	link_count: u32,
	first_test: u32,
	test_count: u32,
}
#assert(size_of(Goap_Goal) == 24)

// Goap_Header starts the data. layout is goap_layout's, so data of another build is refused.
Goap_Header :: struct {
	layout:              u64,
	key_count:           u32,
	action_count:        u32,
	goal_count:          u32,
	test_count:          u32,
	effect_count:        u32,
	consideration_count: u32,
	link_count:          u32,
	point_count:         u32,
	// The most nodes that a search holds, and the most actions that a plan holds.
	max_nodes:           u32,
	max_plan:            u32,
}
#assert(size_of(Goap_Header) == 48)

goap_layout :: proc() -> u64 {
	h := layout.hash(Goap_Header)
	h ~= layout.hash(Goap_Goal) * 31
	h ~= layout.hash(Plan_Action) * 961
	h ~= layout.hash(Plan_Test) * 29791
	h ~= layout.hash(Plan_Effect) * 923521
	h ~= layout.hash(Goap_Node) * 28629151
	h ~= layout.hash(Goap_Agent) * 887503681
	h ~= layout.hash(Plan_Run) * 27512614111
	h ~= layout.hash(Utility_Consideration) * 852891037441
	return h
}

// Goap_State is where each part of an agent's module state is, as offsets, and its size.
Goap_State :: struct {
	// [goal_count]f32, each goal's priority in the last think.
	priorities: u64,
	// [key_count]i32, the world state that the goals in Goap_Agent.failed failed in.
	failed_at:  u64,
	// [max_plan]u16, the plan's actions, by index.
	steps:      u64,
	// [key_count]i32, the world state that the plan expects now.
	expected:   u64,
	// Goap_Search, then [key_count]i32, the search's world state; the actions that it may use, a bit each; their costs,
	// [action_count]f32; and [max_nodes] nodes of node_size bytes.
	search:     u64,
	world:      u64,
	usable:     u64,
	costs:      u64,
	nodes:      u64,
	node_size:  u64,
	size:       u64,
}

// The offset of the Plan_Run, after the Goap_Agent.
GOAP_RUN :: size_of(Goap_Agent)

// goap_state lays out the module state of a decision of these counts. The cook sizes the state with it, and the module
// finds its parts with it.
goap_state :: proc "contextless" (key_count, action_count, goal_count, max_nodes, max_plan: u32) -> (s: Goap_State) {
	k, a := u64(key_count), u64(action_count)
	at := u64(GOAP_RUN + size_of(Plan_Run))
	s.priorities = at
	at += u64(goal_count) * 4
	s.failed_at = at
	at += k * 4
	s.steps = at
	at += (u64(max_plan) * 2 + 3) &~ 3
	s.expected = at
	at += k * 4
	s.search = at
	at += size_of(Goap_Search)
	s.world = at
	at += k * 4
	s.usable = at
	at += (a + 31) / 32 * 4
	s.costs = at
	at += a * 4
	s.nodes = at
	s.node_size = size_of(Goap_Node) + k * size_of(Plan_Interval)
	at += u64(max_nodes) * s.node_size
	s.size = (at + 7) &~ 7
	return
}

// Goap_Data is a view of the data, without checks: goap_view checks it once, when the decision loads.
Goap_Data :: struct {
	header:         ^Goap_Header,
	// The planning keys' slots.
	keys:           []u32,
	actions:        []Plan_Action,
	goals:          []Goap_Goal,
	tests:          []Plan_Test,
	effects:        []Plan_Effect,
	considerations: []Utility_Consideration,
	links:          []u32,
	points:         []Utility_Point,
}

@(private = "file")
goap_size :: proc "contextless" (h: ^Goap_Header) -> u64 {
	return size_of(Goap_Header) + u64(h.key_count) * 4 + u64(h.action_count) * size_of(Plan_Action) + u64(h.goal_count) * size_of(Goap_Goal) +
		u64(h.test_count) * size_of(Plan_Test) + u64(h.effect_count) * size_of(Plan_Effect) +
		u64(h.consideration_count) * size_of(Utility_Consideration) + u64(h.link_count) * 4 + u64(h.point_count) * size_of(Utility_Point)
}

// goap_data is a view of the data, which it does not check, besides its size.
goap_data :: proc "contextless" (data: []byte) -> (g: Goap_Data) {
	if len(data) < size_of(Goap_Header) {
		return
	}
	h := (^Goap_Header)(raw_data(data))
	if u64(len(data)) < goap_size(h) {
		return
	}
	at := size_of(Goap_Header)
	take :: proc "contextless" (data: []byte, at: ^int, $T: typeid, count: u32) -> []T {
		s := ([^]T)(raw_data(data[at^:]))[:count]
		at^ += int(count) * size_of(T)
		return s
	}
	g.header = h
	g.keys = take(data, &at, u32, h.key_count)
	g.actions = take(data, &at, Plan_Action, h.action_count)
	g.goals = take(data, &at, Goap_Goal, h.goal_count)
	g.tests = take(data, &at, Plan_Test, h.test_count)
	g.effects = take(data, &at, Plan_Effect, h.effect_count)
	g.considerations = take(data, &at, Utility_Consideration, h.consideration_count)
	g.links = take(data, &at, u32, h.link_count)
	g.points = take(data, &at, Utility_Point, h.point_count)
	return
}

// goap_state_of is the layout of the data's module state.
goap_state_of :: proc "contextless" (g: Goap_Data) -> Goap_State {
	h := g.header
	return goap_state(h.key_count, h.action_count, h.goal_count, h.max_nodes, h.max_plan)
}

// goap_view checks the data against its decision: its layout and size, its counts and limits, that the module state
// holds its layout, that each action's node has an action and a cost above 0, that each goal has a desired state and a
// priority of 0 or more, that every range and index is in range, and its considerations as utility's are checked. It
// does not check keys: goap_check does, with the blackboard.
goap_view :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob) -> (g: Goap_Data, ok: bool) {
	if len(data) < size_of(Goap_Header) || uintptr(raw_data(data)) % align_of(Goap_Header) != 0 {
		return
	}
	h := (^Goap_Header)(raw_data(data))
	if h.layout != goap_layout() || u64(len(data)) != goap_size(h) {
		return
	}
	if h.key_count == 0 || h.key_count > MAX_PLAN_KEYS || h.action_count == 0 || h.action_count > MAX_GOAP_ACTIONS || h.goal_count == 0 ||
	   h.goal_count > MAX_GOAP_GOALS || h.max_nodes == 0 || h.max_nodes > MAX_GOAP_NODES || h.max_plan == 0 || h.max_plan > MAX_PLAN_LENGTH {
		return
	}
	g = goap_data(data)
	if goap_state_of(g).size > u64(decision.state_size) {
		return {}, false
	}
	nodes := decision_nodes(decision_data, decision)
	range :: proc "contextless" (first, count: u32, length: int) -> bool {
		return u64(first) + u64(count) <= u64(length)
	}
	if !plan_tests_ok(g.tests, h.key_count) || !plan_effects_ok(g.effects, h.key_count) {
		return {}, false
	}
	for a in g.actions {
		if int(a.node) >= len(nodes) || nodes[a.node].action == DECISION_NONE || a.cost.source > max(Plan_Number_Source) {
			return {}, false
		}
		if a.cost.source == .Constant && !(a.cost.value > 0 && a.cost.value - a.cost.value == 0) {
			return {}, false
		}
		if !range(a.first_test, a.test_count, len(g.tests)) || !range(a.first_effect, a.effect_count, len(g.effects)) || a.effect_count == 0 {
			return {}, false
		}
	}
	for goal in g.goals {
		if int(goal.node) >= len(nodes) || !(goal.priority >= 0 && goal.priority - goal.priority == 0) || goal.test_count == 0 {
			return {}, false
		}
		if !range(goal.first_test, goal.test_count, len(g.tests)) || !range(goal.first_link, goal.link_count, len(g.links)) {
			return {}, false
		}
	}
	for l in g.links {
		if int(l) >= len(g.considerations) {
			return {}, false
		}
	}
	for c in g.considerations {
		if !utility_consideration_ok(c, g.points, len(nodes)) {
			return {}, false
		}
	}
	return g, true
}

// goap_check checks the data against its decision and the decision's blackboard: goap_view's checks, that the planning
// keys are distinct bool, int and enum keys and each effect fits its key, that cost keys are floats or ints, and that
// the considerations' keys are of the types that they read.
goap_check :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob, board_data: []byte, board: ^Blackboard_Blob) -> bool {
	g, ok := goap_view(data, decision_data, decision)
	if !ok {
		return false
	}
	keys := blackboard_keys(board_data, board)
	if !plan_keys_ok(g.keys, g.effects, keys) {
		return false
	}
	for a in g.actions {
		if a.cost.source == .Key && (int(a.cost.key) >= len(keys) || keys[a.cost.key].type not_in (bit_set[Blackboard_Type]{.Float, .Int})) {
			return false
		}
	}
	for c in g.considerations {
		if !utility_consideration_keys_ok(keys, c) {
			return false
		}
	}
	return true
}

// Goap_Contents is the data as goap_write takes it.
Goap_Contents :: struct {
	max_nodes:      u32,
	max_plan:       u32,
	keys:           []u32,
	actions:        []Plan_Action,
	goals:          []Goap_Goal,
	tests:          []Plan_Test,
	effects:        []Plan_Effect,
	considerations: []Utility_Consideration,
	links:          []u32,
	points:         []Utility_Point,
}

// goap_write builds the data.
goap_write :: proc(c: Goap_Contents, allocator := context.allocator) -> []byte {
	header := Goap_Header {
		layout              = goap_layout(),
		key_count           = u32(len(c.keys)),
		action_count        = u32(len(c.actions)),
		goal_count          = u32(len(c.goals)),
		test_count          = u32(len(c.tests)),
		effect_count        = u32(len(c.effects)),
		consideration_count = u32(len(c.considerations)),
		link_count          = u32(len(c.links)),
		point_count         = u32(len(c.points)),
		max_nodes           = c.max_nodes,
		max_plan            = c.max_plan,
	}
	data := make([]byte, int(goap_size(&header)), allocator)
	at := 0
	put :: proc(data: []byte, at: ^int, from: rawptr, size: int) {
		if size > 0 {
			mem.copy(&data[at^], from, size)
		}
		at^ += size
	}
	put(data, &at, &header, size_of(header))
	put(data, &at, raw_data(c.keys), len(c.keys) * 4)
	put(data, &at, raw_data(c.actions), len(c.actions) * size_of(Plan_Action))
	put(data, &at, raw_data(c.goals), len(c.goals) * size_of(Goap_Goal))
	put(data, &at, raw_data(c.tests), len(c.tests) * size_of(Plan_Test))
	put(data, &at, raw_data(c.effects), len(c.effects) * size_of(Plan_Effect))
	put(data, &at, raw_data(c.considerations), len(c.considerations) * size_of(Utility_Consideration))
	put(data, &at, raw_data(c.links), len(c.links) * 4)
	put(data, &at, raw_data(c.points), len(c.points) * size_of(Utility_Point))
	return data
}

package search

import format "cinnabar:engine/asset/format"

// The search (see docs/ai/goap.md#the-search): a regressive A* from a goal's desired state to the world state that the
// search began in. A node is a state that the search regressed to, an interval of values for each planning key, and an
// action leads from a node to the state before it: the action's effects must not contradict the node, at least one must
// touch a key that the node constrains, and the state before it takes the action's preconditions. A node that the
// world state satisfies ends the search, and the actions on the way back to the goal are the plan, in their order. The
// search is in the agent's module state, so it goes on over thinks, and it reads only the technique's data, so a tool
// can plan as the runtime does: whole runs a search to its end in one call, as the cook daemon's plan preview does.

// The least cost of an action: a cost key below it counts as it, so every action costs something and a search ends.
MIN_COST :: 0.001

// The parent and the action of the root, which has neither.
@(private)
NO_NODE :: max(u16)

// FREE is the interval of a key that a state does not constrain.
@(private)
FREE :: format.Plan_Interval{min(i32), max(i32)}

// Search is a view of a search's state in the agent's module state.
Search :: struct {
	header:    ^format.Goap_Search,
	// The world state that the search began in, by planning key.
	world:     []i32,
	// The actions that the search may use, a bit each by index, and their costs.
	usable:    []u32,
	costs:     []f32,
	nodes:     []byte,
	node_size: int,
	max_plan:  int,
}

Result :: enum u8 {
	Searching,
	Found,
	Failed,
}

// of is the search in an agent's module state.
of :: proc(g: format.Goap_Data, layout: format.Goap_State, state: []byte) -> Search {
	k, a := int(g.header.key_count), int(g.header.action_count)
	return {
		header = (^format.Goap_Search)(&state[layout.search]),
		world = ([^]i32)(&state[layout.world])[:k],
		usable = ([^]u32)(&state[layout.usable])[:(a + 31) / 32],
		costs = ([^]f32)(&state[layout.costs])[:a],
		nodes = state[layout.nodes:][:int(g.header.max_nodes) * int(layout.node_size)],
		node_size = int(layout.node_size),
		max_plan = int(g.header.max_plan),
	}
}

// node_at is a node of the search and its intervals.
@(private)
node_at :: proc(s: ^Search, index: int) -> (^format.Goap_Node, []format.Plan_Interval) {
	at := index * s.node_size
	node := (^format.Goap_Node)(&s.nodes[at])
	intervals := ([^]format.Plan_Interval)(&s.nodes[at + size_of(format.Goap_Node)])[:len(s.world)]
	return node, intervals
}

// is_usable is whether the search may use the action at an index.
@(private)
is_usable :: proc(s: ^Search, action: int) -> bool {
	return s.usable[action / 32] & (1 << u32(action % 32)) != 0
}

// begin begins a search for a goal, from the world state, the usable actions and their costs that the search
// holds already. The heuristic's unit is the least cost of an effect among the usable actions: no plan can satisfy a key
// for less, so the heuristic never overestimates, and the plan found is the cheapest.
begin :: proc(s: ^Search, g: format.Goap_Data, goal: format.Goap_Goal) {
	s.header^ = {}
	unit := max(f32)
	for a, i in g.actions {
		if is_usable(s, i) {
			unit = min(unit, s.costs[i] / f32(a.effect_count))
		}
	}
	s.header.min_unit = unit if unit < max(f32) else 0
	root, intervals := node_at(s, 0)
	for &iv in intervals {
		iv = FREE
	}
	// The cook makes one test of each key, and the check keeps tests from being empty, so the desired state is not.
	for test in g.tests[goal.first_test:][:goal.test_count] {
		intervals[test.key] = {max(intervals[test.key].lo, test.lo), min(intervals[test.key].hi, test.hi)}
	}
	root^ = {
		parent = NO_NODE,
		action = NO_NODE,
		open   = 1,
	}
	root.f = heuristic(s, intervals)
	s.header.node_count = 1
}

// step expands at most budget nodes of a search. A search is found when a node that it takes from the open
// nodes is satisfied by its world state, and it fails when no node is open, or when a node does not fit in its state.
// It takes the open node of the lowest f, and the first made of equal ones. Its children are made in the actions'
// order, so the actions' order breaks ties, and a search gives the same plan on every run.
step :: proc(s: ^Search, g: format.Goap_Data, budget: int) -> (result: Result, found: int) {
	children: [format.MAX_PLAN_KEYS]format.Plan_Interval
	for _ in 0 ..< budget {
		best := -1
		best_f: f32
		for i in 0 ..< int(s.header.node_count) {
			node, _ := node_at(s, i)
			if node.open != 0 && (best < 0 || node.f < best_f) {
				best, best_f = i, node.f
			}
		}
		if best < 0 {
			return .Failed, -1
		}
		node, intervals := node_at(s, best)
		node.open = 0
		if satisfied(s.world, intervals) {
			return .Found, best
		}
		if int(node.depth) >= s.max_plan {
			continue
		}
		for a, i in g.actions {
			if !is_usable(s, i) {
				continue
			}
			child := children[:len(intervals)]
			if !regress(g, a, intervals, child) {
				continue
			}
			cost := node.g + s.costs[i]
			if twin := find(s, child); twin >= 0 {
				other, _ := node_at(s, twin)
				if other.g <= cost {
					continue
				}
				other^ = {
					g      = cost,
					f      = cost + heuristic(s, child),
					parent = u16(best),
					action = u16(i),
					depth  = node.depth + 1,
					open   = 1,
				}
				continue
			}
			count := int(s.header.node_count)
			if count * s.node_size >= len(s.nodes) {
				return .Failed, -1
			}
			made, made_intervals := node_at(s, count)
			made^ = {
				g      = cost,
				f      = cost + heuristic(s, child),
				parent = u16(best),
				action = u16(i),
				depth  = node.depth + 1,
				open   = 1,
			}
			copy(made_intervals, child)
			s.header.node_count += 1
		}
	}
	return .Searching, -1
}

// plan writes the plan of a found node into steps: the actions on the way from it back to the goal, which is
// the order that they run in. It gives the plan's length.
plan :: proc(s: ^Search, found: int, steps: []u16) -> u32 {
	length: u32
	node, _ := node_at(s, found)
	for node.parent != NO_NODE {
		steps[length] = node.action
		length += 1
		node, _ = node_at(s, int(node.parent))
	}
	return length
}

// regress is the state before an action that leads to a state, into before. It is false when the action does not lead
// to the state: when an effect contradicts it, when no effect touches a key that it constrains, or when the action's
// preconditions contradict the state before. Effects are regressed from the last, since they apply in their order.
@(private)
regress :: proc(g: format.Goap_Data, a: format.Plan_Action, after, before: []format.Plan_Interval) -> bool {
	copy(before, after)
	relevant := false
	effects := g.effects[a.first_effect:][:a.effect_count]
	#reverse for e in effects {
		iv := before[e.key]
		constrained := iv != FREE
		switch e.op {
		case .Set:
			if constrained {
				if e.value < iv.lo || e.value > iv.hi {
					return false
				}
				relevant = true
			}
			before[e.key] = FREE
		case .Add:
			if constrained {
				relevant = true
				before[e.key] = {shift(iv.lo, e.value), shift(iv.hi, e.value)}
			}
		}
	}
	if !relevant {
		return false
	}
	for test in g.tests[a.first_test:][:a.test_count] {
		iv := &before[test.key]
		iv^ = {max(iv.lo, test.lo), min(iv.hi, test.hi)}
		if iv.lo > iv.hi {
			return false
		}
	}
	return true
}

// shift is an end of an interval before an add of a value. An open end stays open, and a closed one saturates.
@(private)
shift :: proc(end: i32, value: i32) -> i32 {
	if end == min(i32) || end == max(i32) {
		return end
	}
	return i32(clamp(i64(end) - i64(value), i64(min(i32)) + 1, i64(max(i32)) - 1))
}

// satisfied is whether a world state is inside a state's intervals.
@(private)
satisfied :: proc(world: []i32, intervals: []format.Plan_Interval) -> bool {
	for iv, k in intervals {
		if world[k] < iv.lo || world[k] > iv.hi {
			return false
		}
	}
	return true
}

// heuristic is the keys that the world state does not satisfy times the least cost of an effect.
@(private)
heuristic :: proc(s: ^Search, intervals: []format.Plan_Interval) -> f32 {
	unsatisfied := 0
	for iv, k in intervals {
		if s.world[k] < iv.lo || s.world[k] > iv.hi {
			unsatisfied += 1
		}
	}
	return f32(unsatisfied) * s.header.min_unit
}

// find is the node of the same state, or -1.
@(private)
find :: proc(s: ^Search, intervals: []format.Plan_Interval) -> int {
	outer: for i in 0 ..< int(s.header.node_count) {
		_, other := node_at(s, i)
		for iv, k in intervals {
			if other[k] != iv {
				continue outer
			}
		}
		return i
	}
	return -1
}

// Outcome is how a whole search ended: with a plan that reaches the goal from the world state, or, when it failed, with
// the plan of its closest node.
Outcome :: enum u8 {
	Found,
	Closest,
}

// Whole is a whole search's result. Its plan is in the steps that whole was given.
Whole :: struct {
	outcome: Outcome,
	// The plan's length in steps.
	length:  u32,
	// The nodes that the search made.
	nodes:   u32,
	// The planning keys, by index, that the plan's first state needs and the world state does not have. A found plan
	// has none.
	unmet:   bit_set[0 ..< format.MAX_PLAN_KEYS;u32],
}

// whole runs a search for a goal to its end, from a world state, the usable actions, a bit each by index, and their
// costs, in a state of goap_state_of(g).size bytes, and writes its plan into steps, which hold max_plan. The search is
// the runtime's, so it finds the plan that an agent finds from the same world state, usable actions and costs. When it
// fails, its plan is that of its closest node (see closest).
whole :: proc(g: format.Goap_Data, state: []byte, world: []i32, usable: []u32, costs: []f32, goal: format.Goap_Goal, steps: []u16) -> (w: Whole) {
	s := of(g, format.goap_state_of(g), state)
	copy(s.world, world)
	copy(s.usable, usable)
	copy(s.costs, costs)
	begin(&s, g, goal)
	result, found := step(&s, g, max(int))
	w.nodes = s.header.node_count
	if result != .Found {
		w.outcome = .Closest
		found = closest(&s)
		_, intervals := node_at(&s, found)
		for iv, k in intervals {
			if s.world[k] < iv.lo || s.world[k] > iv.hi {
				w.unmet += {k}
			}
		}
	}
	w.length = plan(&s, found, steps)
	return
}

// closest is the node of a search that the world state is closest to: the fewest keys that the world state does not
// satisfy, then a node other than the root, which is the goal itself and has no plan, then the lowest cost from the
// goal, and the first made of equal ones. A deeper node is not closer for its depth: an action whose effect only adds to
// a key regresses again and again, each time costing more. The root is a node, so there is one.
closest :: proc(s: ^Search) -> int {
	best, best_unsatisfied := 0, max(int)
	best_g: f32
	for i in 0 ..< int(s.header.node_count) {
		node, intervals := node_at(s, i)
		unsatisfied := 0
		for iv, k in intervals {
			if s.world[k] < iv.lo || s.world[k] > iv.hi {
				unsatisfied += 1
			}
		}
		better := unsatisfied < best_unsatisfied
		if unsatisfied == best_unsatisfied {
			better = best == 0 || (i != 0 && node.g < best_g)
		}
		if better {
			best, best_unsatisfied, best_g = i, unsatisfied, node.g
		}
	}
	return best
}

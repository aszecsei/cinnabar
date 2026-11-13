package cook

import "core:math"

import "cinnabar:engine/ai/goap/search"
import cook_link "cinnabar:engine/asset/cook_link"
import format "cinnabar:engine/asset/format"

// plan_preview plans a decision editor's plan query on a GOAP decision that checked out, with the runtime's search (see
// docs/editor/decision-editor.md#plan-preview). The world state is the query's, and the blackboard's defaults for the
// planning keys that it leaves out. The cook cannot evaluate a guard, which reads the agent's values and the world, so
// every action is usable. An action's cost is its constant, or its key's default, at least search.MIN_COST, as when an
// agent's search begins. A query on another technique, or of a goal or a key that the decision does not have, is a
// problem, and has no answer.
plan_preview :: proc(checked: Checked_Decision, query: cook_link.Plan_Query, path: string, problems: ^Problems) -> (answer: cook_link.Plan_Answer, ok: bool) {
	contents := checked.contents
	if contents.technique != .Goap {
		report_error(problems, path, 0, 0, "only a GOAP decision has a plan preview")
		return
	}
	g := format.goap_data(contents.technique_data)
	goal := -1
	for record, i in g.goals {
		if contents.nodes[record.node].id == query.goal {
			goal = i
		}
	}
	if goal < 0 {
		report_error(problems, path, 0, 0, "the plan preview's goal %d is not a goal of the decision", query.goal)
		return
	}
	world := make([]i32, len(g.keys), context.temp_allocator)
	for slot, k in g.keys {
		key := checked.keys[slot]
		#partial switch key.type {
		case .Bool:
			world[k] = 1 if key.default[0] != 0 else 0
		case .Int:
			world[k] = (^i32)(&key.default)^
		case .Enum:
			world[k] = i32((^u32)(&key.default)^)
		}
	}
	next: for v in query.state {
		for slot, k in g.keys {
			if checked.keys[slot].name == v.key {
				world[k] = v.value
				continue next
			}
		}
		report_error(problems, path, 0, 0, "the plan preview's key %q is not a planning key of the decision", v.key)
		return
	}
	usable := make([]u32, (len(g.actions) + 31) / 32, context.temp_allocator)
	costs := make([]f32, len(g.actions), context.temp_allocator)
	for a, i in g.actions {
		usable[i / 32] |= 1 << u32(i % 32)
		cost := f64(a.cost.value)
		if a.cost.source == .Key {
			key := checked.keys[a.cost.key]
			#partial switch key.type {
			case .Float:
				cost = f64((^f32)(&key.default)^)
			case .Int:
				cost = f64((^i32)(&key.default)^)
			}
		}
		if math.is_nan(cost) || math.is_inf(cost) {
			cost = 0
		}
		costs[i] = f32(max(cost, search.MIN_COST))
	}
	state := make([]byte, format.goap_state_of(g).size, context.temp_allocator)
	steps := make([]u16, g.header.max_plan, context.temp_allocator)
	whole := search.whole(g, state, world, usable, costs, g.goals[goal], steps)
	answer = {
		outcome = cook_link.Plan_Outcome(whole.outcome),
		steps   = make([]cook_link.Plan_Answer_Step, whole.length, context.temp_allocator),
		nodes   = whole.nodes,
	}
	for step, i in steps[:whole.length] {
		node := contents.nodes[g.actions[step].node]
		answer.steps[i] = {node.id, contents.actions[node.action].name}
	}
	unmet := make([dynamic]string, context.temp_allocator)
	for slot, k in g.keys {
		if k in whole.unmet {
			append(&unmet, checked.keys[slot].name)
		}
	}
	answer.unmet = unmet[:]
	return answer, true
}

#assert(int(cook_link.Plan_Outcome.Found) == int(search.Outcome.Found))
#assert(int(cook_link.Plan_Outcome.Closest) == int(search.Outcome.Closest))

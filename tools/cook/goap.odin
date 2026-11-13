package cook

import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The GOAP technique of the decision kind (see docs/content/kinds/decisions.md#goap). The header names the planning
// keys, the bool, int and enum keys that the planner's world state holds, and the search's size. Each `goal` node has a
// desired state over the planning keys and a priority, which `consideration` nodes may scale, as a utility option's
// score is scaled. Each `action` node has preconditions and effects on the planning keys and a cost. The reader turns
// each key's tests into one interval, checks the nodes, and sizes the agents' module state from the search's size.

GOAP_READER :: Technique_Reader {
	version = "goap 1",
	read    = read_goap,
}

// The defaults of the header's settings.
GOAP_DEFAULT_MAX_NODES :: 64
GOAP_DEFAULT_MAX_PLAN :: 8

@(private = "file")
GOAL_FIELDS :: []string{"when", "desired", "priority", "considerations", "position"}
@(private = "file")
ACTION_FIELDS :: []string{"action", "when", "preconditions", "effects", "cost", "position"}

@(private = "file")
Goap_Kind :: enum {
	Unknown,
	Goal,
	Action,
	Consideration,
}

@(private = "file")
Goap_Text_Node :: struct {
	kind:          Goap_Kind,
	goal:          format.Goap_Goal,
	action:        format.Plan_Action,
	tests:         []format.Plan_Test,
	effects:       []format.Plan_Effect,
	consideration: format.Utility_Consideration,
	points:        [dynamic]format.Utility_Point,
	// A goal's considerations, by their index in the text's nodes.
	children:      [dynamic]int,
	children_line: int,
	// Whether a goal lists the consideration, and its index among the considerations.
	listed:        bool,
	index:         int,
}

read_goap :: proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte) {
	problems := len(p.found)
	r := Plan_Reader {
		p         = p,
		planning  = make([dynamic]u32, context.temp_allocator),
		technique = "GOAP",
	}
	contents := format.Goap_Contents {
		max_nodes = GOAP_DEFAULT_MAX_NODES,
		max_plan  = GOAP_DEFAULT_MAX_PLAN,
	}
	keys_line, nodes_line := 0, 0
	for s in text.settings {
		switch s.key {
		case "keys":
			keys_line = s.line
			read_planning_keys(&r, s)
		case "max_nodes":
			nodes_line = s.line
			value, ok := strconv.parse_int(s.value)
			if !ok || value < 1 || value > format.MAX_GOAP_NODES {
				decision_problem(p, s.line, "max_nodes is a count from 1 to %d", format.MAX_GOAP_NODES)
			} else {
				contents.max_nodes = u32(value)
			}
		case "max_plan":
			value, ok := strconv.parse_int(s.value)
			if !ok || value < 1 || value > format.MAX_PLAN_LENGTH {
				decision_problem(p, s.line, "max_plan is a count from 1 to %d", format.MAX_PLAN_LENGTH)
			} else {
				contents.max_plan = u32(value)
			}
		case:
			decision_problem(p, s.line, "a GOAP decision has no setting %s: its settings are keys, max_nodes and max_plan", s.key)
		}
	}
	if keys_line == 0 {
		decision_problem(p, 1, "a GOAP decision names its planning keys: `keys = <key>, <key>, ...`")
	}
	nodes := make([]Goap_Text_Node, len(text.nodes), context.temp_allocator)
	by_id := make(map[int]int, len(text.nodes), context.temp_allocator)
	for n, i in text.nodes {
		by_id[n.id] = i
	}
	goals, actions := 0, 0
	for &n, i in text.nodes {
		read_goap_node(&r, &n, &nodes[i])
		goals += int(nodes[i].kind == .Goal)
		actions += int(nodes[i].kind == .Action)
	}
	if goals == 0 {
		decision_problem(p, 1, "a GOAP decision has goals: `node <id> goal`")
	}
	if actions == 0 {
		decision_problem(p, 1, "a GOAP decision has actions: `node <id> action`")
	}
	if goals > format.MAX_GOAP_GOALS {
		decision_problem(p, 1, "a GOAP decision has at most %d goals", format.MAX_GOAP_GOALS)
	}
	if actions > format.MAX_GOAP_ACTIONS {
		decision_problem(p, 1, "a GOAP decision has at most %d actions", format.MAX_GOAP_ACTIONS)
	}
	// Each goal's considerations.
	for &n in nodes {
		if n.kind != .Goal {
			continue
		}
		ids := slice.clone(n.children[:], context.temp_allocator)
		for id, at in ids {
			child, found := by_id[id]
			switch {
			case !found:
				decision_problem(p, n.children_line, "no node has the ID %d", id)
				child = -1
			case nodes[child].kind != .Consideration:
				decision_problem(p, n.children_line, "node %d is not a consideration", id)
				child = -1
			case:
				for other in ids[:at] {
					if other == id {
						decision_problem(p, n.children_line, "node %d is a consideration of this goal twice", id)
					}
				}
				nodes[child].listed = true
			}
			n.children[at] = child
		}
	}
	for n, i in nodes {
		if n.kind == .Consideration && !n.listed {
			decision_problem(p, text.nodes[i].line, "no goal lists the consideration %d", text.nodes[i].id)
		}
	}
	if len(p.found) > problems {
		return
	}
	// The records, in the text's order: the actions, the goals, the considerations, and each one's tests and effects.
	action_records := make([dynamic]format.Plan_Action, context.temp_allocator)
	goal_records := make([dynamic]format.Goap_Goal, context.temp_allocator)
	tests := make([dynamic]format.Plan_Test, context.temp_allocator)
	effects := make([dynamic]format.Plan_Effect, context.temp_allocator)
	considerations := make([dynamic]format.Utility_Consideration, context.temp_allocator)
	points := make([dynamic]format.Utility_Point, context.temp_allocator)
	links := make([dynamic]u32, context.temp_allocator)
	for &n in nodes {
		if n.kind != .Consideration {
			continue
		}
		n.index = len(considerations)
		c := n.consideration
		if c.curve == .Table {
			c.first_point = u32(len(points))
			c.point_count = u32(len(n.points))
			append(&points, ..n.points[:])
		}
		append(&considerations, c)
	}
	for n in nodes {
		switch n.kind {
		case .Action:
			a := n.action
			a.first_test, a.test_count = u32(len(tests)), u32(len(n.tests))
			a.first_effect, a.effect_count = u32(len(effects)), u32(len(n.effects))
			append(&tests, ..n.tests)
			append(&effects, ..n.effects)
			append(&action_records, a)
		case .Goal:
			g := n.goal
			g.first_test, g.test_count = u32(len(tests)), u32(len(n.tests))
			g.first_link, g.link_count = u32(len(links)), u32(len(n.children))
			append(&tests, ..n.tests)
			for child in n.children {
				append(&links, u32(nodes[child].index))
			}
			append(&goal_records, g)
		case .Consideration, .Unknown:
		}
	}
	contents.keys = r.planning[:]
	contents.actions = action_records[:]
	contents.goals = goal_records[:]
	contents.tests = tests[:]
	contents.effects = effects[:]
	contents.considerations = considerations[:]
	contents.links = links[:]
	contents.points = points[:]
	layout := format.goap_state(u32(len(r.planning)), u32(len(action_records)), u32(len(goal_records)), contents.max_nodes, contents.max_plan)
	if layout.size > format.MAX_DECISION_STATE {
		decision_problem(
			p,
			nodes_line if nodes_line != 0 else keys_line,
			"the state of a search of %d nodes over %d keys, and its plan, is %d bytes, more than %d: lower max_nodes, or plan over fewer keys",
			contents.max_nodes,
			len(r.planning),
			layout.size,
			format.MAX_DECISION_STATE,
		)
		return
	}
	return u32(layout.size), format.goap_write(contents)
}

// read_goap_node reads a node's kind and fields.
@(private = "file")
read_goap_node :: proc(r: ^Plan_Reader, text: ^Decision_Text_Node, n: ^Goap_Text_Node) {
	p := r.p
	n.children = make([dynamic]int, context.temp_allocator)
	switch text.kind {
	case "goal":
		n.kind = .Goal
		n.goal = {node = u32(text.index), priority = 1}
	case "action":
		n.kind = .Action
		n.action = {node = u32(text.index), cost = {value = 1}}
	case "consideration":
		n.kind = .Consideration
	case:
		decision_problem(p, text.line, "%s is not a node of a GOAP decision: a node is goal, action or consideration", text.kind)
		return
	}
	kind_fields := [Goap_Kind][]string {
		.Unknown       = nil,
		.Goal          = GOAL_FIELDS,
		.Action        = ACTION_FIELDS,
		.Consideration = CONSIDERATION_FIELDS,
	}
	articles := [Goap_Kind]string {
		.Unknown       = "",
		.Goal          = "a goal",
		.Action        = "an action",
		.Consideration = "a consideration",
	}
	if n.kind != .Action && text.set_line != 0 {
		decision_problem(p, text.set_line, "only an action writes keys, and this is %s", articles[n.kind])
	}
	if n.kind == .Action {
		for w in p.writes[text.first_write:][:text.write_count] {
			if slice.contains(r.planning[:], w.key) {
				decision_problem(p, text.set_line, "%s is a planning key, which an action changes by its effects and not by set", p.keys[w.key].name)
			}
		}
	}
	own_fields := make([dynamic]Decision_Field, context.temp_allocator)
	has := proc(text: ^Decision_Text_Node, key: string) -> bool {
		for f in text.fields {
			if f.key == key {
				return true
			}
		}
		return false
	}
	for f in text.fields {
		if !slice.contains(kind_fields[n.kind], f.key) {
			known := false
			for fields in kind_fields {
				known ||= slice.contains(fields, f.key)
			}
			if known {
				decision_problem(p, f.line, "%s has no %s", articles[n.kind], f.key)
			} else {
				decision_problem(p, f.line, "a GOAP decision's node has no field %s", f.key)
			}
			continue
		}
		switch n.kind {
		case .Goal:
			read_goal_field(r, n, f)
		case .Action:
			read_action_field(r, n, f)
		case .Consideration:
			append(&own_fields, f)
		case .Unknown:
		}
	}
	switch n.kind {
	case .Goal:
		if !has(text, "desired") {
			decision_problem(p, text.line, "a goal has a desired state: `desired = <test> and <test> ...`")
		}
	case .Action:
		if !has(text, "action") {
			decision_problem(p, text.line, "an action has an action")
		}
		if !has(text, "effects") {
			decision_problem(p, text.line, "an action has effects: `effects = <key> = <value>, <key> += <n>, ...`")
		}
	case .Consideration:
		n.consideration, n.points = read_consideration(p, text, own_fields[:])
	case .Unknown:
	}
}

@(private = "file")
read_goal_field :: proc(r: ^Plan_Reader, n: ^Goap_Text_Node, f: Decision_Field) {
	p := r.p
	switch f.key {
	case "desired":
		n.tests = read_plan_tests(r, f)
	case "priority":
		value, ok := strconv.parse_f32(f.value)
		if !ok || !(value >= 0) || value - value != 0 {
			decision_problem(p, f.line, "priority is a number of 0 or more")
			return
		}
		n.goal.priority = value
	case "considerations":
		n.children_line = f.line
		for part in strings.split(f.value, ",", context.temp_allocator) {
			id, ok := strconv.parse_int(strings.trim_space(part))
			if !ok {
				decision_problem(p, f.line, "considerations are node IDs: `considerations = <id>, <id>, ...`")
				clear(&n.children)
				return
			}
			append(&n.children, id)
		}
	case "when", "position":
	// The shared parts read when, and nothing reads position.
	}
}

@(private = "file")
read_action_field :: proc(r: ^Plan_Reader, n: ^Goap_Text_Node, f: Decision_Field) {
	p := r.p
	switch f.key {
	case "preconditions":
		n.tests = read_plan_tests(r, f)
	case "effects":
		n.effects = read_plan_effects(r, f)
	case "cost":
		if value, ok := strconv.parse_f32(f.value); ok {
			if !(value > 0) || value - value != 0 {
				decision_problem(p, f.line, "cost is a number above 0, or a float or int key")
				return
			}
			n.action.cost = {value = value}
			return
		}
		slot, type, found := plan_board_key(p, f.value)
		switch {
		case !is_identifier(f.value):
			decision_problem(p, f.line, "cost is a number above 0, or a float or int key")
		case !found:
			decision_problem(p, f.line, "the blackboard has no key named %s", f.value)
		case type != .Float && type != .Int:
			decision_problem(p, f.line, "%s is a %s, and cost is a float or an int key", f.value, type_name(type))
		case:
			n.action.cost = {key = u32(slot), source = .Key}
		}
	case "action", "when", "position":
	// The shared parts read action and when, and nothing reads position.
	}
}

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

// Goap_Reader is what the reader knows of the header: the planning keys' slots, by their index.
@(private = "file")
Goap_Reader :: struct {
	p:        ^Decision_Parser,
	planning: [dynamic]u32,
}

read_goap :: proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte) {
	problems := len(p.found)
	r := Goap_Reader {
		p        = p,
		planning = make([dynamic]u32, context.temp_allocator),
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

// read_planning_keys reads `keys = <key>, <key>, ...`: distinct bool, int and enum keys of the blackboard, at most
// MAX_PLAN_KEYS.
@(private = "file")
read_planning_keys :: proc(r: ^Goap_Reader, s: Decision_Field) {
	p := r.p
	for part in strings.split(s.value, ",", context.temp_allocator) {
		name := strings.trim_space(part)
		slot, type, found := goap_key(p, name)
		switch {
		case !is_identifier(name):
			decision_problem(p, s.line, "keys are the blackboard's keys: `keys = <key>, <key>, ...`")
			return
		case !found:
			decision_problem(p, s.line, "the blackboard has no key named %s", name)
		case type != .Bool && type != .Int && type != .Enum:
			decision_problem(p, s.line, "%s is a %s, and a planning key is a bool, an int or an enum", name, type_name(type))
		case slice.contains(r.planning[:], u32(slot)):
			decision_problem(p, s.line, "%s is a planning key twice", name)
		case len(r.planning) == format.MAX_PLAN_KEYS:
			decision_problem(p, s.line, "a GOAP decision plans over at most %d keys", format.MAX_PLAN_KEYS)
			return
		case:
			append(&r.planning, u32(slot))
		}
	}
}

// read_goap_node reads a node's kind and fields.
@(private = "file")
read_goap_node :: proc(r: ^Goap_Reader, text: ^Decision_Text_Node, n: ^Goap_Text_Node) {
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
read_goal_field :: proc(r: ^Goap_Reader, n: ^Goap_Text_Node, f: Decision_Field) {
	p := r.p
	switch f.key {
	case "desired":
		n.tests = read_tests(r, f)
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
read_action_field :: proc(r: ^Goap_Reader, n: ^Goap_Text_Node, f: Decision_Field) {
	p := r.p
	switch f.key {
	case "preconditions":
		n.tests = read_tests(r, f)
	case "effects":
		n.effects = read_effects(r, f)
	case "cost":
		if value, ok := strconv.parse_f32(f.value); ok {
			if !(value > 0) || value - value != 0 {
				decision_problem(p, f.line, "cost is a number above 0, or a float or int key")
				return
			}
			n.action.cost = {value = value}
			return
		}
		slot, type, found := goap_key(p, f.value)
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

// read_tests reads tests joined by `and`, each `<key>`, `not <key>` or `<key> <op> <value>` of a planning key, into one
// interval for each key that they test, in the order that each key first appears. The operators are ==, <, <=, > and
// >= on an int, == on an enum, and == and != on a bool.
@(private = "file")
read_tests :: proc(r: ^Goap_Reader, f: Decision_Field) -> []format.Plan_Test {
	p := r.p
	tests := make([dynamic]format.Plan_Test, context.temp_allocator)
	for raw in strings.split(f.value, " and ", context.temp_allocator) {
		term := strings.trim_space(raw)
		lo, hi := i32(min(i32)), i32(max(i32))
		name := term
		negated := false
		if strings.has_prefix(term, "not ") || strings.has_prefix(term, "!") {
			negated = true
			name = strings.trim_space(term[4:] if term[0] == 'n' else term[1:])
		}
		op, value := "", ""
		if !negated {
			for candidate in ([]string{"<=", ">=", "==", "!=", "<", ">"}) {
				if at := strings.index(term, candidate); at >= 0 {
					op = candidate
					name = strings.trim_space(term[:at])
					value = strings.trim_space(term[at + len(candidate):])
					break
				}
			}
		}
		index, key, ok := planning_key(r, name, f.line)
		if !ok {
			continue
		}
		switch {
		case op == "" && key.type != .Bool:
			decision_problem(p, f.line, "%s is a %s, so a test of it compares it: `%s <op> <value>`", name, type_name(key.type), name)
			continue
		case op == "":
			lo = 0 if negated else 1
			hi = lo
		case:
			v, value_ok := plan_value(p, key, value, f.line)
			if !value_ok {
				continue
			}
			ordered := op == "<" || op == "<=" || op == ">" || op == ">="
			if (op == "!=" && key.type != .Bool) || (ordered && key.type != .Int) {
				allowed := "=="
				#partial switch key.type {
				case .Int:
					allowed = "==, <, <=, > and >="
				case .Bool:
					allowed = "== and !="
				}
				decision_problem(p, f.line, "%s is a %s, which a test compares with %s", name, type_name(key.type), allowed)
				continue
			}
			if (op == "<" && v == min(i32)) || (op == ">" && v == max(i32)) {
				decision_problem(p, f.line, "%s %s %d can never hold", name, op, v)
				continue
			}
			switch op {
			case "==":
				lo, hi = v, v
			case "!=":
				lo, hi = 1 - v, 1 - v
			case "<":
				hi = v - 1
			case "<=":
				hi = v
			case ">":
				lo = v + 1
			case ">=":
				lo = v
			}
		}
		merged := false
		for &t in tests {
			if t.key == index {
				t.lo, t.hi = max(t.lo, lo), min(t.hi, hi)
				if t.lo > t.hi {
					decision_problem(p, f.line, "the tests of %s can never hold together", name)
				}
				merged = true
			}
		}
		if !merged {
			append(&tests, format.Plan_Test{key = index, lo = lo, hi = hi})
		}
	}
	return tests[:]
}

// read_effects reads effects, each `<key> = <value>`, which sets a planning key, or `<key> += <n>` or `<key> -= <n>`,
// which adds to an int planning key. An action changes a key once.
@(private = "file")
read_effects :: proc(r: ^Goap_Reader, f: Decision_Field) -> []format.Plan_Effect {
	p := r.p
	effects := make([dynamic]format.Plan_Effect, context.temp_allocator)
	for raw in strings.split(f.value, ",", context.temp_allocator) {
		term := strings.trim_space(raw)
		e: format.Plan_Effect
		name, value: string
		sign := i32(1)
		plus, minus, equals := strings.index(term, "+="), strings.index(term, "-="), strings.index_byte(term, '=')
		switch {
		case plus >= 0:
			e.op = .Add
			name, value = term[:plus], term[plus + 2:]
		case minus >= 0:
			e.op = .Add
			sign = -1
			name, value = term[:minus], term[minus + 2:]
		case equals >= 0:
			name, value = term[:equals], term[equals + 1:]
		case:
			decision_problem(p, f.line, "an effect is `<key> = <value>`, `<key> += <n>` or `<key> -= <n>`")
			continue
		}
		name, value = strings.trim_space(name), strings.trim_space(value)
		index, key, ok := planning_key(r, name, f.line)
		if !ok {
			continue
		}
		if e.op == .Add && key.type != .Int {
			decision_problem(p, f.line, "%s is a %s, and only an int is added to", name, type_name(key.type))
			continue
		}
		v, value_ok := plan_value(p, key, value, f.line)
		if !value_ok {
			continue
		}
		if e.op == .Add && sign < 0 {
			if v == min(i32) {
				decision_problem(p, f.line, "%s is not an int that can be taken away", value)
				continue
			}
			v = -v
		}
		e.key, e.value = index, v
		doubled := false
		for other in effects {
			doubled ||= other.key == index
		}
		if doubled {
			decision_problem(p, f.line, "the effects change %s twice", name)
			continue
		}
		append(&effects, e)
	}
	return effects[:]
}

// planning_key is the index among the planning keys of a key of a name, and the key.
@(private = "file")
planning_key :: proc(r: ^Goap_Reader, name: string, line: int) -> (index: u32, key: format.Blackboard_Key_Contents, ok: bool) {
	slot, _, found := goap_key(r.p, name)
	if !found {
		decision_problem(r.p, line, "the blackboard has no key named %s", name)
		return
	}
	for planning, i in r.planning {
		if planning == u32(slot) {
			return u32(i), r.p.keys[slot], true
		}
	}
	decision_problem(r.p, line, "%s is not a planning key: the header's keys name them", name)
	return
}

// plan_value is a value of a planning key in the planner's world state: true or false for a bool, as 1 or 0, an
// integer for an int, and one of its names for an enum, as its index.
@(private = "file")
plan_value :: proc(p: ^Decision_Parser, key: format.Blackboard_Key_Contents, value: string, line: int) -> (i32, bool) {
	#partial switch key.type {
	case .Bool:
		switch value {
		case "true":
			return 1, true
		case "false":
			return 0, true
		}
		decision_problem(p, line, "%s is a bool, which is true or false, not %s", key.name, value)
	case .Int:
		if v, ok := strconv.parse_i64(value); ok && v >= i64(min(i32)) && v <= i64(max(i32)) {
			return i32(v), true
		}
		decision_problem(p, line, "%s is an int, and %s is not one", key.name, value)
	case .Enum:
		for name, i in key.enum_names {
			if name == value {
				return i32(i), true
			}
		}
		decision_problem(p, line, "%s has no value %s: it is %s", key.name, value, strings.join(key.enum_names, ", ", context.temp_allocator))
	}
	return 0, false
}

// goap_key is the slot and type of the blackboard's key of a name.
@(private = "file")
goap_key :: proc(p: ^Decision_Parser, name: string) -> (slot: int, type: format.Blackboard_Type, found: bool) {
	for k, i in p.keys {
		if k.name == name {
			return i, k.type, true
		}
	}
	return -1, {}, false
}

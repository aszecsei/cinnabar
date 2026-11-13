package cook

import "core:slice"
import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The HTN technique of the decision kind (see docs/content/kinds/decisions.md#htn). The header names the planning keys,
// as GOAP's does, the root task and the plan's size. Each `task` node is a compound task with `methods` in order of
// preference. Each `method` node has preconditions on the planning keys and `subtasks`, tasks and actions in order. Each
// `action` node is a primitive task with preconditions and effects on the planning keys, as GOAP's actions have. The
// reader turns each key's tests into one interval, checks the nodes and that the root reaches each of them, lays out
// each task's methods together, and sizes the agents' module state from the counts.

HTN_READER :: Technique_Reader {
	version = "htn 1",
	read    = read_htn,
}

// The default of the header's max_plan.
HTN_DEFAULT_MAX_PLAN :: 8

@(private = "file")
TASK_FIELDS :: []string{"methods", "position"}
@(private = "file")
METHOD_FIELDS :: []string{"when", "preconditions", "subtasks", "position"}
@(private = "file")
HTN_ACTION_FIELDS :: []string{"action", "when", "preconditions", "effects", "position"}

@(private = "file")
Htn_Kind :: enum {
	Unknown,
	Task,
	Method,
	Action,
}

@(private = "file")
Htn_Text_Node :: struct {
	kind:          Htn_Kind,
	tests:         []format.Plan_Test,
	effects:       []format.Plan_Effect,
	// A task's methods, or a method's subtasks, by their index in the text's nodes, and the line that lists them.
	children:      [dynamic]int,
	children_line: int,
	// The task that lists a method, or -1.
	owner:         int,
	// Whether the root reaches the node, and its index among the records of its kind.
	reached:       bool,
	index:         int,
}

read_htn :: proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte) {
	problems := len(p.found)
	r := Plan_Reader {
		p         = p,
		planning  = make([dynamic]u32, context.temp_allocator),
		technique = "HTN",
	}
	contents := format.Htn_Contents {
		max_plan = HTN_DEFAULT_MAX_PLAN,
	}
	keys_line, root_line, root_id := 0, 0, 0
	root_parsed := false
	for s in text.settings {
		switch s.key {
		case "keys":
			keys_line = s.line
			read_planning_keys(&r, s)
		case "root":
			root_line = s.line
			if id, ok := strconv.parse_int(s.value); ok {
				root_id, root_parsed = id, true
			} else {
				decision_problem(p, s.line, "root is a task's node ID: `root = <id>`")
			}
		case "max_plan":
			value, ok := strconv.parse_int(s.value)
			if !ok || value < 1 || value > format.MAX_PLAN_LENGTH {
				decision_problem(p, s.line, "max_plan is a count from 1 to %d", format.MAX_PLAN_LENGTH)
			} else {
				contents.max_plan = u32(value)
			}
		case:
			decision_problem(p, s.line, "an HTN decision has no setting %s: its settings are keys, root and max_plan", s.key)
		}
	}
	if root_line == 0 {
		decision_problem(p, 1, "an HTN decision names its root task: `root = <id>`")
	}
	nodes := make([]Htn_Text_Node, len(text.nodes), context.temp_allocator)
	by_id := make(map[int]int, len(text.nodes), context.temp_allocator)
	for n, i in text.nodes {
		by_id[n.id] = i
	}
	counts: [Htn_Kind]int
	for &n, i in text.nodes {
		read_htn_node(&r, &n, &nodes[i])
		counts[nodes[i].kind] += 1
	}
	if counts[.Task] == 0 {
		decision_problem(p, 1, "an HTN decision has tasks: `node <id> task`")
	}
	if counts[.Action] == 0 {
		decision_problem(p, 1, "an HTN decision has actions: `node <id> action`")
	}
	if counts[.Task] > format.MAX_HTN_TASKS {
		decision_problem(p, 1, "an HTN decision has at most %d tasks", format.MAX_HTN_TASKS)
	}
	if counts[.Method] > format.MAX_HTN_METHODS {
		decision_problem(p, 1, "an HTN decision has at most %d methods", format.MAX_HTN_METHODS)
	}
	if counts[.Action] > format.MAX_HTN_ACTIONS {
		decision_problem(p, 1, "an HTN decision has at most %d actions", format.MAX_HTN_ACTIONS)
	}
	root := -1
	if root_parsed {
		found: bool
		root, found = by_id[root_id]
		switch {
		case !found:
			decision_problem(p, root_line, "no node has the ID %d", root_id)
			root = -1
		case nodes[root].kind != .Task:
			decision_problem(p, root_line, "node %d is not a task: the root is a task", root_id)
			root = -1
		}
	}
	// Each task's methods and each method's subtasks.
	for &n, i in nodes {
		if n.kind != .Task && n.kind != .Method {
			continue
		}
		ids := slice.clone(n.children[:], context.temp_allocator)
		for id, at in ids {
			child, found := by_id[id]
			switch {
			case !found:
				decision_problem(p, n.children_line, "no node has the ID %d", id)
				child = -1
			case n.kind == .Task && nodes[child].kind != .Method:
				decision_problem(p, n.children_line, "node %d is not a method", id)
				child = -1
			case n.kind == .Method && nodes[child].kind != .Task && nodes[child].kind != .Action:
				decision_problem(p, n.children_line, "node %d is not a task or an action", id)
				child = -1
			case n.kind == .Task && slice.contains(ids[:at], id):
				decision_problem(p, n.children_line, "node %d is a method of this task twice", id)
			case n.kind == .Task && nodes[child].owner >= 0:
				decision_problem(p, n.children_line, "node %d is a method of node %d too: a method has one task", id, text.nodes[nodes[child].owner].id)
			case n.kind == .Task:
				nodes[child].owner = i
			}
			n.children[at] = child
		}
	}
	for n, i in nodes {
		if n.kind == .Method && n.owner < 0 {
			decision_problem(p, text.nodes[i].line, "no task lists the method %d", text.nodes[i].id)
		}
	}
	if len(p.found) > problems {
		return
	}
	// The nodes that the root reaches. A task may be reached again, as a method's subtask, which makes a recursion.
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, root)
	nodes[root].reached = true
	for len(stack) > 0 {
		n := pop(&stack)
		for child in nodes[n].children {
			if !nodes[child].reached {
				nodes[child].reached = true
				append(&stack, child)
			}
		}
	}
	for n, i in nodes {
		if !n.reached && n.kind != .Unknown {
			decision_problem(p, text.nodes[i].line, "the root does not reach node %d", text.nodes[i].id)
		}
	}
	if len(p.found) > problems {
		return
	}
	// The records: the actions and the tasks in the text's order, and the methods by their tasks, each task's together
	// in the order that it lists them.
	actions := make([dynamic]format.Plan_Action, context.temp_allocator)
	tasks := make([dynamic]format.Htn_Task, context.temp_allocator)
	methods := make([dynamic]format.Htn_Method, context.temp_allocator)
	subtasks := make([dynamic]format.Htn_Subtask, context.temp_allocator)
	tests := make([dynamic]format.Plan_Test, context.temp_allocator)
	effects := make([dynamic]format.Plan_Effect, context.temp_allocator)
	for &n in nodes {
		switch n.kind {
		case .Action:
			n.index = len(actions)
			append(&actions, format.Plan_Action{})
		case .Task:
			n.index = len(tasks)
			append(&tasks, format.Htn_Task{})
		case .Method, .Unknown:
		}
	}
	for &n in nodes {
		if n.kind != .Task {
			continue
		}
		for child in n.children {
			nodes[child].index = len(methods)
			append(&methods, format.Htn_Method{})
		}
	}
	for n, i in nodes {
		node := u32(text.nodes[i].index)
		switch n.kind {
		case .Action:
			actions[n.index] = {
				node         = node,
				cost         = {value = 1},
				first_test   = u32(len(tests)),
				test_count   = u32(len(n.tests)),
				first_effect = u32(len(effects)),
				effect_count = u32(len(n.effects)),
			}
			append(&tests, ..n.tests)
			append(&effects, ..n.effects)
		case .Task:
			tasks[n.index] = {
				node         = node,
				first_method = u32(nodes[n.children[0]].index),
				method_count = u32(len(n.children)),
			}
		case .Method:
			methods[n.index] = {
				node          = node,
				first_test    = u32(len(tests)),
				test_count    = u32(len(n.tests)),
				first_subtask = u32(len(subtasks)),
				subtask_count = u32(len(n.children)),
			}
			append(&tests, ..n.tests)
			for child in n.children {
				kind := format.Htn_Subtask_Kind.Task if nodes[child].kind == .Task else .Action
				append(&subtasks, format.Htn_Subtask{kind = kind, index = u32(nodes[child].index)})
			}
		case .Unknown:
		}
	}
	contents.root = u32(nodes[root].index)
	contents.keys = r.planning[:]
	contents.actions = actions[:]
	contents.tasks = tasks[:]
	contents.methods = methods[:]
	contents.subtasks = subtasks[:]
	contents.tests = tests[:]
	contents.effects = effects[:]
	layout := format.htn_state(u32(len(r.planning)), u32(len(actions)), u32(len(methods)), contents.max_plan)
	if layout.size > format.MAX_DECISION_STATE {
		decision_problem(
			p,
			keys_line if keys_line != 0 else 1,
			"the state of a decomposition over %d keys, %d methods and %d actions, and its plan, is %d bytes, more than %d: plan over fewer keys, or use fewer methods or actions",
			len(r.planning),
			len(methods),
			len(actions),
			layout.size,
			format.MAX_DECISION_STATE,
		)
		return
	}
	return u32(layout.size), format.htn_write(contents)
}

// read_htn_node reads a node's kind and fields.
@(private = "file")
read_htn_node :: proc(r: ^Plan_Reader, text: ^Decision_Text_Node, n: ^Htn_Text_Node) {
	p := r.p
	n.children = make([dynamic]int, context.temp_allocator)
	n.owner = -1
	switch text.kind {
	case "task":
		n.kind = .Task
	case "method":
		n.kind = .Method
	case "action":
		n.kind = .Action
	case:
		decision_problem(p, text.line, "%s is not a node of an HTN decision: a node is task, method or action", text.kind)
		return
	}
	kind_fields := [Htn_Kind][]string {
		.Unknown = nil,
		.Task    = TASK_FIELDS,
		.Method  = METHOD_FIELDS,
		.Action  = HTN_ACTION_FIELDS,
	}
	articles := [Htn_Kind]string {
		.Unknown = "",
		.Task    = "a task",
		.Method  = "a method",
		.Action  = "an action",
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
				decision_problem(p, f.line, "an HTN decision's node has no field %s", f.key)
			}
			continue
		}
		switch f.key {
		case "methods", "subtasks":
			n.children_line = f.line
			for part in strings.split(f.value, ",", context.temp_allocator) {
				id, ok := strconv.parse_int(strings.trim_space(part))
				if !ok {
					decision_problem(p, f.line, "%s are node IDs: `%s = <id>, <id>, ...`", f.key, f.key)
					clear(&n.children)
					return
				}
				append(&n.children, id)
			}
		case "preconditions":
			n.tests = read_plan_tests(r, f)
		case "effects":
			n.effects = read_plan_effects(r, f)
		case "action", "when", "position":
		// The shared parts read action and when, and nothing reads position.
		}
	}
	switch n.kind {
	case .Task:
		if !has(text, "methods") {
			decision_problem(p, text.line, "a task has methods: `methods = <id>, <id>, ...`")
		}
	case .Method:
		if !has(text, "subtasks") {
			decision_problem(p, text.line, "a method has subtasks: `subtasks = <id>, <id>, ...`")
		}
	case .Action:
		if !has(text, "action") {
			decision_problem(p, text.line, "an action has an action")
		}
	case .Unknown:
	}
}

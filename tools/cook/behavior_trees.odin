package cook

import "core:strconv"
import "core:strings"

import format "cinnabar:engine/asset/format"

// The behavior tree technique of the decision kind (see docs/content/kinds/decisions.md#behavior-trees). Each node is a
// composite, `sequence`, `selector` or `parallel`, with its children by ID, or a leaf, `action`, `wait`, `set` or
// `condition`, and any node has the decorators `when` with `abort`, `invert`, `cooldown`, `repeat`, `time_limit` and
// `force`. The reader checks the tree, and writes it in depth-first order, the root first, with each node's state and
// timers laid out in the agents' module state.

BEHAVIOR_TREE_READER :: Technique_Reader {
	version = "behavior_tree 1",
	read    = read_behavior_tree,
}

// Tree_Text_Node is what the reader makes of a node before it orders the tree.
@(private = "file")
Tree_Text_Node :: struct {
	record:        format.Tree_Node,
	known:         bool,
	children:      [dynamic]int,
	children_line: int,
	abort_line:    int,
	// The node that lists it as a child, or -1.
	parent:        int,
	order:         int,
	depth:         int,
}

@(private = "file")
Tree_Read :: struct {
	p:     ^Decision_Parser,
	text:  ^Decision_Text,
	nodes: []Tree_Text_Node,
	order: [dynamic]int,
}

// The fields that each kind takes, besides the decorators, which every kind takes.
@(private = "file")
TREE_DECORATORS :: []string{"when", "abort", "invert", "cooldown", "repeat", "time_limit", "force", "position"}

read_behavior_tree :: proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte) {
	problems := len(p.found)
	for s in text.settings {
		decision_problem(p, s.line, "a behavior tree has no setting %s", s.key)
	}
	if len(text.nodes) == 0 {
		decision_problem(p, 1, "a behavior tree has nodes: `node <id> <kind>`")
		return
	}
	r := Tree_Read {
		p     = p,
		text  = text,
		nodes = make([]Tree_Text_Node, len(text.nodes), context.temp_allocator),
		order = make([dynamic]int, context.temp_allocator),
	}
	by_id := make(map[int]int, len(text.nodes), context.temp_allocator)
	for n, i in text.nodes {
		by_id[n.id] = i
	}
	for &n, i in text.nodes {
		read_node(&r, &n, &r.nodes[i])
	}
	link_children(&r, by_id)
	if len(p.found) > problems {
		return
	}
	root := find_root(&r)
	if root < 0 {
		return
	}
	order_tree(&r, root, 1)
	for n, i in r.nodes {
		if n.parent >= 0 && n.order < 0 {
			decision_problem(p, text.nodes[i].line, "node %d is in a cycle: the root does not reach it", text.nodes[i].id)
		}
	}
	if len(p.found) > problems {
		return
	}
	check_tree(&r)
	if len(p.found) > problems {
		return
	}
	// The states first, TREE_STATE_SIZE each, then the timers, 8 bytes each.
	timers := u32(len(r.order) * format.TREE_STATE_SIZE)
	records := make([]format.Tree_Node, len(r.order), context.temp_allocator)
	for index, at in r.order {
		n := &r.nodes[index]
		n.record.state = u32(at * format.TREE_STATE_SIZE)
		n.record.timers = timers
		timers += u32(card(format.tree_timers(n.record))) * 8
		records[at] = n.record
	}
	return timers, format.tree_write(records)
}

// read_node reads a node's kind and fields into its record.
@(private = "file")
read_node :: proc(r: ^Tree_Read, text: ^Decision_Text_Node, n: ^Tree_Text_Node) {
	p := r.p
	n.parent = -1
	n.order = -1
	n.children = make([dynamic]int, context.temp_allocator)
	n.record = {
		node = u32(text.index),
		test = format.DECISION_NONE,
	}
	kind_names := format.TREE_KIND_NAMES
	for name, k in kind_names {
		if name == text.kind {
			n.record.kind = k
			n.known = true
		}
	}
	if !n.known {
		names := make([dynamic]string, context.temp_allocator)
		for name in kind_names {
			append(&names, name)
		}
		decision_problem(p, text.line, "%s is not a node of a behavior tree: a node is %s", text.kind, strings.join(names[:], ", ", context.temp_allocator))
		return
	}
	kind := n.record.kind
	kind_name := kind_names[kind]
	has := proc(text: ^Decision_Text_Node, key: string) -> bool {
		for f in text.fields {
			if f.key == key {
				return true
			}
		}
		return false
	}
	for f in text.fields {
		own := false
		switch f.key {
		case "children":
			own = kind in format.TREE_COMPOSITES
		case "action":
			own = kind == .Action
		case "condition":
			own = kind == .Condition
		case "seconds":
			own = kind == .Wait
		case "policy":
			own = kind == .Parallel
		case:
			for d in TREE_DECORATORS {
				own ||= d == f.key
			}
			if !own {
				decision_problem(p, f.line, "a behavior tree's node has no field %s", f.key)
				continue
			}
		}
		if !own {
			decision_problem(p, f.line, "a %s has no %s", kind_name, f.key)
			continue
		}
		read_field(r, n, f)
	}
	required := ""
	switch kind {
	case .Sequence, .Selector, .Parallel:
		if !has(text, "children") {
			decision_problem(p, text.line, "a %s has children: `children = <id>, <id>, ...`", kind_name)
		}
		if kind == .Parallel {
			required = "policy"
		}
	case .Action:
		required = "action"
	case .Wait:
		required = "seconds"
	case .Condition:
		required = "condition"
	case .Set:
		if text.set_line == 0 {
			decision_problem(p, text.line, "a set writes keys: `set <key> = <value>`")
		}
	}
	if required != "" && !has(text, required) {
		decision_problem(p, text.line, "a %s has a %s", kind_name, required)
	}
	if kind != .Set && text.set_line != 0 {
		decision_problem(p, text.set_line, "only a set node writes keys, and this is a %s", kind_name)
	}
	if n.abort_line != 0 && !has(text, "when") {
		decision_problem(p, n.abort_line, "abort is for a node's when: it has none")
	}
}

// read_field reads a field that the node's kind takes.
@(private = "file")
read_field :: proc(r: ^Tree_Read, n: ^Tree_Text_Node, f: Decision_Field) {
	p := r.p
	switch f.key {
	case "children":
		n.children_line = f.line
		for part in strings.split(f.value, ",", context.temp_allocator) {
			id, ok := strconv.parse_int(strings.trim_space(part))
			if !ok {
				decision_problem(p, f.line, "children are node IDs: `children = <id>, <id>, ...`")
				clear(&n.children)
				return
			}
			append(&n.children, id)
		}
	case "condition":
		n.record.test = decision_condition(p, f.value, f.line)
	case "seconds":
		n.record.seconds = tree_time(p, f)
	case "cooldown":
		n.record.cooldown = tree_time(p, f)
		n.record.flags += {.Cooldown}
	case "time_limit":
		n.record.time_limit = tree_time(p, f)
		n.record.flags += {.Time_Limit}
	case "policy":
		policy, ok := name_of(format.TREE_POLICY_NAMES, f.value)
		if !ok {
			decision_problem(p, f.line, "policy is one or all")
		}
		n.record.policy = policy
	case "abort":
		n.abort_line = f.line
		abort, ok := name_of(format.TREE_ABORT_NAMES, f.value)
		if !ok {
			decision_problem(p, f.line, "abort is none, self, lower or both")
		}
		n.record.abort = abort
	case "invert":
		switch f.value {
		case "true":
			n.record.flags += {.Invert}
		case "false":
		case:
			decision_problem(p, f.line, "invert is true or false")
		}
	case "force":
		switch f.value {
		case "succeed":
			n.record.force = .Succeed
		case "fail":
			n.record.force = .Fail
		case:
			decision_problem(p, f.line, "force is succeed or fail")
		}
	case "repeat":
		if f.value == "forever" {
			n.record.repeat = format.TREE_FOREVER
			return
		}
		count, ok := strconv.parse_int(f.value)
		if !ok || count < 1 || count >= int(format.TREE_FOREVER) {
			decision_problem(p, f.line, "repeat is a count of 1 or more, or forever")
			return
		}
		n.record.repeat = u32(count)
	case "when", "action", "position":
	// The shared parts read when and action, and nothing reads position.
	}
}

// name_of finds a value among an enum's names.
@(private)
name_of :: proc(names: [$E]string, value: string) -> (E, bool) {
	for name, e in names {
		if name == value {
			return e, true
		}
	}
	return {}, false
}

// tree_time reads a time: a number of seconds, 0 or more, or a float or int key.
@(private)
tree_time :: proc(p: ^Decision_Parser, f: Decision_Field) -> format.Tree_Time {
	if seconds, ok := strconv.parse_f32(f.value); ok {
		if seconds < 0 {
			decision_problem(p, f.line, "%s is 0 seconds or more", f.key)
		}
		return {seconds = seconds}
	}
	if is_identifier(f.value) {
		for k, slot in p.keys {
			if k.name != f.value {
				continue
			}
			if k.type != .Float && k.type != .Int {
				decision_problem(p, f.line, "%s is a %s, and %s is a float or an int key", f.value, type_name(k.type), f.key)
				return {}
			}
			return {key = u32(slot), source = .Key}
		}
		decision_problem(p, f.line, "the blackboard has no key named %s", f.value)
		return {}
	}
	decision_problem(p, f.line, "%s is a number of seconds or a float or int key", f.key)
	return {}
}

// link_children gives each child its parent, reporting IDs that no node has and children with two parents.
@(private = "file")
link_children :: proc(r: ^Tree_Read, by_id: map[int]int) {
	p := r.p
	for &n, i in r.nodes {
		for id, at in n.children {
			child, found := by_id[id]
			switch {
			case !found:
				decision_problem(p, n.children_line, "no node has the ID %d", id)
			case r.nodes[child].parent == i:
				decision_problem(p, n.children_line, "node %d is a child twice", id)
			case r.nodes[child].parent >= 0:
				decision_problem(p, n.children_line, "node %d is a child of node %d too: a node has one parent", id, r.text.nodes[r.nodes[child].parent].id)
			case:
				r.nodes[child].parent = i
			}
			n.children[at] = child if found else -1
		}
	}
}

// find_root is the one node that no node lists as a child, or -1, with a problem.
@(private = "file")
find_root :: proc(r: ^Tree_Read) -> int {
	root := -1
	many := false
	for n, i in r.nodes {
		if n.parent >= 0 {
			continue
		}
		if root >= 0 {
			decision_problem(r.p, r.text.nodes[i].line, "node %d is not a child of any node, and node %d is the root: a tree has one root", r.text.nodes[i].id, r.text.nodes[root].id)
			many = true
			continue
		}
		root = i
	}
	if root < 0 {
		decision_problem(r.p, r.text.nodes[0].line, "every node is a child of another, in a cycle: a tree has a root")
	}
	return -1 if many else root
}

// order_tree puts a node and its subtree in depth-first order, and gives each its end and depth. A tree deeper than
// MAX_TREE_DEPTH is a problem at the first node too deep.
@(private = "file")
order_tree :: proc(r: ^Tree_Read, index: int, depth: int) {
	n := &r.nodes[index]
	if n.order >= 0 {
		return
	}
	n.order = len(r.order)
	n.depth = depth
	append(&r.order, index)
	if depth == format.MAX_TREE_DEPTH + 1 {
		decision_problem(r.p, r.text.nodes[index].line, "the tree is deeper than %d nodes", format.MAX_TREE_DEPTH)
	}
	for child in n.children {
		order_tree(r, child, depth + 1)
	}
	r.nodes[index].record.end = u32(len(r.order))
}

// check_tree checks what needs the whole tree: that an abort of lower priorities is on a selector's child, and that a
// parallel's policy can be met and its children run one action at most.
@(private = "file")
check_tree :: proc(r: ^Tree_Read) {
	p := r.p
	abort_names := format.TREE_ABORT_NAMES
	for n, i in r.nodes {
		if n.record.abort == .Lower || n.record.abort == .Both {
			if n.parent < 0 || r.nodes[n.parent].record.kind != .Selector {
				decision_problem(p, n.abort_line, "abort = %s is for a selector's child: lower priorities are its later children", abort_names[n.record.abort])
			}
		}
		if n.record.kind != .Parallel {
			continue
		}
		succeed, fail, acting := 0, 0, 0
		for child in n.children {
			can_succeed, can_fail := outcomes(r.nodes[child].record)
			succeed += int(can_succeed)
			fail += int(can_fail)
			acting += int(has_action(r, child))
		}
		line := r.text.nodes[i].line
		switch n.record.policy {
		case .One:
			if succeed == 0 {
				decision_problem(p, line, "no child of this parallel can succeed, so its policy one is never met")
			}
		case .All:
			if succeed < len(n.children) {
				decision_problem(p, line, "a child of this parallel never succeeds, so its policy all is never met")
			}
		}
		if acting > 1 {
			decision_problem(p, line, "%d children of this parallel run actions: an agent runs one action at a time", acting)
		}
	}
}

// outcomes is whether a node can succeed and can fail, by its decorators: a repeat forever succeeds never, invert swaps
// the two, and force decides.
@(private = "file")
outcomes :: proc(n: format.Tree_Node) -> (can_succeed, can_fail: bool) {
	can_succeed, can_fail = n.repeat != format.TREE_FOREVER, true
	if .Invert in n.flags {
		can_succeed, can_fail = can_fail, can_succeed
	}
	switch n.force {
	case .None:
	case .Succeed:
		can_succeed, can_fail = true, false
	case .Fail:
		can_succeed, can_fail = false, true
	}
	return
}

@(private = "file")
has_action :: proc(r: ^Tree_Read, index: int) -> bool {
	if r.nodes[index].record.kind == .Action {
		return true
	}
	for child in r.nodes[index].children {
		if has_action(r, child) {
			return true
		}
	}
	return false
}

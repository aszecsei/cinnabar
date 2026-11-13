package asset_format

import "core:mem"

import "cinnabar:core/layout"

// A behavior tree is the technique data of a decision whose technique is Behavior_Tree (see
// docs/content/kinds/decisions.md#behavior-trees): a Tree_Header, then the tree's nodes in depth-first order, the root
// first. A node's subtree is the nodes from it to its end, and its children are the node after it and then each node at
// the end of the child before. Each node has TREE_STATE_SIZE bytes of state in the agent's module state, at its state
// offset, and its timers at its timers offset.

// A tree is at most this many nodes deep, the root's depth being 1.
MAX_TREE_DEPTH :: 32
// The bytes of a node's state in the agent's module state.
TREE_STATE_SIZE :: 16
// A repeat that never ends.
TREE_FOREVER :: max(u32)

Tree_Kind :: enum u8 {
	Sequence,
	Selector,
	Parallel,
	Action,
	Wait,
	Set,
	Condition,
}

// TREE_KIND_NAMES are the node kinds as a decision's text names them.
TREE_KIND_NAMES :: [Tree_Kind]string {
	.Sequence  = "sequence",
	.Selector  = "selector",
	.Parallel  = "parallel",
	.Action    = "action",
	.Wait      = "wait",
	.Set       = "set",
	.Condition = "condition",
}

// TREE_COMPOSITES are the kinds that have children.
TREE_COMPOSITES :: bit_set[Tree_Kind]{.Sequence, .Selector, .Parallel}

// Tree_Abort is what a node's guard aborts while it is observed: its own branch when it becomes false, the lower
// priorities that run when it becomes true, both, or nothing.
Tree_Abort :: enum u8 {
	None,
	Self,
	Lower,
	Both,
}

TREE_ABORT_NAMES :: [Tree_Abort]string {
	.None  = "none",
	.Self  = "self",
	.Lower = "lower",
	.Both  = "both",
}

// Tree_Force is the result that a node gives whatever its own was, or None for its own.
Tree_Force :: enum u8 {
	None,
	Succeed,
	Fail,
}

// Tree_Policy is when a parallel ends: One succeeds when a child succeeds and fails when all fail; All succeeds when all
// succeed and fails when one fails.
Tree_Policy :: enum u8 {
	One,
	All,
}

TREE_POLICY_NAMES :: [Tree_Policy]string {
	.One = "one",
	.All = "all",
}

// Tree_Flag is a decorator that a node has: Invert swaps its success and failure, and Cooldown and Time_Limit have
// their times in the node.
Tree_Flag :: enum u8 {
	Invert,
	Cooldown,
	Time_Limit,
}

Tree_Flags :: bit_set[Tree_Flag;u8]

// Tree_Time_Source is where a time comes from: the node's constant, or a float or int key.
Tree_Time_Source :: enum u8 {
	Constant,
	Key,
}

// Tree_Time is a time in seconds: a constant in seconds, or the value of the key at the slot key. The zero time is a
// constant 0.
Tree_Time :: struct {
	seconds: f32,
	key:     u32,
	source:  Tree_Time_Source,
	padding: [3]u8,
}
#assert(size_of(Tree_Time) == 12)

// Tree_Timer is one of a node's timers, which are u64 ticks from its timers offset in this order, each only if the node
// has it: a wait's end, the tick that a node with a time limit started in, and the tick that a node with a cooldown may
// start again in.
Tree_Timer :: enum u8 {
	Wait_Until,
	Started,
	Ready_At,
}

// Tree_Node is a node of the tree.
Tree_Node :: struct {
	// The decision's node, whose condition is the guard, whose action an action node starts, and whose writes a set
	// node makes.
	node:       u32,
	// One past the last node of its subtree.
	end:        u32,
	kind:       Tree_Kind,
	abort:      Tree_Abort,
	force:      Tree_Force,
	policy:     Tree_Policy,
	flags:      Tree_Flags,
	padding:    [3]u8,
	// The times that the node runs in a row while it succeeds: 0 once, TREE_FOREVER without end.
	repeat:     u32,
	// A condition node's condition, a decision's condition, or DECISION_NONE.
	test:       u32,
	// A wait's time.
	seconds:    Tree_Time,
	cooldown:   Tree_Time,
	time_limit: Tree_Time,
	// The offsets of its state and its timers in the agent's module state.
	state:      u32,
	timers:     u32,
}
#assert(size_of(Tree_Node) == 68)

// Tree_Header starts a tree's data. layout is tree_layout's, so data of another build is refused.
Tree_Header :: struct {
	layout:     u64,
	node_count: u32,
	padding:    u32,
}
#assert(size_of(Tree_Header) == 16)

tree_layout :: proc() -> u64 {
	return layout.hash(Tree_Header) ~ layout.hash(Tree_Node) * 31 ~ layout.hash(Tree_Time) * 961
}

// tree_timers is the timers that a node has.
tree_timers :: proc "contextless" (n: Tree_Node) -> (timers: bit_set[Tree_Timer]) {
	if n.kind == .Wait {
		timers += {.Wait_Until}
	}
	if .Time_Limit in n.flags {
		timers += {.Started}
	}
	if .Cooldown in n.flags {
		timers += {.Ready_At}
	}
	return
}

// tree_timer is the offset of a node's timer in the agent's module state. The node has it.
tree_timer :: proc "contextless" (n: Tree_Node, timer: Tree_Timer) -> u32 {
	before := 0
	for t in tree_timers(n) {
		if t < timer {
			before += 1
		}
	}
	return n.timers + u32(before) * 8
}

// tree_nodes is a tree's nodes, without checking them: tree_view checks them once, when the decision loads.
tree_nodes :: proc "contextless" (data: []byte) -> []Tree_Node {
	if len(data) < size_of(Tree_Header) {
		return nil
	}
	header := (^Tree_Header)(raw_data(data))
	return ([^]Tree_Node)(raw_data(data[size_of(Tree_Header):]))[:header.node_count]
}

// tree_view checks a tree's data against its decision: its layout and size, that its subtrees nest and are at most
// MAX_TREE_DEPTH deep, that a composite has children and another node none, that each node's decision node, action and
// condition are there, and that each state and timer is inside the module state. It does not check keys: tree_check
// does, with the blackboard.
tree_view :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob) -> (nodes: []Tree_Node, ok: bool) {
	if len(data) < size_of(Tree_Header) || uintptr(raw_data(data)) % align_of(Tree_Node) != 0 {
		return
	}
	header := (^Tree_Header)(raw_data(data))
	if header.layout != tree_layout() || header.node_count == 0 ||
	   u64(len(data)) != size_of(Tree_Header) + u64(header.node_count) * size_of(Tree_Node) {
		return
	}
	nodes = tree_nodes(data)
	decision_nodes := decision_nodes(decision_data, decision)
	conditions := decision_conditions(decision_data, decision)
	state_size := decision.state_size
	for n in nodes {
		if n.kind > max(Tree_Kind) || n.abort > max(Tree_Abort) || n.force > max(Tree_Force) || n.policy > max(Tree_Policy) ||
		   n.seconds.source > max(Tree_Time_Source) || n.cooldown.source > max(Tree_Time_Source) ||
		   n.time_limit.source > max(Tree_Time_Source) || int(n.node) >= len(decision_nodes) {
			return nil, false
		}
		if n.kind == .Action && decision_nodes[n.node].action == DECISION_NONE {
			return nil, false
		}
		if n.kind == .Condition && int(n.test) >= len(conditions) {
			return nil, false
		}
		if n.state % 4 != 0 || u64(n.state) + TREE_STATE_SIZE > u64(state_size) {
			return nil, false
		}
		if n.timers % 8 != 0 || u64(n.timers) + u64(card(tree_timers(n))) * 8 > u64(state_size) {
			return nil, false
		}
	}
	// The subtrees nest: the root's is the tree, a composite's children fill its own, and another node's is itself.
	nest :: proc(nodes: []Tree_Node, i: u32, depth: int) -> bool {
		n := nodes[i]
		if depth > MAX_TREE_DEPTH || n.end <= i || int(n.end) > len(nodes) {
			return false
		}
		if n.kind not_in TREE_COMPOSITES {
			return n.end == i + 1
		}
		if n.end == i + 1 {
			return false
		}
		for c := i + 1; c < n.end; c = nodes[c].end {
			if !nest(nodes, c, depth + 1) || nodes[c].end > n.end {
				return false
			}
		}
		return true
	}
	if nodes[0].end != header.node_count || !nest(nodes, 0, 1) {
		return nil, false
	}
	return nodes, true
}

// tree_check checks a tree against its decision and its decision's blackboard: tree_view's checks, and that each time
// that a key holds is a float or an int key's.
tree_check :: proc(data: []byte, decision_data: []byte, decision: ^Decision_Blob, board_data: []byte, board: ^Blackboard_Blob) -> bool {
	nodes, ok := tree_view(data, decision_data, decision)
	if !ok {
		return false
	}
	keys := blackboard_keys(board_data, board)
	time_ok :: proc(t: Tree_Time, keys: []Blackboard_Key) -> bool {
		return t.source == .Constant || (int(t.key) < len(keys) && (keys[t.key].type == .Float || keys[t.key].type == .Int))
	}
	for n in nodes {
		if !time_ok(n.seconds, keys) || !time_ok(n.cooldown, keys) || !time_ok(n.time_limit, keys) {
			return false
		}
	}
	return true
}

// tree_write builds a tree's data from its nodes.
tree_write :: proc(nodes: []Tree_Node, allocator := context.allocator) -> []byte {
	data := make([]byte, size_of(Tree_Header) + len(nodes) * size_of(Tree_Node), allocator)
	header := Tree_Header {
		layout     = tree_layout(),
		node_count = u32(len(nodes)),
	}
	mem.copy(raw_data(data), &header, size_of(header))
	if len(nodes) > 0 {
		mem.copy(&data[size_of(Tree_Header)], raw_data(nodes), len(nodes) * size_of(Tree_Node))
	}
	return data
}

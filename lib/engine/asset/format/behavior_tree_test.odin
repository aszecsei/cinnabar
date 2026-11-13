package asset_format

import "core:slice"
import "core:testing"

// test_tree is a selector of a condition and a sequence of an action and a wait for the key at slot 0, with the
// condition's node on a cooldown.
@(private = "file")
test_tree :: proc() -> []Tree_Node {
	return slice.clone(
		[]Tree_Node {
			{node = 0, end = 5, kind = .Selector, test = DECISION_NONE, state = 0, timers = 80},
			{node = 1, end = 2, kind = .Condition, test = 0, flags = {.Cooldown}, cooldown = {seconds = 2}, state = 16, timers = 80},
			{node = 2, end = 5, kind = .Sequence, test = DECISION_NONE, state = 32, timers = 88},
			{node = 3, end = 4, kind = .Action, test = DECISION_NONE, state = 48, timers = 88},
			{node = 4, end = 5, kind = .Wait, test = DECISION_NONE, seconds = {key = 0, source = .Key}, state = 64, timers = 88},
		},
		context.temp_allocator,
	)
}

@(private = "file")
tree_decision :: proc(tree: []byte, state_size: u32 = 96) -> []byte {
	nodes := make([]Decision_Node_Contents, 5, context.temp_allocator)
	for &n, i in nodes {
		n = {id = u32(i + 1), kind = "node", condition = DECISION_NONE, action = DECISION_NONE}
	}
	nodes[3].action = 0
	contents := Decision_Contents {
		technique      = .Behavior_Tree,
		state_size     = state_size,
		nodes          = nodes,
		conditions     = {{first_op = 0, op_count = 1}},
		ops            = {{code = .Key, operand = 1}},
		actions        = {{name = "walk"}},
		technique_data = tree,
	}
	return aligned(decision_write(contents, context.temp_allocator))
}

@(private = "file")
tree_of :: proc(data: []byte) -> ([]byte, ^Decision_Blob) {
	blob, ok := decision_view(data)
	if !ok {
		return nil, nil
	}
	return decision_technique_data(data, blob), blob
}

@(test)
trees_round_trip :: proc(t: ^testing.T) {
	data := tree_decision(tree_write(test_tree(), context.temp_allocator))
	tree, blob := tree_of(data)
	testing.expect(t, blob != nil)
	if blob == nil {
		return
	}
	nodes, ok := tree_view(tree, data, blob)
	testing.expect(t, ok)
	testing.expect_value(t, len(nodes), 5)
	testing.expect_value(t, nodes[2].end, 5)
	testing.expect_value(t, nodes[4].seconds.source, Tree_Time_Source.Key)
	testing.expect_value(t, tree_timer(nodes[1], .Ready_At), 80)
	testing.expect_value(t, tree_timer(nodes[4], .Wait_Until), 88)
	both := Tree_Node {
		kind   = .Wait,
		flags  = {.Time_Limit, .Cooldown},
		timers = 8,
	}
	testing.expect_value(t, tree_timer(both, .Started), 16)
	testing.expect_value(t, tree_timer(both, .Ready_At), 24)
}

// A tree whose subtrees do not nest, whose nodes are not in its decision, or whose states are outside the module state
// is refused, and so is a time from a key that is not a number.
@(test)
bad_trees_are_refused :: proc(t: ^testing.T) {
	Change :: proc(nodes: []Tree_Node)
	changes := []Change {
		proc(nodes: []Tree_Node) {nodes[0].end = 4},
		proc(nodes: []Tree_Node) {nodes[2].end = 3},
		proc(nodes: []Tree_Node) {nodes[3].end = 5},
		proc(nodes: []Tree_Node) {nodes[1].kind = .Sequence},
		proc(nodes: []Tree_Node) {nodes[3].node = 9},
		proc(nodes: []Tree_Node) {nodes[3].node = 0},
		proc(nodes: []Tree_Node) {nodes[1].test = 1},
		proc(nodes: []Tree_Node) {nodes[4].state = 90},
		proc(nodes: []Tree_Node) {nodes[1].timers = 92},
		proc(nodes: []Tree_Node) {nodes[4].kind = Tree_Kind(9)},
	}
	for change, i in changes {
		nodes := test_tree()
		change(nodes)
		data := tree_decision(tree_write(nodes, context.temp_allocator))
		tree, blob := tree_of(data)
		_, ok := tree_view(tree, data, blob)
		testing.expectf(t, !ok, "change %d is refused", i)
	}

	// Another layout, and a tree deeper than the limit.
	data := tree_decision(tree_write(test_tree(), context.temp_allocator))
	tree, blob := tree_of(data)
	(^Tree_Header)(raw_data(tree)).layout += 1
	_, ok := tree_view(tree, data, blob)
	testing.expect(t, !ok)
	deep := make([]Tree_Node, MAX_TREE_DEPTH + 1, context.temp_allocator)
	for &n in deep {
		n = {node = 0, end = u32(len(deep)), kind = .Sequence, test = DECISION_NONE}
	}
	deep[len(deep) - 1].kind = .Set
	data = tree_decision(tree_write(deep, context.temp_allocator))
	tree, blob = tree_of(data)
	_, ok = tree_view(tree, data, blob)
	testing.expect(t, !ok)
	deep = deep[1:]
	for &n in deep {
		n.end -= 1
	}
	data = tree_decision(tree_write(deep, context.temp_allocator))
	tree, blob = tree_of(data)
	_, ok = tree_view(tree, data, blob)
	testing.expect(t, ok)

	// A wait for a key that is a bool's, and then a float's.
	board := aligned(blackboard_write({keys = {{name = "delay", type = .Bool}, {name = "seen", type = .Bool}}}, context.temp_allocator))
	board_blob, board_ok := blackboard_view(board)
	testing.expect(t, board_ok)
	data = tree_decision(tree_write(test_tree(), context.temp_allocator))
	tree, blob = tree_of(data)
	testing.expect(t, !tree_check(tree, data, blob, board, board_blob))
	board = aligned(blackboard_write({keys = {{name = "delay", type = .Float}, {name = "seen", type = .Bool}}}, context.temp_allocator))
	board_blob, _ = blackboard_view(board)
	testing.expect(t, tree_check(tree, data, blob, board, board_blob))
}

package cook

import "core:fmt"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
TREE_BOARD :: `blackboard 1
float health = 1
float delay = 0.5
int count = 2
bool has_target
enum mood (calm, alert) = calm
entity target
`

@(private = "file")
TREE_BOARD_GUID :: "00112233445566778899aabbccddeeff"

@(private = "file")
TREE_HEAD :: "decision 1\ntechnique = behavior_tree\nblackboard = $" + TREE_BOARD_GUID + "\n"

// A guard: attack a close target, chase a seen one, and otherwise patrol, with an alarm when its health is low. The
// nodes are not in the tree's order, which the cook finds.
@(private = "file")
GUARD :: TREE_HEAD + `
node 1 selector
	children = 2, 5, 8
node 8 parallel
	position = [0, 300]
	policy = one
	children = 9, 10
node 9 action
	action = patrol
	repeat = forever
	invert = true
node 10 sequence
	children = 11, 12
node 11 condition
	condition = health < 0.3
node 12 set
	set mood = alert
	force = fail
node 2 sequence
	when = target != none and distance(self, target) < 2
	abort = both
	children = 3, 4
node 3 action
	action = attack(at = target)
	cooldown = 1.5
node 4 wait
	seconds = delay
node 5 action
	when = has_target
	abort = lower
	action = chase(at = target)
	time_limit = 10
`

@(private = "file")
tree_keys :: proc(t: ^testing.T) -> []format.Blackboard_Key_Contents {
	contents, problems := blackboard_parse(TREE_BOARD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	return contents.keys
}

// The tree is in depth-first order, the root first, with each node's end, its decision node, its decorators and its
// state and timers laid out after each other.
@(test)
a_behavior_tree_cooks_in_depth_first_order :: proc(t: ^testing.T) {
	contents, problems := decision_parse(GUARD, tree_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(problems) > 0 {
		return
	}
	nodes := format.tree_nodes(contents.technique_data)
	testing.expect_value(t, len(nodes), 10)
	if len(nodes) != 10 {
		return
	}
	ids := [10]u32{1, 2, 3, 4, 5, 8, 9, 10, 11, 12}
	ends := [10]u32{10, 4, 3, 4, 5, 10, 7, 10, 9, 10}
	kinds := [10]format.Tree_Kind{.Selector, .Sequence, .Action, .Wait, .Action, .Parallel, .Action, .Sequence, .Condition, .Set}
	for n, i in nodes {
		testing.expectf(t, contents.nodes[n.node].id == ids[i], "node %d is %d", i, contents.nodes[n.node].id)
		testing.expectf(t, n.end == ends[i], "node %d ends at %d", i, n.end)
		testing.expectf(t, n.kind == kinds[i], "node %d is a %v", i, n.kind)
		testing.expect_value(t, n.state, u32(i * format.TREE_STATE_SIZE))
	}
	testing.expect_value(t, nodes[1].abort, format.Tree_Abort.Both)
	testing.expect(t, contents.nodes[nodes[1].node].condition != format.DECISION_NONE)
	testing.expect_value(t, nodes[4].abort, format.Tree_Abort.Lower)
	testing.expect_value(t, nodes[5].policy, format.Tree_Policy.One)
	testing.expect_value(t, nodes[6].repeat, format.TREE_FOREVER)
	testing.expect(t, .Invert in nodes[6].flags)
	// The shared parts parse the guards first, as the lines come, and the reader the conditions after.
	testing.expect_value(t, nodes[8].test, 2)
	testing.expect_value(t, nodes[9].force, format.Tree_Force.Fail)
	testing.expect_value(t, contents.nodes[nodes[9].node].write_count, 1)
	// The timers follow the ten states: the attack's cooldown, the wait's end and the chase's start.
	testing.expect_value(t, nodes[2].cooldown, format.Tree_Time{seconds = 1.5})
	testing.expect_value(t, format.tree_timer(nodes[2], .Ready_At), 160)
	testing.expect_value(t, nodes[3].seconds, format.Tree_Time{key = 1, source = .Key})
	testing.expect_value(t, format.tree_timer(nodes[3], .Wait_Until), 168)
	testing.expect_value(t, format.tree_timer(nodes[4], .Started), 176)
	testing.expect_value(t, contents.state_size, 184)
}

@(test)
behavior_tree_problems_have_their_lines :: proc(t: ^testing.T) {
	deep := strings.builder_make(context.temp_allocator)
	for i in 1 ..= format.MAX_TREE_DEPTH + 1 {
		fmt.sbprintf(&deep, "node %d sequence\n\tchildren = %d\n", i, i + 1)
	}
	fmt.sbprintf(&deep, "node %d wait\n\tseconds = 1\n", format.MAX_TREE_DEPTH + 2)
	cases := []struct {
		text: string,
		line: int,
	} {
		{"", 1},
		{"speed = 2\nnode 1 wait\n\tseconds = 1\n", 4},
		{"node 1 dance\n", 4},
		{"node 1 wait\n\tseconds = 1\n\tcolor = red\n", 6},
		{"node 1 wait\n\tseconds = 1\n\tpolicy = one\n", 6},
		{"node 1 sequence\n", 4},
		{"node 1 action\n", 4},
		{"node 1 condition\n", 4},
		{"node 1 wait\n", 4},
		{"node 1 set\n", 4},
		{"node 1 wait\n\tseconds = 1\n\tset mood = alert\n", 6},
		{"node 1 sequence\n\tchildren = 2\n", 5},
		{"node 1 sequence\n\tchildren = 2, x\nnode 2 wait\n\tseconds = 1\n", 5},
		{"node 1 sequence\n\tchildren = 2, 2\nnode 2 wait\n\tseconds = 1\n", 5},
		{"node 1 sequence\n\tchildren = 2, 3\nnode 3 sequence\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\n", 7},
		{"node 1 wait\n\tseconds = 1\nnode 2 wait\n\tseconds = 1\n", 6},
		{"node 1 sequence\n\tchildren = 1\n", 4},
		{"node 1 sequence\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\nnode 3 sequence\n\tchildren = 4\nnode 4 sequence\n\tchildren = 3\n", 8},
		{strings.to_string(deep), 4 + 2 * format.MAX_TREE_DEPTH},
		{"node 1 wait\n\tseconds = 1\n\tabort = self\n", 6},
		{"node 1 sequence\n\tchildren = 2\nnode 2 wait\n\twhen = has_target\n\tabort = lower\n\tseconds = 1\n", 8},
		{"node 1 wait\n\twhen = has_target\n\tabort = both\n\tseconds = 1\n", 6},
		{"node 1 parallel\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\n", 4},
		{"node 1 parallel\n\tpolicy = all\n\tchildren = 2, 3\nnode 2 wait\n\tseconds = 1\n\trepeat = forever\nnode 3 wait\n\tseconds = 1\n", 4},
		{"node 1 parallel\n\tpolicy = one\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\n\tforce = fail\n", 4},
		{"node 1 parallel\n\tpolicy = one\n\tchildren = 2, 3\nnode 2 action\n\taction = a\nnode 3 sequence\n\tchildren = 4\nnode 4 action\n\taction = b\n", 4},
		{"node 1 condition\n\tcondition = missing\n", 5},
		{"node 1 wait\n\tseconds = has_target\n", 5},
		{"node 1 wait\n\tseconds = later\n", 5},
		{"node 1 wait\n\tseconds = -1\n", 5},
		{"node 1 wait\n\tseconds = 1\n\trepeat = 0\n", 6},
		{"node 1 wait\n\tseconds = 1\n\tinvert = yes\n", 6},
		{"node 1 wait\n\tseconds = 1\n\tforce = maybe\n", 6},
		{"node 1 wait\n\tseconds = 1\n\twhen = has_target\n\tabort = always\n", 7},
		{"node 1 parallel\n\tpolicy = most\n\tchildren = 2\nnode 2 wait\n\tseconds = 1\n", 5},
	}
	keys := tree_keys(t)
	for c in cases {
		_, problems := decision_parse(strings.concatenate({TREE_HEAD, c.text}, context.temp_allocator), keys, TECHNIQUE_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}

	// The decorators that a node takes whatever its kind, and the policies that can be met.
	good := []string {
		"node 1 wait\n\tseconds = 0\n\tposition = [1, 2]\n\tinvert = false\n\trepeat = 3\n\tcooldown = count\n\ttime_limit = 2.5\n\tforce = succeed\n",
		"node 1 selector\n\tchildren = 2\nnode 2 condition\n\tcondition = has_target\n\twhen = health > 0\n\tabort = lower\n",
		"node 1 parallel\n\tpolicy = all\n\tchildren = 2, 3\nnode 2 wait\n\tseconds = 1\n\trepeat = forever\n\tforce = succeed\nnode 3 action\n\taction = a\n",
	}
	for g in good {
		_, problems := decision_parse(strings.concatenate({TREE_HEAD, g}, context.temp_allocator), keys, TECHNIQUE_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) == 0, "%q: %v", g, problems)
	}
}

// The cooker cooks a behavior tree with its own reader into a blob whose tree fits its blackboard.
@(test)
behavior_trees_cook_to_blobs_that_fit_their_blackboards :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/ai/guard.blackboard", TREE_BOARD},
			{"content/ai/guard.blackboard.meta", "guid = " + TREE_BOARD_GUID + "\n"},
			{"content/ai/guard.decision", GUARD},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Blackboard, .Decision}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Decision], 1)
	board_guid, _ := format.guid_parse(TREE_BOARD_GUID)
	board_data := tree_blob(t, tree, board_guid)
	board, board_ok := format.blackboard_view(board_data)
	data := tree_blob(t, tree, tree_guid(t, tree, "ai/guard.decision"))
	blob, ok := format.decision_view(data)
	testing.expect(t, ok && board_ok)
	if !ok || !board_ok {
		return
	}
	testing.expect_value(t, blob.technique, format.Decision_Technique.Behavior_Tree)
	testing.expect_value(t, blob.state_size, 184)
	testing.expect(t, format.decision_check(data, blob, board_data, board))
	testing.expect(t, format.tree_check(format.decision_technique_data(data, blob), data, blob, board_data, board))
}

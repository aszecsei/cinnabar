package asset_format

import "core:slice"
import "core:testing"

// test_goap plans over the bool at slot 2, the int at slot 3 and the enum at slot 4: a goal that the bool is true,
// scaled by a consideration of the float at slot 0, and two actions, one that sets the bool and one that adds to the
// int at the cost of the float at slot 0.
@(private = "file")
test_goap :: proc() -> Goap_Contents {
	return Goap_Contents {
		max_nodes = 8,
		max_plan = 4,
		keys = slice.clone([]u32{2, 3, 4}, context.temp_allocator),
		actions = slice.clone(
			[]Plan_Action {
				{node = 1, cost = {value = 1}, first_test = 1, test_count = 1, first_effect = 0, effect_count = 1},
				{node = 2, cost = {key = 0, source = .Key}, first_test = 2, test_count = 0, first_effect = 1, effect_count = 2},
			},
			context.temp_allocator,
		),
		goals = slice.clone([]Goap_Goal{{node = 0, priority = 2, first_link = 0, link_count = 1, first_test = 0, test_count = 1}}, context.temp_allocator),
		tests = slice.clone([]Plan_Test{{key = 0, lo = 1, hi = 1}, {key = 1, lo = 1, hi = max(i32)}}, context.temp_allocator),
		effects = slice.clone([]Plan_Effect{{key = 0, op = .Set, value = 1}, {key = 1, op = .Add, value = 3}, {key = 2, op = .Set, value = 1}}, context.temp_allocator),
		considerations = slice.clone([]Utility_Consideration{{node = 3, input = .Number, curve = .Linear, a = 0, max = 1, slope = 1, exponent = 1}}, context.temp_allocator),
		links = slice.clone([]u32{0}, context.temp_allocator),
	}
}

@(private = "file")
goap_decision :: proc(data: []byte, state_size: u32 = 0) -> []byte {
	nodes := make([]Decision_Node_Contents, 4, context.temp_allocator)
	kinds := [4]string{"goal", "action", "action", "consideration"}
	for &n, i in nodes {
		n = {id = u32(i + 1), kind = kinds[i], condition = DECISION_NONE, action = DECISION_NONE}
	}
	nodes[1].action = 0
	nodes[2].action = 1
	size := state_size
	if size == 0 {
		size = u32(goap_state(3, 2, 1, 8, 4).size)
	}
	contents := Decision_Contents {
		technique      = .Goap,
		state_size     = size,
		nodes          = nodes,
		actions        = {{name = "arm"}, {name = "reload"}},
		technique_data = data,
	}
	return aligned(decision_write(contents, context.temp_allocator))
}

@(private = "file")
goap_board :: proc() -> []byte {
	keys := []Blackboard_Key_Contents {
		{name = "health", type = .Float},
		{name = "target", type = .Entity},
		{name = "armed", type = .Bool},
		{name = "ammo", type = .Int},
		{name = "mood", type = .Enum, enum_names = {"calm", "alert"}},
	}
	return aligned(blackboard_write({keys = keys}, context.temp_allocator))
}

@(test)
goap_round_trips :: proc(t: ^testing.T) {
	data := goap_decision(goap_write(test_goap(), context.temp_allocator))
	blob, ok := decision_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	g, viewed := goap_view(decision_technique_data(data, blob), data, blob)
	testing.expect(t, viewed)
	if !viewed {
		return
	}
	testing.expect_value(t, g.header.max_nodes, 8)
	testing.expect_value(t, g.header.max_plan, 4)
	testing.expect(t, slice.equal(g.keys, []u32{2, 3, 4}))
	testing.expect_value(t, len(g.actions), 2)
	testing.expect_value(t, g.actions[1].cost, Plan_Number{key = 0, source = .Key})
	testing.expect_value(t, g.goals[0].priority, 2)
	testing.expect_value(t, g.tests[1], Plan_Test{key = 1, lo = 1, hi = max(i32)})
	testing.expect_value(t, g.effects[1], Plan_Effect{key = 1, op = .Add, value = 3})
	testing.expect_value(t, len(g.considerations), 1)
	board := goap_board()
	board_blob, board_ok := blackboard_view(board)
	testing.expect(t, board_ok)
	if board_ok {
		testing.expect(t, goap_check(decision_technique_data(data, blob), data, blob, board, board_blob))
	}
}

// The state's parts follow each other, 4-aligned, and the size is 8-aligned.
@(test)
goap_state_is_laid_out_in_order :: proc(t: ^testing.T) {
	s := goap_state(3, 2, 1, 8, 4)
	testing.expect_value(t, s.priorities, 32)
	testing.expect_value(t, s.failed_at, 36)
	testing.expect_value(t, s.steps, 48)
	testing.expect_value(t, s.expected, 56)
	testing.expect_value(t, s.search, 68)
	testing.expect_value(t, s.world, 76)
	testing.expect_value(t, s.usable, 88)
	testing.expect_value(t, s.costs, 92)
	testing.expect_value(t, s.nodes, 100)
	testing.expect_value(t, s.node_size, 40)
	testing.expect_value(t, s.size, 424)
}

// Data of another layout, with indices out of range, empty tests, costs of 0, a state too small, or keys of types that
// it does not read is refused.
@(test)
bad_goap_is_refused :: proc(t: ^testing.T) {
	Change :: proc(c: ^Goap_Contents)
	views := []Change {
		proc(c: ^Goap_Contents) {c.actions[0].node = 9},
		proc(c: ^Goap_Contents) {c.actions[0].node = 0},
		proc(c: ^Goap_Contents) {c.actions[0].cost = {value = 0}},
		proc(c: ^Goap_Contents) {c.actions[0].effect_count = 0},
		proc(c: ^Goap_Contents) {c.actions[1].effect_count = 3},
		proc(c: ^Goap_Contents) {c.goals[0].test_count = 0},
		proc(c: ^Goap_Contents) {c.goals[0].priority = -1},
		proc(c: ^Goap_Contents) {c.goals[0].link_count = 2},
		proc(c: ^Goap_Contents) {c.links[0] = 1},
		proc(c: ^Goap_Contents) {c.tests[0].key = 3},
		proc(c: ^Goap_Contents) {c.tests[0] = {key = 0, lo = 1, hi = 0}},
		proc(c: ^Goap_Contents) {c.effects[0].key = 5},
		proc(c: ^Goap_Contents) {c.max_plan = 0},
		proc(c: ^Goap_Contents) {c.max_plan = MAX_PLAN_LENGTH + 1},
		proc(c: ^Goap_Contents) {c.max_nodes = 0},
		proc(c: ^Goap_Contents) {c.max_nodes = 9},
		proc(c: ^Goap_Contents) {c.considerations[0].max = 0},
	}
	for change, i in views {
		contents := test_goap()
		change(&contents)
		data := goap_decision(goap_write(contents, context.temp_allocator))
		blob, ok := decision_view(data)
		testing.expect(t, ok)
		_, viewed := goap_view(decision_technique_data(data, blob), data, blob)
		testing.expectf(t, !viewed, "change %d is viewed", i)
	}
	// A layout of another build is refused.
	{
		data := goap_write(test_goap(), context.temp_allocator)
		(^Goap_Header)(raw_data(data)).layout += 1
		decision := goap_decision(data)
		blob, _ := decision_view(decision)
		_, viewed := goap_view(decision_technique_data(decision, blob), decision, blob)
		testing.expect(t, !viewed)
	}
	checks := []Change {
		proc(c: ^Goap_Contents) {c.keys[0] = 0},
		proc(c: ^Goap_Contents) {c.keys[1] = 2},
		proc(c: ^Goap_Contents) {c.keys[2] = 9},
		proc(c: ^Goap_Contents) {c.effects[1].key = 0},
		proc(c: ^Goap_Contents) {c.effects[0].value = 2},
		proc(c: ^Goap_Contents) {c.effects[2].value = 2},
		proc(c: ^Goap_Contents) {c.actions[1].cost = {key = 1, source = .Key}},
		proc(c: ^Goap_Contents) {c.considerations[0].a = 1},
	}
	board := goap_board()
	board_blob, _ := blackboard_view(board)
	for change, i in checks {
		contents := test_goap()
		change(&contents)
		data := goap_decision(goap_write(contents, context.temp_allocator))
		blob, _ := decision_view(data)
		g := decision_technique_data(data, blob)
		_, viewed := goap_view(g, data, blob)
		testing.expectf(t, viewed, "check %d is not viewed", i)
		testing.expectf(t, !goap_check(g, data, blob, board, board_blob), "check %d passes", i)
	}
}

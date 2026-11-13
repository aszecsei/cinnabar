package asset_format

import "core:slice"
import "core:testing"

// test_utility is two options: the first with a linear consideration of the float at slot 0, and a cooldown; the
// second, which targets the entity at slot 1, with a table of its distance from the agent and the same consideration.
@(private = "file")
test_utility :: proc() -> Utility_Contents {
	return Utility_Contents {
		pick = .Weighted,
		within = 0.1,
		momentum = 0.25,
		options = slice.clone(
			[]Utility_Option {
				{node = 0, weight = 1, first_link = 0, link_count = 1, target = DECISION_NONE, flags = {.Cooldown}, cooldown = {seconds = 2}, state = 8, links_state = 56},
				{node = 1, weight = 2, first_link = 1, link_count = 2, target = 1, state = 32, links_state = 64},
			},
			context.temp_allocator,
		),
		considerations = slice.clone(
			[]Utility_Consideration {
				{node = 2, input = .Number, curve = .Linear, a = 0, max = 1, slope = 1, exponent = 1},
				{node = 3, input = .Distance, curve = .Table, a = UTILITY_SELF, b = 1, max = 10, slope = 1, exponent = 1, first_point = 0, point_count = 2},
			},
			context.temp_allocator,
		),
		links = slice.clone([]u32{0, 1, 0}, context.temp_allocator),
		points = slice.clone([]Utility_Point{{0, 1}, {1, 0}}, context.temp_allocator),
	}
}

@(private = "file")
utility_decision :: proc(data: []byte, state_size: u32 = 80) -> []byte {
	nodes := make([]Decision_Node_Contents, 4, context.temp_allocator)
	for &n, i in nodes {
		n = {id = u32(i + 1), kind = "option" if i < 2 else "consideration", condition = DECISION_NONE, action = DECISION_NONE}
	}
	nodes[0].action = 0
	nodes[1].action = 1
	contents := Decision_Contents {
		technique      = .Utility,
		state_size     = state_size,
		nodes          = nodes,
		actions        = {{name = "rest"}, {name = "attack"}},
		technique_data = data,
	}
	return aligned(decision_write(contents, context.temp_allocator))
}

@(private = "file")
utility_board :: proc() -> []byte {
	keys := []Blackboard_Key_Contents{{name = "health", type = .Float}, {name = "target", type = .Entity}, {name = "mood", type = .Bool}}
	return aligned(blackboard_write({keys = keys}, context.temp_allocator))
}

@(test)
utility_round_trips :: proc(t: ^testing.T) {
	data := utility_decision(utility_write(test_utility(), context.temp_allocator))
	blob, ok := decision_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	u, viewed := utility_view(decision_technique_data(data, blob), data, blob)
	testing.expect(t, viewed)
	testing.expect_value(t, len(u.options), 2)
	testing.expect_value(t, len(u.considerations), 2)
	testing.expect_value(t, len(u.links), 3)
	testing.expect_value(t, len(u.points), 2)
	testing.expect_value(t, u.header.pick, Utility_Pick.Weighted)
	testing.expect_value(t, u.options[1].target, 1)
	testing.expect_value(t, u.considerations[1].b, 1)
	testing.expect_value(t, u.points[1], Utility_Point{1, 0})
	board := utility_board()
	board_blob, board_ok := blackboard_view(board)
	testing.expect(t, board_ok)
	if board_ok {
		testing.expect(t, utility_check(decision_technique_data(data, blob), data, blob, board, board_blob))
	}
}

// Data of another layout, with indices out of range, states outside the module state, a table whose points go back,
// or keys of types that it does not read is refused.
@(test)
bad_utility_is_refused :: proc(t: ^testing.T) {
	Change :: proc(c: ^Utility_Contents)
	views := []Change {
		proc(c: ^Utility_Contents) {c.options[0].node = 9},
		proc(c: ^Utility_Contents) {c.options[1].link_count = 3},
		proc(c: ^Utility_Contents) {c.links[2] = 5},
		proc(c: ^Utility_Contents) {c.options[1].state = 64},
		proc(c: ^Utility_Contents) {c.options[1].links_state = 68},
		proc(c: ^Utility_Contents) {c.considerations[1].point_count = 3},
		proc(c: ^Utility_Contents) {c.considerations[1].point_count = 1},
		proc(c: ^Utility_Contents) {c.points[1].x = -1},
		proc(c: ^Utility_Contents) {c.considerations[0].max = 0},
		proc(c: ^Utility_Contents) {c.within = 2},
		proc(c: ^Utility_Contents) {c.options[0].weight = -1},
	}
	for change, i in views {
		contents := test_utility()
		change(&contents)
		data := utility_decision(utility_write(contents, context.temp_allocator))
		blob, ok := decision_view(data)
		testing.expect(t, ok)
		_, viewed := utility_view(decision_technique_data(data, blob), data, blob)
		testing.expectf(t, !viewed, "change %d is viewed", i)
	}
	// An option whose decision node has no action is refused.
	{
		data := utility_write(test_utility(), context.temp_allocator)
		decision := utility_decision(data)
		blob, _ := decision_view(decision)
		nodes := decision_nodes(decision, blob)
		nodes[1].action = DECISION_NONE
		_, viewed := utility_view(decision_technique_data(decision, blob), decision, blob)
		testing.expect(t, !viewed)
	}
	// A layout of another build is refused.
	{
		data := utility_write(test_utility(), context.temp_allocator)
		(^Utility_Header)(raw_data(data)).layout += 1
		decision := utility_decision(data)
		blob, _ := decision_view(decision)
		_, viewed := utility_view(decision_technique_data(decision, blob), decision, blob)
		testing.expect(t, !viewed)
	}
	checks := []Change {
		proc(c: ^Utility_Contents) {c.options[1].target = 0},
		proc(c: ^Utility_Contents) {c.considerations[0].a = 1},
		proc(c: ^Utility_Contents) {c.considerations[1].a = 0},
		proc(c: ^Utility_Contents) {c.considerations[0].a = 7},
		proc(c: ^Utility_Contents) {c.options[0].cooldown = {key = 2, source = .Key}},
	}
	board := utility_board()
	board_blob, _ := blackboard_view(board)
	for change, i in checks {
		contents := test_utility()
		change(&contents)
		data := utility_decision(utility_write(contents, context.temp_allocator))
		blob, _ := decision_view(data)
		u := decision_technique_data(data, blob)
		_, viewed := utility_view(u, data, blob)
		testing.expectf(t, viewed, "check %d is not viewed", i)
		testing.expectf(t, !utility_check(u, data, blob, board, board_blob), "check %d passes", i)
	}
}

package asset_format

import "core:slice"
import "core:testing"

// test_htn plans over the bool at slot 2, the int at slot 3 and the enum at slot 4: a root task with two methods, one
// that arms and then reloads when the bool is true, and one that reloads; arm sets the bool, and reload adds to the int
// and sets the enum.
@(private = "file")
test_htn :: proc() -> Htn_Contents {
	return Htn_Contents {
		root = 0,
		max_plan = 4,
		keys = slice.clone([]u32{2, 3, 4}, context.temp_allocator),
		actions = slice.clone(
			[]Plan_Action {
				{node = 3, cost = {value = 1}, first_test = 1, test_count = 1, first_effect = 0, effect_count = 1},
				{node = 4, cost = {value = 1}, first_test = 2, test_count = 0, first_effect = 1, effect_count = 2},
			},
			context.temp_allocator,
		),
		tasks = slice.clone([]Htn_Task{{node = 0, first_method = 0, method_count = 2}}, context.temp_allocator),
		methods = slice.clone(
			[]Htn_Method {
				{node = 1, first_test = 0, test_count = 1, first_subtask = 0, subtask_count = 2},
				{node = 2, first_test = 1, test_count = 0, first_subtask = 2, subtask_count = 1},
			},
			context.temp_allocator,
		),
		subtasks = slice.clone([]Htn_Subtask{{.Action, 0}, {.Action, 1}, {.Action, 1}}, context.temp_allocator),
		tests = slice.clone([]Plan_Test{{key = 0, lo = 1, hi = 1}, {key = 1, lo = 1, hi = max(i32)}}, context.temp_allocator),
		effects = slice.clone([]Plan_Effect{{key = 0, op = .Set, value = 1}, {key = 1, op = .Add, value = 3}, {key = 2, op = .Set, value = 1}}, context.temp_allocator),
	}
}

@(private = "file")
htn_decision :: proc(data: []byte, state_size: u32 = 0) -> []byte {
	nodes := make([]Decision_Node_Contents, 5, context.temp_allocator)
	kinds := [5]string{"task", "method", "method", "action", "action"}
	for &n, i in nodes {
		n = {id = u32(i + 1), kind = kinds[i], condition = DECISION_NONE, action = DECISION_NONE}
	}
	nodes[3].action = 0
	nodes[4].action = 1
	size := state_size
	if size == 0 {
		size = u32(htn_state(3, 2, 2, 4).size)
	}
	contents := Decision_Contents {
		technique      = .Htn,
		state_size     = size,
		nodes          = nodes,
		actions        = {{name = "arm"}, {name = "reload"}},
		technique_data = data,
	}
	return aligned(decision_write(contents, context.temp_allocator))
}

@(private = "file")
htn_board :: proc() -> []byte {
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
htn_round_trips :: proc(t: ^testing.T) {
	data := htn_decision(htn_write(test_htn(), context.temp_allocator))
	blob, ok := decision_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	h, viewed := htn_view(decision_technique_data(data, blob), data, blob)
	testing.expect(t, viewed)
	if !viewed {
		return
	}
	testing.expect_value(t, h.header.root, 0)
	testing.expect_value(t, h.header.max_plan, 4)
	testing.expect(t, slice.equal(h.keys, []u32{2, 3, 4}))
	testing.expect_value(t, len(h.actions), 2)
	testing.expect_value(t, h.tasks[0], Htn_Task{node = 0, first_method = 0, method_count = 2})
	testing.expect_value(t, h.methods[1], Htn_Method{node = 2, first_test = 1, test_count = 0, first_subtask = 2, subtask_count = 1})
	testing.expect_value(t, h.subtasks[2], Htn_Subtask{.Action, 1})
	testing.expect_value(t, h.tests[1], Plan_Test{key = 1, lo = 1, hi = max(i32)})
	testing.expect_value(t, h.effects[1], Plan_Effect{key = 1, op = .Add, value = 3})
	board := htn_board()
	board_blob, board_ok := blackboard_view(board)
	testing.expect(t, board_ok)
	if board_ok {
		testing.expect(t, htn_check(decision_technique_data(data, blob), data, blob, board, board_blob))
	}
}

// The state's parts follow each other, 4-aligned, and the size is 8-aligned.
@(test)
htn_state_is_laid_out_in_order :: proc(t: ^testing.T) {
	s := htn_state(3, 2, 2, 4)
	testing.expect_value(t, s.steps, 32)
	testing.expect_value(t, s.expected, 40)
	testing.expect_value(t, s.record, 52)
	testing.expect_value(t, s.search, 308)
	testing.expect_value(t, s.world, 340)
	testing.expect_value(t, s.begin, 352)
	testing.expect_value(t, s.usable_methods, 364)
	testing.expect_value(t, s.usable_actions, 368)
	testing.expect_value(t, s.plan, 372)
	testing.expect_value(t, s.choices, 380)
	testing.expect_value(t, s.frames, 636)
	testing.expect_value(t, s.size, 768)
}

// Data of another layout, with indices out of range, a root that is not a task, tasks without methods, methods without
// subtasks, empty tests, a state too small, or keys of types that it does not read is refused.
@(test)
bad_htn_is_refused :: proc(t: ^testing.T) {
	Change :: proc(c: ^Htn_Contents)
	views := []Change {
		proc(c: ^Htn_Contents) {c.actions[0].node = 9},
		proc(c: ^Htn_Contents) {c.actions[0].node = 0},
		proc(c: ^Htn_Contents) {c.actions[1].effect_count = 3},
		proc(c: ^Htn_Contents) {c.root = 1},
		proc(c: ^Htn_Contents) {c.tasks[0].method_count = 0},
		proc(c: ^Htn_Contents) {c.tasks[0].method_count = 3},
		proc(c: ^Htn_Contents) {c.tasks[0].node = 9},
		proc(c: ^Htn_Contents) {c.methods[0].subtask_count = 0},
		proc(c: ^Htn_Contents) {c.methods[1].subtask_count = 2},
		proc(c: ^Htn_Contents) {c.methods[0].test_count = 3},
		proc(c: ^Htn_Contents) {c.subtasks[0] = {.Action, 2}},
		proc(c: ^Htn_Contents) {c.subtasks[0] = {.Task, 1}},
		proc(c: ^Htn_Contents) {c.subtasks[0].kind = Htn_Subtask_Kind(2)},
		proc(c: ^Htn_Contents) {c.tests[0].key = 3},
		proc(c: ^Htn_Contents) {c.tests[0] = {key = 0, lo = 1, hi = 0}},
		proc(c: ^Htn_Contents) {c.effects[0].key = 5},
		proc(c: ^Htn_Contents) {c.max_plan = 0},
		proc(c: ^Htn_Contents) {c.max_plan = MAX_PLAN_LENGTH + 1},
		proc(c: ^Htn_Contents) {c.max_plan = 8},
	}
	for change, i in views {
		contents := test_htn()
		change(&contents)
		data := htn_decision(htn_write(contents, context.temp_allocator))
		blob, ok := decision_view(data)
		testing.expect(t, ok)
		_, viewed := htn_view(decision_technique_data(data, blob), data, blob)
		testing.expectf(t, !viewed, "change %d is viewed", i)
	}
	// A layout of another build is refused.
	{
		data := htn_write(test_htn(), context.temp_allocator)
		(^Htn_Header)(raw_data(data)).layout += 1
		decision := htn_decision(data)
		blob, _ := decision_view(decision)
		_, viewed := htn_view(decision_technique_data(decision, blob), decision, blob)
		testing.expect(t, !viewed)
	}
	checks := []Change {
		proc(c: ^Htn_Contents) {c.keys[0] = 0},
		proc(c: ^Htn_Contents) {c.keys[1] = 2},
		proc(c: ^Htn_Contents) {c.keys[2] = 9},
		proc(c: ^Htn_Contents) {c.effects[1].key = 0},
		proc(c: ^Htn_Contents) {c.effects[0].value = 2},
		proc(c: ^Htn_Contents) {c.effects[2].value = 2},
	}
	board := htn_board()
	board_blob, _ := blackboard_view(board)
	for change, i in checks {
		contents := test_htn()
		change(&contents)
		data := htn_decision(htn_write(contents, context.temp_allocator))
		blob, _ := decision_view(data)
		h := decision_technique_data(data, blob)
		_, viewed := htn_view(h, data, blob)
		testing.expectf(t, viewed, "check %d is not viewed", i)
		testing.expectf(t, !htn_check(h, data, blob, board, board_blob), "check %d passes", i)
	}
}

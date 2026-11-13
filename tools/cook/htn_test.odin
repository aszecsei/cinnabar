package cook

import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
HTN_BOARD :: `blackboard 1
float health = 100
int ammo = 3
bool armed
bool near
bool sees
enum mood (calm, alert) = calm
entity target
`

@(private = "file")
HTN_BOARD_GUID :: "00112233445566778899aabbccddeef2"

@(private = "file")
HTN_HEAD :: "decision 1\ntechnique = htn\nblackboard = $" + HTN_BOARD_GUID + "\n"

// A guard: attack a target that it sees, closing in first unless it is near; arm itself when it is not armed; and
// otherwise patrol.
@(private = "file")
GUARD :: HTN_HEAD + `keys = armed, near, sees, ammo
root = 1
max_plan = 6

node 1 task
	methods = 2, 3, 4
node 2 method
	when = target != none
	preconditions = sees and ammo > 0
	subtasks = 5, 10
node 3 method
	preconditions = not armed
	subtasks = 11
node 4 method
	subtasks = 12
node 5 task
	methods = 6, 7
node 6 method
	preconditions = near
	subtasks = 13
node 7 method
	subtasks = 14, 13
node 10 action
	action = attack(at = target)
	preconditions = near and ammo > 0
	effects = ammo -= 1
	set mood = alert
node 11 action
	action = pick_up(item = "rifle")
	effects = armed = true, ammo += 6
node 12 action
	position = [0, 200]
	action = patrol
node 13 action
	action = aim
node 14 action
	action = move_to(key = "target")
	when = health > 10
	preconditions = not near
	effects = near = true
`

@(private = "file")
htn_keys :: proc(t: ^testing.T) -> []format.Blackboard_Key_Contents {
	contents, problems := blackboard_parse(HTN_BOARD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	return contents.keys
}

// The planning keys are their slots, the actions and tasks are in the text's order, each task's methods are together in
// its order, each subtask names its kind, each key's tests are one interval, and the module state is sized from the
// counts.
@(test)
an_htn_decision_cooks :: proc(t: ^testing.T) {
	contents, problems := decision_parse(GUARD, htn_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(problems) > 0 {
		return
	}
	h := format.htn_data(contents.technique_data)
	if h.header == nil || len(h.tasks) != 2 || len(h.methods) != 5 || len(h.actions) != 5 || len(h.subtasks) != 7 {
		testing.expect(t, false, "the data's counts")
		return
	}
	MAX :: max(i32)
	id :: proc(contents: format.Decision_Contents, node: u32) -> u32 {
		return contents.nodes[node].id
	}
	testing.expect_value(t, h.header.root, 0)
	testing.expect_value(t, h.header.max_plan, 6)
	testing.expect_value(t, len(h.keys), 4)
	testing.expect_value(t, h.keys[0], 2)
	testing.expect_value(t, h.keys[1], 3)
	testing.expect_value(t, h.keys[2], 4)
	testing.expect_value(t, h.keys[3], 1)

	root, aim := h.tasks[0], h.tasks[1]
	testing.expect_value(t, id(contents, root.node), 1)
	testing.expect_value(t, root.first_method, 0)
	testing.expect_value(t, root.method_count, 3)
	testing.expect_value(t, id(contents, aim.node), 5)
	testing.expect_value(t, aim.first_method, 3)
	testing.expect_value(t, aim.method_count, 2)

	attack, arm, patrol, near, close := h.methods[0], h.methods[1], h.methods[2], h.methods[3], h.methods[4]
	testing.expect_value(t, id(contents, attack.node), 2)
	testing.expect(t, contents.nodes[attack.node].condition != format.DECISION_NONE)
	testing.expect_value(t, attack.test_count, 2)
	testing.expect_value(t, h.tests[attack.first_test], format.Plan_Test{key = 2, lo = 1, hi = 1})
	testing.expect_value(t, h.tests[attack.first_test + 1], format.Plan_Test{key = 3, lo = 1, hi = MAX})
	testing.expect_value(t, attack.subtask_count, 2)
	testing.expect_value(t, h.subtasks[attack.first_subtask], format.Htn_Subtask{.Task, 1})
	testing.expect_value(t, h.subtasks[attack.first_subtask + 1], format.Htn_Subtask{.Action, 0})
	testing.expect_value(t, id(contents, arm.node), 3)
	testing.expect_value(t, h.tests[arm.first_test], format.Plan_Test{key = 0, lo = 0, hi = 0})
	testing.expect_value(t, id(contents, patrol.node), 4)
	testing.expect_value(t, patrol.test_count, 0)
	testing.expect_value(t, h.subtasks[patrol.first_subtask], format.Htn_Subtask{.Action, 2})
	testing.expect_value(t, id(contents, near.node), 6)
	testing.expect_value(t, h.subtasks[near.first_subtask], format.Htn_Subtask{.Action, 3})
	testing.expect_value(t, id(contents, close.node), 7)
	testing.expect_value(t, close.subtask_count, 2)
	testing.expect_value(t, h.subtasks[close.first_subtask], format.Htn_Subtask{.Action, 4})
	testing.expect_value(t, h.subtasks[close.first_subtask + 1], format.Htn_Subtask{.Action, 3})

	strike, pick_up, walk, point, move := h.actions[0], h.actions[1], h.actions[2], h.actions[3], h.actions[4]
	testing.expect_value(t, id(contents, strike.node), 10)
	testing.expect_value(t, contents.nodes[strike.node].write_count, 1)
	testing.expect_value(t, strike.test_count, 2)
	testing.expect_value(t, h.effects[strike.first_effect], format.Plan_Effect{key = 3, op = .Add, value = -1})
	testing.expect_value(t, pick_up.effect_count, 2)
	testing.expect_value(t, h.effects[pick_up.first_effect], format.Plan_Effect{key = 0, op = .Set, value = 1})
	testing.expect_value(t, h.effects[pick_up.first_effect + 1], format.Plan_Effect{key = 3, op = .Add, value = 6})
	testing.expect_value(t, id(contents, walk.node), 12)
	testing.expect_value(t, walk.effect_count, 0)
	testing.expect_value(t, id(contents, point.node), 13)
	testing.expect_value(t, id(contents, move.node), 14)
	testing.expect(t, contents.nodes[move.node].condition != format.DECISION_NONE)
	testing.expect_value(t, h.tests[move.first_test], format.Plan_Test{key = 1, lo = 0, hi = 0})

	// 32 bytes of agent and runner, 12 of steps, 16 expected, 256 of record, 32 of search header, 16 of world and 16 of
	// its beginning, 4 and 4 of usable bits, 12 of plan, 256 of choices and 128 of frames.
	testing.expect_value(t, contents.state_size, 784)
	testing.expect_value(t, contents.state_size, u32(format.htn_state(4, 5, 5, 6).size))
}

// The settings' defaults, a decision without planning keys, and a task that recurses through its methods.
@(test)
htn_settings_have_defaults :: proc(t: ^testing.T) {
	text := HTN_HEAD + "root = 1\nnode 1 task\n\tmethods = 2\nnode 2 method\n\tsubtasks = 3, 1\nnode 3 action\n\taction = a\n"
	contents, problems := decision_parse(text, htn_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	h := format.htn_data(contents.technique_data)
	if h.header == nil {
		return
	}
	testing.expect_value(t, h.header.max_plan, HTN_DEFAULT_MAX_PLAN)
	testing.expect_value(t, len(h.keys), 0)
	testing.expect_value(t, h.subtasks[1], format.Htn_Subtask{.Task, 0})
	testing.expect_value(t, contents.state_size, u32(format.htn_state(0, 1, 1, HTN_DEFAULT_MAX_PLAN).size))
}

@(test)
htn_problems_have_their_lines :: proc(t: ^testing.T) {
	KEYS :: "keys = armed, ammo, mood\n"
	ROOT :: "root = 1\n"
	TASK :: "node 1 task\n\tmethods = 2\n"
	METHOD :: "node 2 method\n\tsubtasks = 3\n"
	ACTION :: "node 3 action\n\taction = a\n"
	// The header is 3 lines, and KEYS and ROOT one each, so the task starts at 6, the method at 8 and the action at 10.
	cases := []struct {
		text: string,
		line: int,
	} {
		{KEYS + TASK + METHOD + ACTION, 1},
		{KEYS + ROOT + METHOD + ACTION, 1},
		{KEYS + ROOT + TASK + METHOD, 1},
		{KEYS + "speed = 2\n" + ROOT + TASK + METHOD + ACTION, 5},
		{KEYS + "root = one\n" + TASK + METHOD + ACTION, 5},
		{KEYS + "root = 9\n" + TASK + METHOD + ACTION, 5},
		{KEYS + "root = 2\n" + TASK + METHOD + ACTION, 5},
		{"keys = armed, health\n" + ROOT + TASK + METHOD + ACTION, 4},
		{"keys = armed, armed\n" + ROOT + TASK + METHOD + ACTION, 4},
		{KEYS + ROOT + "max_plan = 0\n" + TASK + METHOD + ACTION, 6},
		{KEYS + ROOT + "max_plan = 99\n" + TASK + METHOD + ACTION, 6},
		{KEYS + ROOT + "node 9 dance\n" + TASK + METHOD + ACTION, 6},
		{KEYS + ROOT + "node 1 task\n" + METHOD + ACTION, 6},
		{KEYS + ROOT + TASK + "node 2 method\n" + ACTION, 8},
		{KEYS + ROOT + TASK + METHOD + "node 3 action\n", 10},
		{KEYS + ROOT + "node 1 task\n\tmethods = 2, x\n" + METHOD + ACTION, 7},
		{KEYS + ROOT + "node 1 task\n\tmethods = 2, 9\n" + METHOD + ACTION, 7},
		{KEYS + ROOT + "node 1 task\n\tmethods = 2, 3\n" + METHOD + ACTION, 7},
		{KEYS + ROOT + "node 1 task\n\tmethods = 2, 2\n" + METHOD + ACTION, 7},
		{KEYS + ROOT + TASK + "\twhen = armed\n" + METHOD + ACTION, 8},
		{KEYS + ROOT + TASK + "\tpreconditions = armed\n" + METHOD + ACTION, 8},
		{KEYS + ROOT + TASK + "\tcolor = red\n" + METHOD + ACTION, 8},
		{KEYS + ROOT + TASK + "\tset mood = alert\n" + METHOD + ACTION, 8},
		{KEYS + ROOT + TASK + "node 2 method\n\tsubtasks = 2\n" + ACTION, 9},
		{KEYS + ROOT + TASK + "node 2 method\n\tsubtasks = 9\n" + ACTION, 9},
		{KEYS + ROOT + TASK + METHOD + "\teffects = armed = true\n" + ACTION, 10},
		{KEYS + ROOT + TASK + METHOD + "\tset mood = alert\n" + ACTION, 10},
		{KEYS + ROOT + TASK + METHOD + ACTION + "node 4 method\n\tsubtasks = 3\n", 12},
		{KEYS + ROOT + TASK + METHOD + ACTION + "node 4 task\n\tmethods = 2\n", 13},
		{KEYS + ROOT + TASK + METHOD + ACTION + "node 4 action\n\taction = b\n", 12},
		{KEYS + ROOT + TASK + "node 2 method\n\tpreconditions = health > 2\n\tsubtasks = 3\n" + ACTION, 9},
		{KEYS + ROOT + TASK + "node 2 method\n\tpreconditions = ammo > 3 and ammo < 2\n\tsubtasks = 3\n" + ACTION, 9},
		{KEYS + ROOT + TASK + METHOD + ACTION + "\tcost = 2\n", 12},
		{KEYS + ROOT + TASK + METHOD + ACTION + "\teffects = armed += 1\n", 12},
		{KEYS + ROOT + TASK + METHOD + ACTION + "\teffects = mood = furious\n", 12},
		{KEYS + ROOT + TASK + METHOD + ACTION + "\tset ammo = 2\n", 12},
	}
	keys := htn_keys(t)
	for c in cases {
		_, problems := decision_parse(strings.concatenate({HTN_HEAD, c.text}, context.temp_allocator), keys, TECHNIQUE_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

// The cooker cooks an HTN decision with its own reader into a blob whose data fits its blackboard.
@(test)
htn_decisions_cook_to_blobs_that_fit_their_blackboards :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/ai/guard.blackboard", HTN_BOARD},
			{"content/ai/guard.blackboard.meta", "guid = " + HTN_BOARD_GUID + "\n"},
			{"content/ai/guard.decision", GUARD},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Blackboard, .Decision}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Decision], 1)
	board_guid, _ := format.guid_parse(HTN_BOARD_GUID)
	board_data := tree_blob(t, tree, board_guid)
	board, board_ok := format.blackboard_view(board_data)
	data := tree_blob(t, tree, tree_guid(t, tree, "ai/guard.decision"))
	blob, ok := format.decision_view(data)
	testing.expect(t, ok && board_ok)
	if !ok || !board_ok {
		return
	}
	testing.expect_value(t, blob.technique, format.Decision_Technique.Htn)
	testing.expect_value(t, blob.state_size, 784)
	testing.expect(t, format.decision_check(data, blob, board_data, board))
	testing.expect(t, format.htn_check(format.decision_technique_data(data, blob), data, blob, board_data, board))
}

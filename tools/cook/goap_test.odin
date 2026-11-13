package cook

import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
GOAP_BOARD :: `blackboard 1
float health = 100
int ammo = 3
bool armed
bool near
bool down
enum mood (calm, alert) = calm
entity target
float travel = 2
`

@(private = "file")
GOAP_BOARD_GUID :: "00112233445566778899aabbccddeef1"

@(private = "file")
GOAP_HEAD :: "decision 1\ntechnique = goap\nblackboard = $" + GOAP_BOARD_GUID + "\n"

// A hunter: down the target when there is one, and otherwise keep ammo. The goals come first, then the actions, and
// the consideration last.
@(private = "file")
HUNTER :: GOAP_HEAD + `keys = armed, ammo, near, down
max_nodes = 48
max_plan = 6

node 1 goal
	when = target != none
	desired = down
	priority = 10
	considerations = 20
node 2 goal
	desired = ammo >= 5
node 10 action
	action = pick_up(item = "rifle")
	effects = armed = true, ammo += 6
	cost = 2
node 11 action
	action = attack(at = target)
	when = health > 10
	preconditions = armed and ammo > 0 and near
	effects = down = true, ammo -= 1
	set mood = alert
node 12 action
	position = [0, 200]
	action = move_to(key = "target")
	preconditions = not near
	effects = near = true
	cost = travel
node 20 consideration
	input = health
	range = [0, 100]
	curve = linear
`

@(private = "file")
goap_keys :: proc(t: ^testing.T) -> []format.Blackboard_Key_Contents {
	contents, problems := blackboard_parse(GOAP_BOARD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	return contents.keys
}

// The planning keys are their slots, the goals and actions are in the text's order, each key's tests are one interval,
// effects are sets and adds, and the module state is sized from the search's size.
@(test)
a_goap_decision_cooks :: proc(t: ^testing.T) {
	contents, problems := decision_parse(HUNTER, goap_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(problems) > 0 {
		return
	}
	g := format.goap_data(contents.technique_data)
	if g.header == nil || len(g.goals) != 2 || len(g.actions) != 3 || len(g.considerations) != 1 {
		testing.expect(t, false, "the data's counts")
		return
	}
	MAX :: max(i32)
	testing.expect_value(t, g.header.max_nodes, 48)
	testing.expect_value(t, g.header.max_plan, 6)
	testing.expect_value(t, len(g.keys), 4)
	testing.expect_value(t, g.keys[0], 2)
	testing.expect_value(t, g.keys[1], 1)
	testing.expect_value(t, g.keys[2], 3)
	testing.expect_value(t, g.keys[3], 4)

	down, keep := g.goals[0], g.goals[1]
	testing.expect_value(t, contents.nodes[down.node].id, 1)
	testing.expect(t, contents.nodes[down.node].condition != format.DECISION_NONE)
	testing.expect_value(t, down.priority, 10)
	testing.expect_value(t, down.link_count, 1)
	testing.expect_value(t, g.links[down.first_link], 0)
	testing.expect_value(t, down.test_count, 1)
	testing.expect_value(t, g.tests[down.first_test], format.Plan_Test{key = 3, lo = 1, hi = 1})
	testing.expect_value(t, keep.priority, 1)
	testing.expect_value(t, keep.link_count, 0)
	testing.expect_value(t, keep.test_count, 1)
	testing.expect_value(t, g.tests[keep.first_test], format.Plan_Test{key = 1, lo = 5, hi = MAX})

	pick_up, attack, move := g.actions[0], g.actions[1], g.actions[2]
	testing.expect_value(t, contents.nodes[pick_up.node].id, 10)
	testing.expect_value(t, pick_up.cost, format.Plan_Number{value = 2})
	testing.expect_value(t, pick_up.test_count, 0)
	testing.expect_value(t, pick_up.effect_count, 2)
	testing.expect_value(t, g.effects[pick_up.first_effect], format.Plan_Effect{key = 0, op = .Set, value = 1})
	testing.expect_value(t, g.effects[pick_up.first_effect + 1], format.Plan_Effect{key = 1, op = .Add, value = 6})
	testing.expect_value(t, attack.cost, format.Plan_Number{value = 1})
	testing.expect(t, contents.nodes[attack.node].condition != format.DECISION_NONE)
	testing.expect_value(t, contents.nodes[attack.node].write_count, 1)
	testing.expect_value(t, attack.test_count, 3)
	testing.expect_value(t, g.tests[attack.first_test], format.Plan_Test{key = 0, lo = 1, hi = 1})
	testing.expect_value(t, g.tests[attack.first_test + 1], format.Plan_Test{key = 1, lo = 1, hi = MAX})
	testing.expect_value(t, g.tests[attack.first_test + 2], format.Plan_Test{key = 2, lo = 1, hi = 1})
	testing.expect_value(t, g.effects[attack.first_effect + 1], format.Plan_Effect{key = 1, op = .Add, value = -1})
	testing.expect_value(t, move.cost, format.Plan_Number{key = 7, source = .Key})
	testing.expect_value(t, g.tests[move.first_test], format.Plan_Test{key = 2, lo = 0, hi = 0})
	testing.expect_value(t, g.considerations[0].a, 0)

	// 32 bytes of agent and runner, then 8 of priorities, 16 of failed state, 12 of steps, 16 expected, 8 of search
	// header, 16 of world, 4 of usable bits, 12 of costs, and 48 nodes of 16 + 4 × 8 bytes.
	testing.expect_value(t, contents.state_size, 2432)
}

// The settings' defaults, and tests of one key that make one interval.
@(test)
goap_settings_have_defaults :: proc(t: ^testing.T) {
	text := GOAP_HEAD + "keys = ammo, mood\nnode 1 goal\n\tdesired = ammo > 2 and ammo <= 9 and mood == alert\nnode 2 action\n\taction = a\n\teffects = ammo += 1, mood = alert\n"
	contents, problems := decision_parse(text, goap_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	g := format.goap_data(contents.technique_data)
	if g.header == nil {
		return
	}
	testing.expect_value(t, g.header.max_nodes, GOAP_DEFAULT_MAX_NODES)
	testing.expect_value(t, g.header.max_plan, GOAP_DEFAULT_MAX_PLAN)
	testing.expect_value(t, g.goals[0].priority, 1)
	testing.expect_value(t, g.goals[0].test_count, 2)
	testing.expect_value(t, g.tests[0], format.Plan_Test{key = 0, lo = 3, hi = 9})
	testing.expect_value(t, g.tests[1], format.Plan_Test{key = 1, lo = 1, hi = 1})
	testing.expect_value(t, g.effects[1], format.Plan_Effect{key = 1, op = .Set, value = 1})
	testing.expect_value(t, contents.state_size, u32(format.goap_state(2, 1, 1, GOAP_DEFAULT_MAX_NODES, GOAP_DEFAULT_MAX_PLAN).size))
}

@(test)
goap_problems_have_their_lines :: proc(t: ^testing.T) {
	KEYS :: "keys = armed, ammo, mood\n"
	GOAL :: "node 1 goal\n\tdesired = armed\n"
	ACTION :: "node 2 action\n\taction = a\n\teffects = armed = true\n"
	// The header is 3 lines and KEYS one, so a goal's first line is 5 and an action after it starts at 7.
	cases := []struct {
		text: string,
		line: int,
	} {
		{GOAL + ACTION, 1},
		{KEYS, 1},
		{KEYS + GOAL, 1},
		{KEYS + ACTION, 1},
		{"speed = 2\n" + KEYS + GOAL + ACTION, 4},
		{"keys = armed, missing\n" + GOAL + ACTION, 4},
		{"keys = armed, health\n" + GOAL + ACTION, 4},
		{"keys = armed, armed\n" + GOAL + ACTION, 4},
		{"keys = armed, 3\n" + GOAL + ACTION, 4},
		{KEYS + "max_nodes = 0\n" + GOAL + ACTION, 5},
		{KEYS + "max_plan = 99\n" + GOAL + ACTION, 5},
		{KEYS + "max_nodes = 1000\n" + GOAL + ACTION, 5},
		{KEYS + "node 9 dance\n" + GOAL + ACTION, 5},
		{KEYS + "node 1 goal\n" + ACTION, 5},
		{KEYS + GOAL + "node 2 action\n\teffects = armed = true\n", 7},
		{KEYS + GOAL + "node 2 action\n\taction = a\n", 7},
		{KEYS + GOAL + "\tcolor = red\n" + ACTION, 7},
		{KEYS + GOAL + "\teffects = armed = true\n" + ACTION, 7},
		{KEYS + GOAL + "\tset mood = alert\n" + ACTION, 7},
		{KEYS + GOAL + "\tpriority = -1\n" + ACTION, 7},
		{KEYS + GOAL + "\tconsiderations = 9\n" + ACTION, 7},
		{KEYS + GOAL + "\tconsiderations = 2\n" + ACTION, 7},
		{KEYS + GOAL + ACTION + "node 3 consideration\n\tinput = health\n\tcurve = linear\n", 10},
		{KEYS + GOAL + "\tconsiderations = 3\n" + ACTION + "node 3 consideration\n\tinput = health\n", 11},
		{KEYS + "node 1 goal\n\tdesired = missing\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = health > 2\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = ammo\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = ammo != 2\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = mood > calm\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = mood == furious\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = armed == maybe\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = ammo > 3 and ammo < 2\n" + ACTION, 6},
		{KEYS + "node 1 goal\n\tdesired = ammo == 1.5\n" + ACTION, 6},
		{KEYS + GOAL + "node 2 action\n\taction = a\n\teffects = armed += 1\n", 9},
		{KEYS + GOAL + "node 2 action\n\taction = a\n\teffects = armed = true, armed = false\n", 9},
		{KEYS + GOAL + "node 2 action\n\taction = a\n\teffects = armed\n", 9},
		{KEYS + GOAL + "node 2 action\n\taction = a\n\teffects = health = 2\n", 9},
		{KEYS + GOAL + ACTION + "\tcost = 0\n", 10},
		{KEYS + GOAL + ACTION + "\tcost = armed\n", 10},
		{KEYS + GOAL + ACTION + "\tcost = missing\n", 10},
		{KEYS + GOAL + ACTION + "\tdesired = armed\n", 10},
		{KEYS + GOAL + ACTION + "\tpreconditions = ammo > x\n", 10},
		{KEYS + GOAL + ACTION + "\tset ammo = 2\n", 10},
	}
	keys := goap_keys(t)
	for c in cases {
		_, problems := decision_parse(strings.concatenate({GOAP_HEAD, c.text}, context.temp_allocator), keys, TECHNIQUE_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

// The cooker cooks a GOAP decision with its own reader into a blob whose data fits its blackboard.
@(test)
goap_decisions_cook_to_blobs_that_fit_their_blackboards :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/ai/hunter.blackboard", GOAP_BOARD},
			{"content/ai/hunter.blackboard.meta", "guid = " + GOAP_BOARD_GUID + "\n"},
			{"content/ai/hunter.decision", HUNTER},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Blackboard, .Decision}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Decision], 1)
	board_guid, _ := format.guid_parse(GOAP_BOARD_GUID)
	board_data := tree_blob(t, tree, board_guid)
	board, board_ok := format.blackboard_view(board_data)
	data := tree_blob(t, tree, tree_guid(t, tree, "ai/hunter.decision"))
	blob, ok := format.decision_view(data)
	testing.expect(t, ok && board_ok)
	if !ok || !board_ok {
		return
	}
	testing.expect_value(t, blob.technique, format.Decision_Technique.Goap)
	testing.expect_value(t, blob.state_size, 2432)
	testing.expect(t, format.decision_check(data, blob, board_data, board))
	testing.expect(t, format.goap_check(format.decision_technique_data(data, blob), data, blob, board_data, board))
}

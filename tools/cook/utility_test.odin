package cook

import "core:slice"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
UTILITY_BOARD :: `blackboard 1
float health = 100
int ammo = 3
bool has_target
enum mood (calm, alert) = calm
entity target
position home
vector facing
`

@(private = "file")
UTILITY_BOARD_GUID :: "00112233445566778899aabbccddeef0"

@(private = "file")
UTILITY_HEAD :: "decision 1\ntechnique = utility\nblackboard = $" + UTILITY_BOARD_GUID + "\n"

// A soldier: attack the best enemy that it perceives, flee when it is hurt, and rest. The considerations follow the
// options, and one is shared.
@(private = "file")
SOLDIER :: UTILITY_HEAD + `pick = weighted
within = 0.2
momentum = 0.5

node 1 option
	action = attack(at = target)
	weight = 2
	considerations = 3, 4
	target = target
	target_tag = enemy
	cooldown = 1.5
node 2 option
	when = health < 30
	action = flee
	considerations = 3, 5
	set mood = alert
node 6 option
	position = [0, 200]
	action = rest
	considerations = 7
node 3 consideration
	input = health
	range = [0, 100]
	curve = logistic
	slope = -1
	exponent = 2
	y_shift = 1
node 4 consideration
	input = distance(self, target)
	range = [0, 30]
	curve = table
	points = [0, 1], [0.5, 0.8], [1, 0]
node 5 consideration
	input = since(mood)
	range = [0, 10]
	curve = polynomial
	exponent = 2
node 7 consideration
	input = has_target
	curve = step
	slope = -1
	y_shift = 1
`

@(private = "file")
utility_keys :: proc(t: ^testing.T) -> []format.Blackboard_Key_Contents {
	contents, problems := blackboard_parse(UTILITY_BOARD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	return contents.keys
}

// The options and the considerations are in the text's order, each option's considerations are its links in its own
// order, and the module state is the running option, the options' states and then their links' states.
@(test)
a_utility_decision_cooks :: proc(t: ^testing.T) {
	contents, problems := decision_parse(SOLDIER, utility_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(problems) > 0 {
		return
	}
	u := format.utility_data(contents.technique_data)
	testing.expect(t, u.header != nil)
	if u.header == nil || len(u.options) != 3 || len(u.considerations) != 4 {
		testing.expectf(t, false, "%d options and %d considerations", len(u.options), len(u.considerations))
		return
	}
	testing.expect_value(t, u.header.pick, format.Utility_Pick.Weighted)
	testing.expect_value(t, u.header.within, 0.2)
	testing.expect_value(t, u.header.momentum, 0.5)
	ids := [3]u32{1, 2, 6}
	for o, i in u.options {
		testing.expect_value(t, contents.nodes[o.node].id, ids[i])
		testing.expect(t, contents.nodes[o.node].action != format.DECISION_NONE)
	}
	attack, flee, rest := u.options[0], u.options[1], u.options[2]
	testing.expect_value(t, attack.weight, 2)
	testing.expect_value(t, attack.target, 4)
	testing.expect_value(t, attack.target_tag, format.animation_graph_hash("enemy"))
	testing.expect_value(t, attack.flags, format.Utility_Flags{.Cooldown, .Tag})
	testing.expect_value(t, attack.cooldown, format.Tree_Time{seconds = 1.5})
	testing.expect_value(t, flee.weight, 1)
	testing.expect_value(t, flee.target, format.DECISION_NONE)
	testing.expect(t, contents.nodes[flee.node].condition != format.DECISION_NONE)
	testing.expect_value(t, contents.nodes[flee.node].write_count, 1)
	testing.expect(t, slice.equal(u.links[attack.first_link:][:attack.link_count], []u32{0, 1}))
	testing.expect(t, slice.equal(u.links[flee.first_link:][:flee.link_count], []u32{0, 2}))
	testing.expect(t, slice.equal(u.links[rest.first_link:][:rest.link_count], []u32{3}))

	health, distance, since, has_target := u.considerations[0], u.considerations[1], u.considerations[2], u.considerations[3]
	testing.expect_value(t, health.input, format.Utility_Input.Number)
	testing.expect_value(t, health.a, 0)
	testing.expect_value(t, health.max, 100)
	testing.expect_value(t, health.curve, format.Utility_Curve.Logistic)
	testing.expect_value(t, health.slope, -1)
	testing.expect_value(t, health.exponent, 2)
	testing.expect_value(t, health.y_shift, 1)
	testing.expect_value(t, distance.input, format.Utility_Input.Distance)
	testing.expect_value(t, distance.a, format.UTILITY_SELF)
	testing.expect_value(t, distance.b, 4)
	testing.expect_value(t, distance.point_count, 3)
	testing.expect_value(t, u.points[distance.first_point + 1], format.Utility_Point{0.5, 0.8})
	testing.expect_value(t, since.input, format.Utility_Input.Since)
	testing.expect_value(t, since.a, 3)
	testing.expect_value(t, has_target.input, format.Utility_Input.Number)
	testing.expect_value(t, has_target.min, 0)
	testing.expect_value(t, has_target.max, 1)
	testing.expect_value(t, has_target.curve, format.Utility_Curve.Step)

	testing.expect_value(t, attack.state, 8)
	testing.expect_value(t, flee.state, 32)
	testing.expect_value(t, rest.state, 56)
	testing.expect_value(t, attack.links_state, 80)
	testing.expect_value(t, flee.links_state, 96)
	testing.expect_value(t, rest.links_state, 112)
	testing.expect_value(t, contents.state_size, 120)
}

// The settings' defaults, an option without considerations, and the fields that every curve takes.
@(test)
utility_settings_have_defaults :: proc(t: ^testing.T) {
	text := UTILITY_HEAD + "node 1 option\n\taction = rest\n"
	contents, problems := decision_parse(text, utility_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	u := format.utility_data(contents.technique_data)
	if u.header == nil {
		return
	}
	testing.expect_value(t, u.header.pick, format.Utility_Pick.Best)
	testing.expect_value(t, u.header.within, UTILITY_DEFAULT_WITHIN)
	testing.expect_value(t, u.header.momentum, UTILITY_DEFAULT_MOMENTUM)
	testing.expect_value(t, u.options[0].link_count, 0)

	good := []string {
		"node 1 option\n\taction = a\n\tconsiderations = 2\nnode 2 consideration\n\tinput = ammo\n\trange = [0, 10]\n\tcurve = linear\n\tslope = 2\n\tx_shift = 0.1\n\ty_shift = -0.5\n",
		"node 1 option\n\taction = a\n\tconsiderations = 2\nnode 2 consideration\n\tinput = health\n\tcurve = logit\n\texponent = 0.5\n",
		"node 1 option\n\taction = a\n\tconsiderations = 2\nnode 2 consideration\n\tinput = distance(home, target)\n\trange = [30, 0]\n\tcurve = table\n\tpoints = [0, 0], [1, 1]\n\texponent = 3\n",
		"node 1 option\n\taction = a\n\tconsiderations = 2\n\tcooldown = ammo\nnode 2 consideration\n\tinput = since(facing)\n\tcurve = step\n\tx_shift = 0.2\n",
	}
	for g in good {
		_, good_problems := decision_parse(strings.concatenate({UTILITY_HEAD, g}, context.temp_allocator), utility_keys(t), TECHNIQUE_READERS, context.temp_allocator)
		testing.expectf(t, len(good_problems) == 0, "%q: %v", g, good_problems)
	}
}

@(test)
utility_problems_have_their_lines :: proc(t: ^testing.T) {
	OPTION :: "node 1 option\n\taction = a\n\tconsiderations = 2\n"
	CONSIDERATION :: "node 2 consideration\n\tinput = health\n\tcurve = linear\n"
	cases := []struct {
		text: string,
		line: int,
	} {
		{"", 1},
		{"speed = 2\nnode 1 option\n\taction = a\n", 4},
		{"pick = worst\nnode 1 option\n\taction = a\n", 4},
		{"pick = weighted\nwithin = 2\nnode 1 option\n\taction = a\n", 5},
		{"within = 0.5\nnode 1 option\n\taction = a\n", 4},
		{"momentum = -1\nnode 1 option\n\taction = a\n", 4},
		{"node 1 dance\n", 1},
		{"node 1 option\n\taction = a\nnode 2 dance\n", 6},
		{"node 1 option\n", 4},
		{"node 1 option\n\taction = a\n\tcolor = red\n", 6},
		{"node 1 option\n\taction = a\n\tcurve = linear\n", 6},
		{"node 1 option\n\taction = a\n\tweight = -1\n", 6},
		{"node 1 option\n\taction = a\n\tcooldown = -1\n", 6},
		{"node 1 option\n\taction = a\n\ttarget = health\n", 6},
		{"node 1 option\n\taction = a\n\ttarget = missing\n", 6},
		{"node 1 option\n\taction = a\n\ttarget_tag = enemy\n", 6},
		{"node 1 option\n\taction = a\n\tconsiderations = 2, x\n" + CONSIDERATION, 6},
		{"node 1 option\n\taction = a\n\tconsiderations = 9\n", 6},
		{"node 1 option\n\taction = a\n\tconsiderations = 2, 2\n" + CONSIDERATION, 6},
		{"node 1 option\n\taction = a\n\tconsiderations = 3\nnode 3 option\n\taction = b\n", 6},
		{"node 1 option\n\taction = a\n" + CONSIDERATION, 6},
		{"node 2 consideration\n\tinput = health\n\tcurve = linear\n", 1},
		{OPTION + "node 2 consideration\n\tcurve = linear\n", 7},
		{OPTION + "node 2 consideration\n\tinput = health\n", 7},
		{OPTION + CONSIDERATION + "\taction = b\n", 10},
		{OPTION + CONSIDERATION + "\twhen = has_target\n", 10},
		{OPTION + CONSIDERATION + "\tset mood = alert\n", 10},
		{OPTION + "node 2 consideration\n\tinput = target\n\tcurve = linear\n", 8},
		{OPTION + "node 2 consideration\n\tinput = missing\n\tcurve = linear\n", 8},
		{OPTION + "node 2 consideration\n\tinput = health + 1\n\tcurve = linear\n", 8},
		{OPTION + "node 2 consideration\n\tinput = distance(self)\n\tcurve = linear\n", 8},
		{OPTION + "node 2 consideration\n\tinput = distance(self, health)\n\tcurve = linear\n", 8},
		{OPTION + "node 2 consideration\n\tinput = since(missing)\n\tcurve = linear\n", 8},
		{OPTION + "node 2 consideration\n\tinput = has_target\n\trange = [0, 2]\n\tcurve = linear\n", 9},
		{OPTION + CONSIDERATION + "\trange = [1, 1]\n", 10},
		{OPTION + CONSIDERATION + "\trange = 5\n", 10},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = wavy\n", 9},
		{OPTION + CONSIDERATION + "\texponent = 2\n", 10},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = polynomial\n\texponent = 0\n", 10},
		{OPTION + CONSIDERATION + "\tslope = steep\n", 10},
		{OPTION + CONSIDERATION + "\tpoints = [0, 0], [1, 1]\n", 10},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = table\n", 7},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = table\n\tpoints = [0, 0]\n", 10},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = table\n\tpoints = [1, 0], [0, 1]\n", 10},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = table\n\tpoints = [0, 0] [1, 1]\n", 10},
		{OPTION + "node 2 consideration\n\tinput = health\n\tcurve = table\n\tpoints = [0, 0, 1], [1, 1]\n", 10},
	}
	keys := utility_keys(t)
	for c in cases {
		_, problems := decision_parse(strings.concatenate({UTILITY_HEAD, c.text}, context.temp_allocator), keys, TECHNIQUE_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

// The cooker cooks a utility decision with its own reader into a blob whose data fits its blackboard.
@(test)
utility_decisions_cook_to_blobs_that_fit_their_blackboards :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/ai/soldier.blackboard", UTILITY_BOARD},
			{"content/ai/soldier.blackboard.meta", "guid = " + UTILITY_BOARD_GUID + "\n"},
			{"content/ai/soldier.decision", SOLDIER},
		},
	)
	defer remove_tree(tree)
	pass := cook(tree_options(tree), {.Blackboard, .Decision}, log_problems = false)
	testing.expect(t, pass.ok)
	testing.expect_value(t, pass.cooked[.Decision], 1)
	board_guid, _ := format.guid_parse(UTILITY_BOARD_GUID)
	board_data := tree_blob(t, tree, board_guid)
	board, board_ok := format.blackboard_view(board_data)
	data := tree_blob(t, tree, tree_guid(t, tree, "ai/soldier.decision"))
	blob, ok := format.decision_view(data)
	testing.expect(t, ok && board_ok)
	if !ok || !board_ok {
		return
	}
	testing.expect_value(t, blob.technique, format.Decision_Technique.Utility)
	testing.expect_value(t, blob.state_size, 120)
	testing.expect(t, format.decision_check(data, blob, board_data, board))
	testing.expect(t, format.utility_check(format.decision_technique_data(data, blob), data, blob, board_data, board))
}

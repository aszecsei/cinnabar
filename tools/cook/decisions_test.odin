package cook

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
BOARD :: `blackboard 1
# A guard's knowledge.
float health = 1
int ammo = 30
bool has_target
enum mood (calm, alert, angry) = calm
entity target
position last_seen = [1, 2, -3]
vector heading = [0, 0, 1]
`

@(private = "file")
BOARD_GUID :: "0123456789abcdef0123456789abcdef"

@(private = "file")
board_keys :: proc(t: ^testing.T) -> []format.Blackboard_Key_Contents {
	contents, problems := blackboard_parse(BOARD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	return contents.keys
}

// test_reader is a technique of nodes that each run their action: its state is a u32 for each node, and its data the
// nodes' count and, for each, the condition of its `also` field.
@(private = "file")
test_reader :: proc(p: ^Decision_Parser, text: ^Decision_Text) -> (state_size: u32, data: []byte) {
	result := make([dynamic]byte, context.temp_allocator)
	append(&result, u8(len(text.nodes)))
	for n in text.nodes {
		also := format.DECISION_NONE
		for f in n.fields {
			switch f.key {
			case "also":
				also = decision_condition(p, f.value, f.line)
			case "when", "action", "position":
			case:
				decision_problem(p, f.line, "a test node has no field %s", f.key)
			}
		}
		append(&result, u8(also))
	}
	return u32(4 * len(text.nodes)), result[:]
}

@(private = "file")
TEST_READERS :: #partial Technique_Readers {
	.Utility = {version = "test 1", read = test_reader},
}

@(test)
blackboards_give_each_key_a_slot_offset_and_default :: proc(t: ^testing.T) {
	contents, problems := blackboard_parse(BOARD, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	keys := contents.keys
	testing.expect_value(t, len(keys), 7)
	names := [?]string{"health", "ammo", "has_target", "mood", "target", "last_seen", "heading"}
	for k, i in keys {
		testing.expect_value(t, k.name, names[i])
	}
	testing.expect_value(t, (^f32)(&keys[0].default)^, 1)
	testing.expect_value(t, (^i32)(&keys[1].default)^, 30)
	testing.expect_value(t, keys[2].default[0], 0)
	testing.expect_value(t, len(keys[3].enum_names), 3)
	testing.expect_value(t, (^u32)(&keys[3].default)^, 0)
	testing.expect_value(t, (^[3]i64)(&keys[5].default)^, [3]i64{1 << 24, 2 << 24, -(3 << 24)})
	testing.expect_value(t, (^[3]f32)(&keys[6].default)^, [3]f32{0, 0, 1})
	offsets, size := format.blackboard_offsets(keys, context.temp_allocator)
	testing.expect_value(t, offsets[2], 8)
	testing.expect_value(t, offsets[4], 16)
	testing.expect_value(t, offsets[5], 24)
	testing.expect_value(t, size, 64)
}

@(test)
blackboard_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	HEAD :: "blackboard 1\nfloat health\n"
	cases := []struct {
		text: string,
		line: int,
	} {
		{"float health\n", 1},
		{HEAD + "string name\n", 3},
		{HEAD + "float health\n", 3},
		{HEAD + "float 3d\n", 3},
		{HEAD + "int ammo = 1.5\n", 3},
		{HEAD + "int ammo = 3000000000\n", 3},
		{HEAD + "bool ready = yes\n", 3},
		{HEAD + "enum mood calm, alert\n", 3},
		{HEAD + "enum mood ()\n", 3},
		{HEAD + "enum mood (calm, calm)\n", 3},
		{HEAD + "enum mood (calm, alert) = angry\n", 3},
		{HEAD + "entity target = self\n", 3},
		{HEAD + "position home = [1, 2]\n", 3},
		{HEAD + "vector heading = 1\n", 3},
		{HEAD + "float speed = fast\n", 3},
	}
	for c in cases {
		_, problems := blackboard_parse(c.text, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

@(test)
conditions_compile_to_postfix_ops :: proc(t: ^testing.T) {
	keys := board_keys(t)
	text := fmt.tprintf("decision 1\ntechnique = utility\nblackboard = $%s\nnode 1 pick\n\twhen = health < 0.3 and (has_target or mood == alert)\n", BOARD_GUID)
	contents, problems := decision_parse(text, keys, TEST_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	codes := [?]format.Decision_Op_Code{.Key, .Constant, .Less, .Key, .Key, .Constant, .Equal, .Or, .And}
	testing.expect_value(t, len(contents.ops), len(codes))
	for o, i in contents.ops {
		testing.expect_value(t, o.code, codes[i])
	}
	testing.expect_value(t, contents.ops[0].operand, 0)
	testing.expect_value(t, contents.ops[3].operand, 2)
	testing.expect_value(t, contents.ops[6].type, u8(format.Blackboard_Type.Enum))
	alert := contents.constants[contents.ops[5].operand]
	testing.expect_value(t, alert.type, format.Blackboard_Type.Enum)
	testing.expect_value(t, (^u32)(&alert.value)^, 1)
	testing.expect_value(t, contents.nodes[0].condition, 0)
	testing.expect_value(t, contents.technique, format.Decision_Technique.Utility)
	testing.expect_value(t, contents.state_size, 4)
}

@(test)
conditions_test_entities_and_distances :: proc(t: ^testing.T) {
	keys := board_keys(t)
	cases := []struct {
		text:  string,
		codes: []format.Decision_Op_Code,
	} {
		{"target != none", {.Key, .Constant, .Not_Equal}},
		{"distance(self, target) < 10", {.Self, .Key, .Distance, .Constant, .Less}},
		{"distance(target, last_seen) >= -2.5e1", {.Key, .Key, .Distance, .Constant, .Greater_Equal}},
		{"not has_target", {.Key, .Not}},
		{"!has_target and ammo > 0", {.Key, .Not, .Key, .Constant, .Greater, .And}},
		{"alert != mood", {.Constant, .Key, .Not_Equal}},
		{"target == self", {.Key, .Self, .Equal}},
		{"has_target == true", {.Key, .Constant, .Equal}},
	}
	for c in cases {
		text := fmt.tprintf("decision 1\ntechnique = utility\nblackboard = $%s\nnode 1 pick\n\twhen = %s\n", BOARD_GUID, c.text)
		contents, problems := decision_parse(text, keys, TEST_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) == 0, "%s: %v", c.text, problems)
		testing.expectf(t, len(contents.ops) == len(c.codes), "%s: %v", c.text, contents.ops)
		for o, i in contents.ops {
			if i < len(c.codes) {
				testing.expectf(t, o.code == c.codes[i], "%s: op %d is %v", c.text, i, o.code)
			}
		}
	}
}

// deep_condition is a condition whose stack is deeper than MAX_DECISION_STACK: each `and (` keeps a value on it.
@(private = "file")
deep_condition :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< format.MAX_DECISION_STACK {
		fmt.sbprintf(&b, "ammo > %d and (", i)
	}
	strings.write_string(&b, "has_target")
	for _ in 0 ..< format.MAX_DECISION_STACK {
		strings.write_byte(&b, ')')
	}
	return strings.to_string(b)
}

@(test)
condition_mistakes_are_problems :: proc(t: ^testing.T) {
	keys := board_keys(t)
	cases := []string {
		"health",
		"health < ",
		"health < 0.3 and",
		"(has_target",
		"missing",
		"mood == furious",
		"mood < alert",
		"has_target < true",
		"target < none",
		"health == has_target",
		"last_seen == last_seen",
		"heading",
		"distance(self, health) < 1",
		"distance(self, none) < 1",
		"distance(self) < 1",
		"health < \"low\"",
		"has_target and 1",
		"health < 0.3 0.4",
		"health # 2",
		"((((((((((((((((((has_target))))))))))))))))))",
		deep_condition(),
	}
	for c in cases {
		text := fmt.tprintf("decision 1\ntechnique = utility\nblackboard = $%s\nnode 1 pick\n\twhen = %s\n", BOARD_GUID, c)
		_, problems := decision_parse(text, keys, TEST_READERS, context.temp_allocator)
		if c == "((((((((((((((((((has_target))))))))))))))))))" || c == "health # 2" {
			// Parentheses do not deepen the stack, and a # starts a comment.
			testing.expectf(t, len(problems) == (1 if c == "health # 2" else 0), "%s: %v", c, problems)
			continue
		}
		testing.expectf(t, len(problems) > 0 && problems[0].line == 5, "%s: %v", c, problems)
	}
}

@(test)
actions_and_writes_take_constants_keys_and_self :: proc(t: ^testing.T) {
	keys := board_keys(t)
	text := fmt.tprintf(`decision 1
technique = utility
blackboard = $%s
node 1 pick
	action = flee(from = target, speed = 4, line = "run, now!", toward = [1, 0, 2], loud = true, at = last_seen, who = self)
	set mood = alert
	set target = self
	set health = 0.5
	set last_seen = [0, 1, 0]
node 2 pick
	action = wait
	set has_target = false
`, BOARD_GUID)
	contents, problems := decision_parse(text, keys, TEST_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	if len(problems) > 0 {
		return
	}
	testing.expect_value(t, len(contents.actions), 2)
	flee := contents.actions[0]
	testing.expect_value(t, flee.name, "flee")
	testing.expect_value(t, flee.arg_count, 7)
	args := contents.args[flee.first_arg:][:flee.arg_count]
	testing.expect_value(t, args[0].source, format.Decision_Source.Key)
	testing.expect_value(t, args[0].type, format.Blackboard_Type.Entity)
	testing.expect_value(t, args[1].type, format.Blackboard_Type.Float)
	testing.expect_value(t, contents.constants[args[2].index].text, "run, now!")
	testing.expect_value(t, args[2].type, format.Blackboard_Type.String)
	testing.expect_value(t, args[3].type, format.Blackboard_Type.Vector)
	testing.expect_value(t, args[4].type, format.Blackboard_Type.Bool)
	testing.expect_value(t, args[5].type, format.Blackboard_Type.Position)
	testing.expect_value(t, args[6].source, format.Decision_Source.Self)
	testing.expect_value(t, contents.actions[1].arg_count, 0)

	node := contents.nodes[0]
	testing.expect_value(t, node.write_count, 4)
	testing.expect_value(t, contents.writes[node.first_write].source, format.Decision_Source.Constant)
	testing.expect_value(t, contents.writes[node.first_write + 1].source, format.Decision_Source.Self)
	testing.expect_value(t, contents.writes[node.first_write + 3].key, 5)
	testing.expect_value(t, contents.nodes[1].first_write, 4)
	testing.expect_value(t, contents.nodes[1].write_count, 1)
}

@(test)
decision_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	keys := board_keys(t)
	head := fmt.tprintf("decision 1\ntechnique = utility\nblackboard = $%s\n", BOARD_GUID)
	cases := []struct {
		text: string,
		line: int,
	} {
		{"technique = utility\n", 1},
		{fmt.tprintf("decision 1\nblackboard = $%s\n", BOARD_GUID), 1},
		{"decision 1\ntechnique = utility\n", 1},
		{fmt.tprintf("decision 1\ntechnique = chess\nblackboard = $%s\n", BOARD_GUID), 2},
		{fmt.tprintf("decision 1\ntechnique = htn\nblackboard = $%s\n", BOARD_GUID), 2},
		{fmt.tprintf("%stechnique = goap\n", head), 4},
		{fmt.tprintf("%sblackboard = guard\n", head), 4},
		{fmt.tprintf("%s\tsize = 2\n", head), 4},
		{fmt.tprintf("%snode 0 pick\n", head), 4},
		{fmt.tprintf("%snode 1\n", head), 4},
		{fmt.tprintf("%snode 1 pick\nnode 1 pick\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\twhen = has_target\n\twhen = has_target\n", head), 6},
		{fmt.tprintf("%snode 1 pick\n\tcolor = red\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\tset missing = 1\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\tset health = true\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\tset health = ammo\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\tset health = self\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\tset mood = furious\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\tset health\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\taction = flee(\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\taction = flee(from target)\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\taction = flee(from = nowhere)\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\taction = flee(from = target, from = self)\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\taction = 3d(x = 1)\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\taction = flee(line = \"unended)\n", head), 5},
		{fmt.tprintf("%snode 1 pick\n\talso = missing\n", head), 5},
	}
	for c in cases {
		_, problems := decision_parse(c.text, keys, TEST_READERS, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

@(test)
a_technique_without_a_reader_is_a_problem :: proc(t: ^testing.T) {
	text := fmt.tprintf("decision 1\ntechnique = goap\nblackboard = $%s\n", BOARD_GUID)
	_, problems := decision_parse(text, board_keys(t), TECHNIQUE_READERS, context.temp_allocator)
	testing.expectf(t, len(problems) == 1 && problems[0].line == 2, "%v", problems)
}

@(private = "file")
DECISION :: `decision 1
technique = utility
blackboard = $0123456789abcdef0123456789abcdef
node 1 pick
	position = [10, 20]
	when = health < 0.3
	action = flee(from = target)
	set mood = alert
`

@(test)
decisions_cook_against_their_blackboards :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/ai/guard.blackboard", BOARD},
			{"content/ai/guard.blackboard.meta", "guid = " + BOARD_GUID + "\n"},
			{"content/ai/guard.decision", DECISION},
			{"content/ai/broken.decision", "decision 1\ntechnique = utility\nblackboard = $0123456789abcdef0123456789abcdef\nnode 1 pick\n\twhen = missing\n"},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	options.technique_readers = TEST_READERS
	pass := cook(options, {.Blackboard, .Decision}, log_problems = false)
	// The broken decision fails, and the guard's cooks.
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Blackboard], 1)
	testing.expect_value(t, pass.cooked[.Decision], 1)
	board_guid, _ := format.guid_parse(BOARD_GUID)
	board_data := tree_blob(t, tree, board_guid)
	board, board_ok := format.blackboard_view(board_data)
	data := tree_blob(t, tree, tree_guid(t, tree, "ai/guard.decision"))
	blob, ok := format.decision_view(data)
	testing.expect(t, ok && board_ok)
	if !ok || !board_ok {
		return
	}
	testing.expect_value(t, blob.blackboard, board_guid)
	testing.expect(t, format.decision_check(data, blob, board_data, board), "the decision fits its blackboard")
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/ai/guard.decision")
	testing.expect_value(t, len(format.decision_technique_data(data, blob)), 2)
	refs, refs_ok := format.blob_references(data, context.temp_allocator)
	testing.expect(t, refs_ok && len(refs) == 1 && refs[0] == board_guid)
	for a in pass.assets {
		if a.kind == .Decision {
			// Each depends on its blackboard, whether it cooked or not.
			testing.expect_value(t, len(a.dependencies), 1)
		}
	}

	// A second cook finds both up to date.
	pass = cook(options, {.Blackboard, .Decision}, log_problems = false)
	testing.expect_value(t, pass.current[.Decision], 1)
	testing.expect_value(t, pass.current[.Blackboard], 1)

	// A blackboard with a new key cooks the decision again, against its new key.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/ai/guard.blackboard", tree.dir), string(BOARD + "bool armed\n")) == nil)
	pass = cook(options, {.Blackboard, .Decision}, log_problems = false)
	testing.expect_value(t, pass.cooked[.Decision], 1)
	board_data = tree_blob(t, tree, board_guid)
	board, _ = format.blackboard_view(board_data)
	data = tree_blob(t, tree, tree_guid(t, tree, "ai/guard.decision"))
	blob, _ = format.decision_view(data)
	testing.expect(t, format.decision_check(data, blob, board_data, board), "the decision fits its new blackboard")

	// A blackboard with a problem fails its decisions, which keep their old blobs.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/ai/guard.blackboard", tree.dir), string(BOARD + "bool armed = maybe\n")) == nil)
	pass = cook(options, {.Blackboard, .Decision}, log_problems = false)
	testing.expect_value(t, pass.cooked[.Decision], 0)
	kept := tree_blob(t, tree, tree_guid(t, tree, "ai/guard.decision"))
	kept_blob, kept_ok := format.decision_view(kept)
	testing.expect(t, kept_ok && kept_blob.header.key == blob.header.key)
}

@(test)
a_decision_names_a_blackboard :: proc(t: ^testing.T) {
	tree := make_tree(
		t,
		{
			{"content/ai/guard.blackboard", BOARD},
			{"content/ai/guard.blackboard.meta", "guid = " + BOARD_GUID + "\n"},
			{"content/ai/other.blackboard.meta", "guid = 00112233445566778899aabbccddeeff\n"},
			{"content/ai/other.blackboard", "blackboard 1\nfloat x\n"},
			{"content/ai/missing.decision", "decision 1\ntechnique = utility\nblackboard = $ffffffffffffffffffffffffffffffff\n"},
			{"content/ai/scene.decision", "decision 1\ntechnique = utility\nblackboard = $ffffffffffffffffffffffffffffff00\n"},
			{"content/ai/scene.scene", "scene 1\n"},
			{"content/ai/scene.scene.meta", "guid = ffffffffffffffffffffffffffffff00\n"},
		},
	)
	defer remove_tree(tree)
	options := tree_options(tree)
	options.technique_readers = TEST_READERS
	pass := cook(options, {.Blackboard, .Decision}, log_problems = false)
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Decision], 0)
	for fragment in ([]string{"no asset has the GUID", "is not a blackboard"}) {
		found := false
		for p in pass.problems.list {
			found ||= p.error && strings.contains(p.text, fragment)
		}
		testing.expectf(t, found, "an error says %q: %v", fragment, pass.problems.list)
	}
}

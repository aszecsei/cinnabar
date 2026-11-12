package cook

import "core:fmt"
import "core:os"
import "core:testing"

import format "cinnabar:engine/asset/format"

@(private = "file")
PERCEPTION :: `perception 1
# A guard's senses.
notices Player, Noise_Maker
target = nearest Player
threat = nearest seen Enemy
anyone = nearest heard any
target_position = position target
target_visible = visible target
target_since = since target
heard = heard noise
heard_position = loudest noise Noise_Maker
`

@(test)
perceptions_parse_their_notices_and_rows :: proc(t: ^testing.T) {
	contents, problems := perception_parse(PERCEPTION, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(contents.notices), 2)
	testing.expect_value(t, contents.notices[1], "Noise_Maker")
	rows := contents.rows
	testing.expect_value(t, len(rows), 8)
	expected := []format.Perception_Row_Contents {
		{key = "target", source = .Nearest, tag = "Player", of = format.PERCEPTION_NONE},
		{key = "threat", source = .Nearest_Seen, tag = "Enemy", of = format.PERCEPTION_NONE},
		{key = "anyone", source = .Nearest_Heard, tag = "", of = format.PERCEPTION_NONE},
		{key = "target_position", source = .Position, of = 0},
		{key = "target_visible", source = .Visible, of = 0},
		{key = "target_since", source = .Since, of = 0},
		{key = "heard", source = .Heard_Noise, of = format.PERCEPTION_NONE},
		{key = "heard_position", source = .Loudest_Noise, tag = "Noise_Maker", of = format.PERCEPTION_NONE},
	}
	for e, i in expected {
		testing.expectf(t, rows[i] == e, "row %d: %v, not %v", i, rows[i], e)
	}
	// Without a notices line, every tag is noticed.
	contents, problems = perception_parse("perception 1\ntarget = nearest any\n", context.temp_allocator)
	testing.expect(t, len(problems) == 0 && len(contents.notices) == 0 && len(contents.rows) == 1)
}

@(test)
perception_mistakes_are_problems_at_their_lines :: proc(t: ^testing.T) {
	HEAD :: "perception 1\ntarget = nearest Player\n"
	cases := []struct {
		text: string,
		line: int,
	} {
		{"target = nearest Player\n", 1},
		{"perception 2\n", 1},
		{HEAD + "target = nearest Enemy\n", 3},
		{HEAD + "3d = nearest Enemy\n", 3},
		{HEAD + "where = position\n", 3},
		{HEAD + "where = position home\n", 3},
		{HEAD + "seen = visible heard\nheard = heard noise\n", 3},
		{HEAD + "heard = heard noise\nseen = visible heard\n", 4},
		{HEAD + "near = nearest\n", 3},
		{HEAD + "near = nearest close Player\n", 3},
		{HEAD + "noise = loudest sound\n", 3},
		{HEAD + "noise = heard noise Player Enemy\n", 3},
		{HEAD + "smell = sniff Player\n", 3},
		{HEAD + "target_position\n", 3},
		{HEAD + "notices Player\nnotices Enemy\n", 4},
		{HEAD + "notices Player, Player\n", 3},
		{HEAD + "notices Player, 9lives\n", 3},
	}
	for c in cases {
		_, problems := perception_parse(c.text, context.temp_allocator)
		testing.expectf(t, len(problems) > 0 && problems[0].line == c.line, "%q: %v", c.text, problems)
	}
}

@(test)
perceptions_cook_into_blobs :: proc(t: ^testing.T) {
	tree := make_tree(t, {{"content/ai/guard.perception", PERCEPTION}, {"content/ai/broken.perception", "perception 1\nwhere = position nobody\n"}})
	defer remove_tree(tree)
	options := tree_options(tree)
	pass := cook(options, {.Perception}, log_problems = false)
	// The broken perception fails, and the guard's cooks.
	testing.expect(t, !pass.ok)
	testing.expect_value(t, pass.cooked[.Perception], 1)
	data := tree_blob(t, tree, tree_guid(t, tree, "ai/guard.perception"))
	blob, ok := format.perception_view(data)
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, format.blob_string(data, blob.source_path), "game/ai/guard.perception")
	testing.expect_value(t, len(format.perception_rows(data, blob)), 8)
	testing.expect_value(t, len(format.perception_notices(data, blob)), 2)

	// A second cook finds it up to date, and an edit cooks it again.
	pass = cook(options, {.Perception}, log_problems = false)
	testing.expect_value(t, pass.current[.Perception], 1)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/ai/guard.perception", tree.dir), string(PERCEPTION + "near = nearest any\n")) == nil)
	pass = cook(options, {.Perception}, log_problems = false)
	testing.expect_value(t, pass.cooked[.Perception], 1)
	data = tree_blob(t, tree, tree_guid(t, tree, "ai/guard.perception"))
	blob, _ = format.perception_view(data)
	testing.expect_value(t, len(format.perception_rows(data, blob)), 9)
	key := blob.header.key

	// A perception with a problem keeps its old blob.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/content/ai/guard.perception", tree.dir), string(PERCEPTION + "near = nearest\n")) == nil)
	pass = cook(options, {.Perception}, log_problems = false)
	testing.expect_value(t, pass.cooked[.Perception], 0)
	kept := tree_blob(t, tree, tree_guid(t, tree, "ai/guard.perception"))
	kept_blob, kept_ok := format.perception_view(kept)
	testing.expect(t, kept_ok && kept_blob.header.key == key)
}
